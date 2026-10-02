/**
 * @file VisionService.ets
 * @module services
 * @description 端侧视觉服务（后置摄像头静默拍摄 + 端侧 MobileNetV2 + 云端 Qwen-VL 兜底 + 振动反馈）。
 *
 * 职责：
 * 1. 后置摄像头静默拍摄单帧 JPEG（PreviewOutput+PhotoOutput 双路，避免全黑帧）；
 * 2. 拍摄完成后立即释放相机资源；
 * 3. 端侧图像分类（LocalImageClassifier）优先 + 云端 Qwen-VL 兜底；
 * 4. 提供振动反馈能力。
 *
 * 设计要点：
 * - 视障用户无需手动对准，应用后台静默拍摄（预览流走隐藏 ImageReceiver）；
 * - 拍摄失败抛中文 Error "相机不可用，请检查权限设置"；
 * - Base64 图像仅在函数作用域内存在，函数返回即解除引用（阅后即焚）。
 * - P0-3 端侧视觉落地：classifyImage() 端侧优先毫秒级响应，云端兜底保证识别能力上限。
 */

import camera from '@ohos.multimedia.camera';
import image from '@ohos.multimedia.image';
import vibrator from '@ohos.vibrator';
import util from '@ohos.util';
import display from '@ohos.display';
import { BusinessError } from '@ohos.base';
import { Permissions } from '@ohos.abilityAccessCtrl';
import { Logger } from '../utils/Logger';
import { PermissionUtil } from '../utils/PermissionUtil';
import { LLMClient } from './LLMClient';
import { LocalImageClassifier } from './LocalImageClassifier';
import { LocalVLMEngine } from './LocalVLMEngine';
import { LocalOCREngine } from './LocalOCREngine';
import { ElderlyMedicineKb } from '../utils/ElderlyMedicineKb';
import {
  MedicineInfo,
  MedicineQuestionResult,
  MedicineRecognitionResult,
  VisionAnalyzeResult,
  LLMMessage
} from '../agent/types';

/** 配对后的预览/拍照 Profile（宽高比一致）。 */
interface MatchedCameraProfiles {
  preview: camera.Profile;
  photo: camera.Profile;
}

const TAG: string = 'VisionService';

/** PixelMap 创建参数（显式接口，满足 arkts-no-untyped-obj-literals） */
interface PixelMapCreateOptions {
  sampleSize: number;
  rotate: number;
}

/** JPEG 打包参数 */
interface JpegPackOptions {
  format: string;
  quality: number;
}

/** 药品视觉抽取与联网补充的模型 JSON 结构。 */
interface MedicineModelResponse {
  is_medicine?: boolean;
  is_blurry?: boolean;
  name?: string;
  active_ingredient?: string;
  specification?: string;
  dosage?: string;
  indications?: string;
  contraindications?: string;
  adverse_reactions?: string;
  interactions?: string;
  special_population?: string;
  expiration?: string;
  manufacturer?: string;
  observed_text?: string;
  source_summary?: string;
  risk_level?: number;
  risk_hint?: string;
  tts_message?: string;
}

/** 0-1000 归一化坐标，框选药品本体区域。 */
interface MedicineBbox {
  x_min: number;
  y_min: number;
  x_max: number;
  y_max: number;
}

/** 第一阶段：在多物体画面中定位药品。 */
interface MedicineLocateResult {
  medicineFound: boolean;
  medicineLabel: string;
  medicineType: string;
  ignoredObjects: Array<string>;
  regionDescription: string;
  bbox: MedicineBbox | null;
  confidence: number;
}

/** 后台全场景识别：物体与文字块（不直接展示给用户）。 */
interface SceneObjectItem {
  name: string;
  category: string;
}

interface SceneTextBlock {
  source: string;
  text: string;
  isMedicine: boolean;
}

interface SceneScanResult {
  objects: Array<SceneObjectItem>;
  textBlocks: Array<SceneTextBlock>;
  medicineLabel: string;
  nonMedicineObjects: Array<string>;
  medicineOnlyText: string;
}

/** PixelMap 裁剪区域。 */
interface CropRegion {
  x: number;
  y: number;
  size: ImageSize;
}

/** 图像尺寸。 */
interface ImageSize {
  width: number;
  height: number;
}

/**
 * VisionService —— 视觉服务（单例）。
 */
export class VisionService {
  private static instance: VisionService | null = null;
  private context: Context | null = null;
  private llmClient: LLMClient;
  /** 端侧图像分类引擎（端侧优先，可选注入） */
  private localClassifier: LocalImageClassifier | null = null;
  /** 端侧视觉大模型引擎（云端失败兜底，可选注入） */
  private localVlm: LocalVLMEngine | null = null;
  /** 端侧离线 OCR 引擎（断网极速朗读文字，可选注入） */
  private localOcr: LocalOCREngine | null = null;
  /** Base64 编码工具（懒加载） */
  private base64Helper: util.Base64Helper = new util.Base64Helper();
  /** 实时预览会话资源（供 UI 同步显示画面） */
  private liveSession: camera.CaptureSession | null = null;
  private liveCamInput: camera.CameraInput | null = null;
  private livePreviewOutput: camera.PreviewOutput | null = null;
  private livePhotoOutput: camera.PhotoOutput | null = null;
  private livePhotoReceiver: image.ImageReceiver | null = null;
  private liveSessionActive: boolean = false;
  /** 当前实时预览流宽高（传感器坐标系，通常为横屏）。 */
  private livePreviewWidth: number = 0;
  private livePreviewHeight: number = 0;

  private constructor() {
    this.llmClient = LLMClient.getInstance();
  }

  public static getInstance(): VisionService {
    if (VisionService.instance === null) {
      VisionService.instance = new VisionService();
    }
    return VisionService.instance;
  }

  /**
   * 初始化（注入 Context）。
   */
  public init(context: Context): void {
    this.context = context;
  }

  /**
   * 启动实时预览会话，将画面输出到 XComponent Surface。
   * 须先由 UI 层创建 XComponent 并传入 surfaceId。
   */
  public async startLivePreview(surfaceId: string): Promise<void> {
    if (!this.context) {
      throw new Error('VisionService 未初始化 context。');
    }
    if (!surfaceId || surfaceId.length === 0) {
      throw new Error('预览 Surface 无效，无法启动相机。');
    }
    if (this.liveSessionActive) {
      await this.stopLivePreview();
    }
    await this.ensureCameraPermission();

    const camMgr: camera.CameraManager = camera.getCameraManager(this.context);
    const backCam: camera.CameraDevice = this.pickBackCamera(camMgr);
    const capability: camera.CameraOutputCapability = camMgr.getSupportedOutputCapability(backCam);
    if (!capability.previewProfiles || capability.previewProfiles.length === 0) {
      throw new Error('设备不支持预览输出流。');
    }
    if (!capability.photoProfiles || capability.photoProfiles.length === 0) {
      throw new Error('设备不支持拍照输出流。');
    }

    const matched: MatchedCameraProfiles = this.pickMatchedProfiles(
      capability.previewProfiles,
      capability.photoProfiles
    );
    const previewProfile: camera.Profile = matched.preview;
    const photoProfile: camera.Profile = matched.photo;
    Logger.info(TAG,
      `实时预览 profile=${previewProfile.size.width}x${previewProfile.size.height}, ` +
      `拍照 profile=${photoProfile.size.width}x${photoProfile.size.height}`);

    const camInput: camera.CameraInput = camMgr.createCameraInput(backCam);
    await camInput.open();

    const previewOutput: camera.PreviewOutput =
      camMgr.createPreviewOutput(previewProfile, surfaceId);
    const photoReceiver: image.ImageReceiver = image.createImageReceiver(
      photoProfile.size.width,
      photoProfile.size.height,
      image.ImageFormat.JPEG,
      2
    );
    const photoSurfaceId: string = await photoReceiver.getReceivingSurfaceId();
    const photoOutput: camera.PhotoOutput =
      camMgr.createPhotoOutput(photoProfile, photoSurfaceId);

    const session: camera.CaptureSession = camMgr.createCaptureSession();
    session.beginConfig();
    session.addInput(camInput);
    session.addOutput(previewOutput);
    session.addOutput(photoOutput);
    await session.commitConfig();
    await session.start();

    this.liveSession = session;
    this.liveCamInput = camInput;
    this.livePreviewOutput = previewOutput;
    this.livePhotoOutput = photoOutput;
    this.livePhotoReceiver = photoReceiver;
    this.livePreviewWidth = previewProfile.size.width;
    this.livePreviewHeight = previewProfile.size.height;
    this.liveSessionActive = true;
    Logger.info(TAG, '实时预览会话已启动');
  }

  /**
   * 实时预览流宽高比（width/height，传感器坐标系）。
   * UI 竖屏显示时应用 1/ratio 作为容器宽高比，避免拉伸。
   */
  public getLivePreviewAspectRatio(): number {
    if (this.livePreviewWidth <= 0 || this.livePreviewHeight <= 0) {
      return 0;
    }
    return this.livePreviewWidth / this.livePreviewHeight;
  }

  /**
   * 在实时预览会话中拍照，返回 base64 JPEG。
   */
  public async captureFromLiveSession(): Promise<string> {
    if (!this.liveSessionActive || this.livePhotoReceiver === null || this.livePhotoOutput === null) {
      throw new Error('相机预览未启动，无法拍摄。');
    }
    const pixelMap: image.PixelMap =
      await this.captureOnce(this.livePhotoReceiver, this.livePhotoOutput);
    const base64: string = await this.pixelMapToBase64(pixelMap, 92);
    pixelMap.release();
    Logger.info(TAG, `实时预览拍摄成功，base64 长度=${base64.length}`);
    return base64;
  }

  /** 停止并释放实时预览会话。 */
  public async stopLivePreview(): Promise<void> {
    if (!this.liveSessionActive &&
      this.liveSession === null &&
      this.liveCamInput === null) {
      return;
    }
    await this.releaseCameraSession(
      this.liveSession,
      this.liveCamInput,
      this.livePreviewOutput,
      this.livePhotoOutput
    );
    this.liveSession = null;
    this.liveCamInput = null;
    this.livePreviewOutput = null;
    this.livePhotoOutput = null;
    this.livePhotoReceiver = null;
    this.livePreviewWidth = 0;
    this.livePreviewHeight = 0;
    this.liveSessionActive = false;
    Logger.info(TAG, '实时预览会话已释放');
  }

  public isLivePreviewActive(): boolean {
    return this.liveSessionActive;
  }

  /**
   * 采集单帧图像（base64）——后置摄像头静默拍摄。
   *
   * 实现要点（修复全黑帧）：
   * - 鸿蒙拍照会话必须同时配置 PreviewOutput + PhotoOutput，否则 AE/AF 无法收敛，拍出全黑图；
   * - 预览流走隐藏 ImageReceiver（不展示 UI），持续消费帧驱动曝光收敛；
   * - 使用设备 getSupportedOutputCapability 返回的真实 profile，禁止硬编码分辨率；
   * - commitConfig / start 均 await；预热后再 capture。
   *
   * @returns base64 编码的 JPEG 字符串（不含 data:image/jpeg;base64, 前缀）
   */
  public async captureFrame(): Promise<string> {
    if (!this.context) {
      throw new Error('VisionService 未初始化 context。');
    }
    await this.ensureCameraPermission();
    let camInput: camera.CameraInput | null = null;
    let session: camera.CaptureSession | null = null;
    let previewOutput: camera.PreviewOutput | null = null;
    let photoOutput: camera.PhotoOutput | null = null;
    let previewReceiver: image.ImageReceiver | null = null;
    let photoReceiver: image.ImageReceiver | null = null;
    try {
      Logger.info(TAG, '开始获取相机管理器...');
      const camMgr: camera.CameraManager = camera.getCameraManager(this.context);
      const backCam: camera.CameraDevice = this.pickBackCamera(camMgr);
      Logger.info(TAG, '找到摄像头，准备打开');
      camInput = camMgr.createCameraInput(backCam);
      await camInput.open();
      Logger.info(TAG, '相机输入已打开');

      const capability: camera.CameraOutputCapability = camMgr.getSupportedOutputCapability(backCam);
      if (!capability.previewProfiles || capability.previewProfiles.length === 0) {
        throw new Error('设备不支持预览输出流。');
      }
      if (!capability.photoProfiles || capability.photoProfiles.length === 0) {
        throw new Error('设备不支持拍照输出流。');
      }
      const matched: MatchedCameraProfiles = this.pickMatchedProfiles(
        capability.previewProfiles,
        capability.photoProfiles
      );
      const previewProfile: camera.Profile = matched.preview;
      const photoProfile: camera.Profile = matched.photo;
      Logger.info(TAG,
        `预览 profile=${previewProfile.size.width}x${previewProfile.size.height}, ` +
        `拍照 profile=${photoProfile.size.width}x${photoProfile.size.height}`);

      // 预览流：隐藏 ImageReceiver，持续 release 帧，驱动 AE/AF（无 UI 静默拍摄）
      previewReceiver = image.createImageReceiver(
        previewProfile.size.width,
        previewProfile.size.height,
        image.ImageFormat.JPEG,
        8
      );
      const previewSurfaceId: string = await previewReceiver.getReceivingSurfaceId();
      this.bindPreviewDrain(previewReceiver);
      previewOutput = camMgr.createPreviewOutput(previewProfile, previewSurfaceId);

      // 拍照流：ImageReceiver 接收 JPEG
      photoReceiver = image.createImageReceiver(
        photoProfile.size.width,
        photoProfile.size.height,
        image.ImageFormat.JPEG,
        2
      );
      const photoSurfaceId: string = await photoReceiver.getReceivingSurfaceId();
      photoOutput = camMgr.createPhotoOutput(photoProfile, photoSurfaceId);

      session = camMgr.createCaptureSession();
      session.beginConfig();
      session.addInput(camInput);
      session.addOutput(previewOutput);
      session.addOutput(photoOutput);
      await session.commitConfig();
      await session.start();
      Logger.info(TAG, '相机会话已启动（预览+拍照双路）');

      // 预热：等预览帧跑起来，AE 收敛（仅 PhotoOutput 时首帧必黑）
      await this.waitMs(1500);
      Logger.info(TAG, '相机预热完成，准备拍照');

      const pixelMap: image.PixelMap = await this.captureOnce(photoReceiver, photoOutput);

      await this.releaseCameraSession(session, camInput, previewOutput, photoOutput);
      session = null;
      camInput = null;
      previewOutput = null;
      photoOutput = null;

      const base64: string = await this.pixelMapToBase64(pixelMap, 92);
      pixelMap.release();
      Logger.info(TAG, `取帧成功，base64 长度=${base64.length}`);
      return base64;
    } catch (error) {
      await this.releaseCameraSession(session, camInput, previewOutput, photoOutput);
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.error(TAG, `取帧失败: ${msg}`);
      throw new Error('相机不可用，请检查权限设置');
    } finally {
      previewReceiver = null;
      photoReceiver = null;
    }
  }

  private async ensureCameraPermission(): Promise<void> {
    if (!this.context) {
      throw new Error('VisionService 未初始化 context。');
    }
    const hasCam: boolean = await PermissionUtil.hasPermission('ohos.permission.CAMERA');
    if (hasCam) {
      return;
    }
    const granted: Array<Permissions> = await PermissionUtil.requestPermissions(
      this.context,
      ['ohos.permission.CAMERA']
    );
    if (granted.indexOf('ohos.permission.CAMERA') < 0) {
      throw new Error('未授予相机权限，请在系统设置中开启。');
    }
  }

  private pickBackCamera(camMgr: camera.CameraManager): camera.CameraDevice {
    const cams: Array<camera.CameraDevice> = camMgr.getSupportedCameras();
    Logger.info(TAG, `设备支持 ${cams.length} 个摄像头`);
    let backCam: camera.CameraDevice | null = null;
    for (let i = 0; i < cams.length; i++) {
      if (cams[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        backCam = cams[i];
        break;
      }
    }
    if (backCam === null && cams.length > 0) {
      backCam = cams[0];
      Logger.warn(TAG, '未标注后置摄像头，回退使用 cams[0]');
    }
    if (backCam === null) {
      throw new Error('未找到可用摄像头。');
    }
    return backCam;
  }

  private async pixelMapToBase64(pixelMap: image.PixelMap, quality: number): Promise<string> {
    const packOpt: JpegPackOptions = { format: 'image/jpeg', quality: quality };
    const packer: image.ImagePacker = image.createImagePacker();
    const jpegBuffer: ArrayBuffer = await packer.packing(pixelMap, packOpt);
    packer.release();
    const jpegBytes: Uint8Array = new Uint8Array(jpegBuffer);
    return this.base64Helper.encodeToStringSync(jpegBytes);
  }

  /**
   * 选择宽高比一致的预览/拍照 Profile，避免“所见与所拍比例不一致 / 画面拉伸”。
   * 竖屏手机：用 screenHeight/screenWidth 对齐传感器横屏 profile 的 width/height。
   */
  private pickMatchedProfiles(
    previewProfiles: Array<camera.Profile>,
    photoProfiles: Array<camera.Profile>
  ): MatchedCameraProfiles {
    const targetAspect: number = this.getTargetCameraAspect();
    const photoProfile: camera.Profile = this.pickBestProfileByAspect(photoProfiles, targetAspect, 12000000, true);
    const photoAspect: number = this.profileAspect(photoProfile);
    const previewProfile: camera.Profile = this.pickBestProfileByAspect(
      previewProfiles,
      photoAspect,
      8000000,
      false
    );
    Logger.info(TAG,
      `目标宽高比=${targetAspect.toFixed(3)}, ` +
      `拍照=${photoProfile.size.width}x${photoProfile.size.height}(${photoAspect.toFixed(3)}), ` +
      `预览=${previewProfile.size.width}x${previewProfile.size.height}` +
      `(${this.profileAspect(previewProfile).toFixed(3)})`);
    const matched: MatchedCameraProfiles = {
      preview: previewProfile,
      photo: photoProfile
    };
    return matched;
  }

  /** 竖屏全屏预览目标宽高比：屏幕高/宽，对齐相机横屏 profile 的宽/高。 */
  private getTargetCameraAspect(): number {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.width > 0 && d.height > 0) {
        const shortEdge: number = Math.min(d.width, d.height);
        const longEdge: number = Math.max(d.width, d.height);
        return longEdge / shortEdge;
      }
    } catch (error) {
      Logger.warn(TAG, `读取屏幕尺寸失败，回退 16:9: ${
        error instanceof Error ? error.message : JSON.stringify(error)}`);
    }
    return 16 / 9;
  }

  private profileAspect(profile: camera.Profile): number {
    if (profile.size.height <= 0) {
      return 1;
    }
    return profile.size.width / profile.size.height;
  }

  /**
   * 在候选中选宽高比最接近 targetAspect 的 Profile；
   * 比例接近时优先更高像素（且不超过 maxPixels）。
   */
  private pickBestProfileByAspect(
    profiles: Array<camera.Profile>,
    targetAspect: number,
    maxPixels: number,
    preferHigherRes: boolean
  ): camera.Profile {
    let best: camera.Profile = profiles[0];
    let bestScore: number = 1e12;
    let fallback: camera.Profile = profiles[0];
    let fallbackPixels: number = profiles[0].size.width * profiles[0].size.height;

    for (let i = 0; i < profiles.length; i++) {
      const p: camera.Profile = profiles[i];
      const pixels: number = p.size.width * p.size.height;
      if (pixels < fallbackPixels) {
        fallback = p;
        fallbackPixels = pixels;
      }
      if (pixels > maxPixels) {
        continue;
      }
      const aspectDiff: number = Math.abs(this.profileAspect(p) - targetAspect);
      // 宽高比权重远高于分辨率，保证预览/拍照/屏幕比例一致
      const pixelTerm: number = preferHigherRes
        ? (1 - pixels / maxPixels) * 0.05
        : Math.abs(pixels - 1920 * 1080) / (1920 * 1080) * 0.05;
      const score: number = aspectDiff * 1000 + pixelTerm;
      if (score < bestScore) {
        bestScore = score;
        best = p;
      }
    }
    // 全部超过 maxPixels 时退回像素最小的，避免会话配置失败
    if (bestScore >= 1e12) {
      return fallback;
    }
    return best;
  }

  /** 消费预览帧，避免 ImageReceiver 队列堵满并驱动 AE */
  private bindPreviewDrain(receiver: image.ImageReceiver): void {
    receiver.on('imageArrival', () => {
      receiver.readNextImage((err: BusinessError, imgObj: image.Image) => {
        if (err || !imgObj) {
          return;
        }
        try {
          imgObj.release();
        } catch (e) {
          // ignore
        }
      });
    });
  }

  private waitMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 触发一次拍照并解码为 PixelMap。
   */
  private captureOnce(
    receiver: image.ImageReceiver,
    photoOutput: camera.PhotoOutput
  ): Promise<image.PixelMap> {
    return new Promise<image.PixelMap>((resolve, reject) => {
      let hasReceived: boolean = false;
      const timeoutId: number = setTimeout(() => {
        if (!hasReceived) {
          reject(new Error('拍照超时：未收到图像数据'));
        }
      }, 8000);

      receiver.on('imageArrival', () => {
        if (hasReceived) {
          return;
        }
        hasReceived = true;
        clearTimeout(timeoutId);
        Logger.info(TAG, '收到拍照图像到达事件');
        receiver.readNextImage((err: BusinessError, imgObj: image.Image) => {
          if (err) {
            reject(new Error(`读取图像失败: ${err.message}`));
            return;
          }
          imgObj.getComponent(image.ComponentType.JPEG, (e: BusinessError, component: image.Component) => {
            if (e) {
              try {
                imgObj.release();
              } catch (relErr) {
                // ignore
              }
              reject(new Error(`获取 JPEG 组件失败: ${e.message}`));
              return;
            }
            const source: image.ImageSource = image.createImageSource(component.byteBuffer);
            const pmOpt: PixelMapCreateOptions = { sampleSize: 1, rotate: 90 };
            source.createPixelMap(pmOpt, (pe: BusinessError, pm: image.PixelMap) => {
              try {
                imgObj.release();
              } catch (relErr) {
                // ignore
              }
              if (pe) {
                reject(new Error(`创建 PixelMap 失败: ${pe.message}`));
                return;
              }
              resolve(pm);
            });
          });
        });
      });

      try {
        Logger.info(TAG, '触发拍照...');
        photoOutput.capture((capErr: BusinessError) => {
          if (capErr) {
            clearTimeout(timeoutId);
            Logger.error(TAG, `拍照失败: ${capErr.message}`);
            reject(new Error(`拍照失败: ${capErr.message}`));
          } else {
            Logger.info(TAG, '拍照指令已发送');
          }
        });
      } catch (capErr) {
        clearTimeout(timeoutId);
        reject(new Error(`触发拍摄失败: ${capErr instanceof Error ? capErr.message : JSON.stringify(capErr)}`));
      }
    });
  }

  /** 停止会话并释放相机输入/输出 */
  private async releaseCameraSession(
    session: camera.CaptureSession | null,
    camInput: camera.CameraInput | null,
    previewOutput: camera.PreviewOutput | null,
    photoOutput: camera.PhotoOutput | null
  ): Promise<void> {
    if (session !== null) {
      try {
        await session.stop();
      } catch (e) {
        Logger.warn(TAG, `session.stop 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
    if (previewOutput !== null) {
      try {
        await previewOutput.release();
      } catch (e) {
        Logger.warn(TAG, `previewOutput.release 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
    if (photoOutput !== null) {
      try {
        await photoOutput.release();
      } catch (e) {
        Logger.warn(TAG, `photoOutput.release 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
    if (camInput !== null) {
      try {
        camInput.close();
      } catch (e) {
        Logger.warn(TAG, `camInput.close 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
  }

  /**
   * 注入端侧图像分类引擎。
   * 注入后 classifyImage() 优先走端侧 MobileNetV2，失败回退云端 Qwen-VL。
   *
   * @param engine 端侧分类引擎实例或 null
   */
  public setLocalImageClassifier(engine: LocalImageClassifier | null): void {
    this.localClassifier = engine;
    Logger.info(TAG, `端侧分类引擎已${engine ? '注入' : '移除'}，ready=${engine ? engine.ready : false}`);
  }

  /**
   * 注入端侧视觉大模型引擎。
   * 注入后 recognizeMedicine()/analyzeItem() 在云端 Qwen-VL失败时降级本地 VLM。
   *
   * @param engine 端侧视觉引擎实例或 null
   */
  public setLocalVlmEngine(engine: LocalVLMEngine | null): void {
    this.localVlm = engine;
    Logger.info(TAG, `端侧视觉引擎已${engine ? '注入' : '移除'}，ready=${engine ? engine.ready : false}`);
  }

  /**
   * 注入端侧 OCR 引擎。
   *
   * @param engine 端侧 OCR 引擎实例或 null
   */
  public setLocalOcrEngine(engine: LocalOCREngine | null): void {
    this.localOcr = engine;
    Logger.info(TAG, `端侧 OCR 引擎已${engine ? '注入' : '移除'}，ready=${engine ? engine.ready : false}`);
  }

  /**
   * 文档与文字朗读识别（端侧 OCR 优先 + 云端视觉大模型自动兜底）。
   *
   * 1. 若端侧 OCR 引擎就绪，走本地 OCR 毫秒级提取；
   * 2. 若端侧 OCR 未就绪、识别异常或结果为空，自动无缝切换至云端视觉大模型提取文字；
   * 3. 若云端失败，尝试端侧 VLM 最终兜底。
   *
   * @param imageBase64 图像 Base64 字符串
   * @returns 提取出的文档文本内容
   */
  public async readTextOffline(imageBase64: string): Promise<string> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别。');
    }

    // 1) 云端视觉大模型优先（只要有网/有Key，调用 Qwen-VL 进行高精度文字与文档提取）
    if (this.llmClient.isReady()) {
      try {
        const prompt: string =
          '你是为视障和高龄用户服务的文档文字提取助手。请识别并完整提取图片中的所有文字内容（如纸质通知、使用说明、药盒说明、信件、发票、书籍、屏幕文字等）。' +
          '保持原有自然段落顺序换行输出。仅输出提取到的原文内容，不要添加任何Markdown标记、代码块或多余解释。';
        const messages: Array<LLMMessage> = [
          { role: 'user', content: prompt, image_base64: imageBase64 }
        ];
        const cloudText: string = await this.llmClient.chat(messages);
        if (cloudText && cloudText.trim().length > 0) {
          Logger.info(TAG, `云端视觉文字提取成功: ${cloudText.substring(0, 50)}`);
          return cloudText.trim();
        }
        Logger.warn(TAG, '云端视觉模型提取文字返回空，降级端侧 OCR');
      } catch (cloudErr) {
        const cloudMsg: string = cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr);
        Logger.warn(TAG, `云端视觉大模型文字提取失败，降级本地: ${cloudMsg}`);
      }
    }

    // 2) 离线模式降级：端侧离线 OCR
    if (this.localOcr !== null && this.localOcr.ready) {
      try {
        const text = await this.localOcr.recognizeText(imageBase64);
        if (text && text.trim().length > 0) {
          Logger.info(TAG, `端侧离线 OCR 识别成功: ${text.substring(0, 50)}`);
          return text.trim();
        }
        Logger.warn(TAG, '端侧离线 OCR 返回空结果');
      } catch (e) {
        const ocrErr: string = e instanceof Error ? e.message : JSON.stringify(e);
        Logger.warn(TAG, `端侧离线 OCR 识别异常: ${ocrErr}`);
      }
    }

    // 3) 端侧 VLM 最终兜底
    if (this.localVlm !== null && this.localVlm.ready) {
      try {
        Logger.info(TAG, '尝试端侧 VLM 提取文字');
        const vlmText: string = await this.localVlm.analyzeImage(imageBase64, '请识别并提取图中的文字内容。');
        if (vlmText && vlmText.trim().length > 0) {
          return vlmText.trim();
        }
      } catch (vlmErr) {
        Logger.warn(TAG, `端侧 VLM 提取文字失败: ${vlmErr instanceof Error ? vlmErr.message : JSON.stringify(vlmErr)}`);
      }
    }

    throw new Error('未能在画面中识别到清晰的文字，请对准纸质文档后重试。');
  }

  /**
   * 图像分类（端侧 MobileNetV2 优先 + 云端 Qwen-VL 兜底）。
   *
   * P0-3 端侧视觉大模型落地核心方法：
   * 1. 端侧分类引擎已注入且就绪 → 调用 classify() 毫秒级响应；
   * 2. 端侧未注入 / 推理失败 → 调用 LLMClient.analyzeImage() 走后端 Qwen-VL；
   * 3. 全部失败抛中文 Error，由 TaskPlanner 走 TTS 兜底（铁律 3）。
   *
   * @param imageBase64 base64 JPEG 字符串（不含 data:image/jpeg;base64, 前缀）
   * @returns TTS 播报文本（如"画面中可能包含：金毛犬(92.3%)"）
   * @throws Error 端侧与云端均失败时抛中文 Error
   */
  public async classifyImage(imageBase64: string): Promise<string> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别。');
    }

    // 1) 云端优先（只要有 Key）：调用通用物品识别 analyzeItem (Qwen-VL)
    if (this.llmClient.isReady()) {
      try {
        const analyzeResult = await this.analyzeItem(imageBase64);
        if (analyzeResult.tts_message && analyzeResult.tts_message.length > 0) {
          Logger.info(TAG, `大模型视觉识别成功: ${analyzeResult.tts_message}`);
          return analyzeResult.tts_message;
        }
      } catch (cloudErr) {
        const cloudMsg: string = cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr);
        Logger.warn(TAG, `云端多模态识别失败，降级本地: ${cloudMsg}`);
      }
    }

    // 2) 端侧离线兜底：仅在无网/无Key且置信度较高(>=0.55)时使用
    if (this.localClassifier !== null && this.localClassifier.ready) {
      try {
        const results = await this.localClassifier.classify(imageBase64);
        if (results.length > 0 && results[0].confidence >= 0.55) {
          const parts: string[] = results
            .filter((r) => r.confidence >= 0.25)
            .map((r): string => `${r.label}(${(r.confidence * 100).toFixed(1)}%)`);
          const tts: string = `离线模式：画面中可能包含：${parts.join('、')}。联网后可获得详细描述。`;
          Logger.info(TAG, `端侧分类兜底: ${tts}`);
          return tts;
        }
      } catch (localErr) {
        const localMsg: string = localErr instanceof Error ? localErr.message : JSON.stringify(localErr);
        Logger.warn(TAG, `端侧分类失败: ${localMsg}`);
      }
    }

    return '未能识别画面中的物体，请对准主体、避开反光后重试。';
  }

  /**
   * 通用物品识别（基于 Qwen-VL 结构化输出）。
   *
   * system prompt 强制返回 JSON：
   * {item_name, category, key_info, tts_message, is_blurry}
   *
   * 解析失败时降级为 tts_message=raw_text，禁止抛错。
   *
   * @param imageBase64 拍摄的物品图像 base64
   * @returns 视觉识别结构化结果
   */
  public async analyzeItem(imageBase64: string): Promise<VisionAnalyzeResult> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('未提供图像数据，无法识别。');
    }
    const systemPrompt: string =
      '你是为视障与高龄用户服务的视觉识别助手。请基于图片识别物品，严格输出 JSON（不要 markdown 代码块、不要多余解释）：' +
      '{"item_name":"物品名称","category":"类别(medicine/appliance/food/document/unknown)",' +
      '"key_info":"核心要素(已过滤条形码/厂家等冗余信息，仅保留用法用量/按键功能/保质期等关键信息)",' +
      '"tts_message":"可直接朗读的中文口语化文案，无 Markdown 标记",' +
      '"is_blurry":false}。' +
      '若图片模糊或无法识别，必须返回 is_blurry=true 且 tts_message="图片有些模糊，请把手机拿远一点再试一次"。' +
      'tts_message 必须是完整可朗读的口语化中文，例如"这是一个阿莫西林药盒，说明书显示一次吃两粒，一天三次，饭后服用"。';
    const messages: Array<LLMMessage> = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: '请识别图中的物品。', image_base64: imageBase64 }
    ];

    let raw: string;
    try {
      raw = await this.llmClient.chat(messages);
    } catch (cloudErr) {
      // 云端失败 → 本地 VLM → 本地图像分类
      if (this.localVlm !== null && this.localVlm.ready) {
        Logger.warn(TAG, `analyzeItem 云端失败，降级端侧 VLM: ${
          cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr)}`);
        raw = await this.localVlm.analyzeImage(imageBase64, '请识别图中的物品并用中文口语化描述。');
      } else if (this.localClassifier !== null && this.localClassifier.ready) {
        Logger.warn(TAG, `analyzeItem 云端/VLM 不可用，降级端侧图像分类`);
        const clsTts: string = await this.classifyImage(imageBase64);
        return {
          item_name: '',
          category: 'unknown',
          key_info: clsTts,
          tts_message: `本地模式：${clsTts}`,
          is_blurry: false
        };
      } else {
        throw new Error(cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr));
      }
    }

    let result: VisionAnalyzeResult;
    try {
      let cleaned: string = raw.replace(/```json|```/g, '').trim();
      const firstBrace: number = cleaned.indexOf('{');
      const lastBrace: number = cleaned.lastIndexOf('}');
      if (firstBrace >= 0 && lastBrace > firstBrace) {
        cleaned = cleaned.substring(firstBrace, lastBrace + 1);
      }
      const parsed = JSON.parse(cleaned) as Record<string, Object>;
      result = {
        item_name: (parsed['item_name'] as string) ?? '',
        category: (parsed['category'] as string) ?? 'unknown',
        key_info: (parsed['key_info'] as string) ?? '',
        tts_message: (parsed['tts_message'] as string) ?? raw,
        is_blurry: Boolean(parsed['is_blurry'] ?? false)
      };
    } catch (parseError) {
      Logger.warn(TAG, `analyzeItem JSON 解析失败，降级为纯文本: ${raw}`);
      result = {
        item_name: '',
        category: 'unknown',
        key_info: '',
        tts_message: raw,
        is_blurry: false
      };
    }
    return result;
  }

  /**
   * 触发振动。
   *
   * @param durationMs 持续毫秒
   */
  public async vibrate(durationMs: number): Promise<void> {
    try {
      vibrator.startVibration({ type: 'time', duration: durationMs }, { id: 0, usage: 'touch' });
    } catch (error) {
      Logger.warn(TAG, `振动失败: ${JSON.stringify(error)}`);
    }
  }

  /**
   * OCR 文字识别（基于云端视觉分析，向后兼容）。
   * 实际调用 analyzeItem，从 key_info 中提取文字内容。
   *
   * @param imageBase64 base64 JPEG 字符串
   * @returns 识别到的文字内容
   */
  public async ocr(imageBase64: string): Promise<string> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别文字。');
    }
    return await this.readTextOffline(imageBase64);
  }

  /**
   * 物体检测（基于图像分类，向后兼容）。
   * 实际调用 classifyImage，返回分类结果作为物体检测结果。
   *
   * @param imageBase64 base64 JPEG 字符串
   * @returns 检测到的物体描述
   */
  public async objectDetect(imageBase64: string): Promise<string> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别物体。');
    }
    try {
      return await this.classifyImage(imageBase64);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      throw new Error(`物体识别失败：${msg}`);
    }
  }

  /**
   * 人脸检测（基于云端视觉分析，向后兼容）。
   * 实际调用 analyzeItem 判断是否有人脸。
   *
   * @param imageBase64 base64 JPEG 字符串
   * @returns 人脸检测结果描述
   */
  public async faceDetect(imageBase64: string): Promise<string> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别人脸。');
    }
    try {
      const result: VisionAnalyzeResult = await this.analyzeItem(imageBase64);
      if (result.category === 'person' || result.item_name.includes('人')) {
        return `检测到人脸：${result.item_name}`;
      }
      return '未检测到人脸。';
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      throw new Error(`人脸识别失败：${msg}`);
    }
  }

  /**
   * 药品专用高精度识别：
   * 基于 Qwen-VL 多模态大模型单阶段提取药品名称、规格、用法、适应症与禁忌，
   * 并结合端侧急救药品知识库进行安全校对，生成通俗易懂的口语化播报。
   */
  public async recognizeMedicine(imageBase64: string): Promise<MedicineRecognitionResult> {
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别药品。');
    }

    // 1) 云端 Qwen-VL 单阶段端到端高精度识别（主链路）
    if (this.llmClient.isReady()) {
      try {
        Logger.info(TAG, '启动云端 Qwen-VL 单阶段药品高精度识别');
        const medicinePrompt: string =
          '你是专为视障与高龄老人设计的药品识别专家。请仔细观察这张图片，识别图中的药品包装、药瓶或药板。\n' +
          '严格输出 JSON 格式（不要包含 markdown 代码块标记，不要包含多余解释）：\n' +
          '{\n' +
          '  "is_medicine": true,\n' +
          '  "name": "药品通用名（如：布洛芬缓释胶囊）",\n' +
          '  "active_ingredient": "有效成分",\n' +
          '  "specification": "规格",\n' +
          '  "dosage": "用法用量",\n' +
          '  "indications": "适应症/主要功效",\n' +
          '  "contraindications": "禁忌与注意事项",\n' +
          '  "expiration": "有效期或生产日期",\n' +
          '  "manufacturer": "生产厂家",\n' +
          '  "observed_text": "在包装上清晰看到的关键文字",\n' +
          '  "tts_message": "面向老人或视障者的自然口语化播报，包含药名、主要功效、用法用量与核心禁忌，120字内。"\n' +
          '}\n' +
          '规则：\n' +
          '1. 如果画面中完全没有药品（例如仅有电脑、手机、文具、餐食等）：\n' +
          '   必须返回 {"is_medicine": false, "name": "", "tts_message": "画面中未检测到药品，请将药盒或药瓶正对镜头后重试。"}\n' +
          '2. 如果画面中有疑似药盒但文字严重反光或模糊看不清：\n' +
          '   返回 {"is_medicine": true, "name": "", "tts_message": "检测到药盒，但包装文字有些模糊或反光，请把手机拿近一点并稳住镜头重试。"}\n' +
          '3. 忽略背景中的电脑、桌面杂物，不要将背景文字误认为药名。';

        const messages: Array<LLMMessage> = [
          { role: 'user', content: medicinePrompt, image_base64: imageBase64 }
        ];

        const raw: string = await this.llmClient.chat(messages);
        const parsed: MedicineModelResponse = this.parseMedicineJson(raw);
        Logger.info(TAG, `Qwen-VL 药品抽取成功: name=${parsed.name}, is_medicine=${parsed.is_medicine}`);

        if (parsed.is_medicine === false) {
          const fallbackInfo: MedicineInfo = {
            name: '',
            observedText: '',
            isMedicine: false,
            riskHint: '画面未对准药品'
          };
          return {
            info: fallbackInfo,
            tts: parsed.tts_message || '画面中未检测到药品，请将药盒正对镜头后重试。'
          };
        }

        let info: MedicineInfo = this.toMedicineInfo(parsed);
        let tts: string = parsed.tts_message ?? '';

        // 如果识别出药名，尝试从端侧急救药品知识库增强核对
        if (info.name && info.name.trim().length > 0) {
          try {
            const kbMatch = await ElderlyMedicineKb.query(info.name.trim());
            if (kbMatch !== null && kbMatch.fatalWarning) {
              info.riskLevel = 2;
              info.riskHint = kbMatch.fatalWarning;
              tts += ` 特别警示：${kbMatch.fatalWarning}`;
            }
          } catch (kbErr) {
            // ignore
          }
        }

        if (tts.length === 0) {
          tts = this.buildMedicineTts(info);
        }

        return { info: info, tts: tts };
      } catch (cloudErr) {
        const cloudMsg: string = cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr);
        Logger.warn(TAG, `云端 Qwen-VL 药品识别失败，降级本地: ${cloudMsg}`);
      }
    }

    // 2) 离线模式降级：尝试端侧 OCR + SQLite 知识库
    if (this.localOcr !== null && this.localOcr.ready) {
      try {
        Logger.info(TAG, '离线模式：尝试端侧 OCR 识别药名');
        const ocrText: string = await this.localOcr.recognizeText(imageBase64);
        if (ocrText && ocrText.trim().length > 0) {
          const kbMatch = await ElderlyMedicineKb.query(ocrText.trim());
          if (kbMatch !== null) {
            const kbTts: string = ElderlyMedicineKb.buildTtsString(kbMatch);
            return {
              info: {
                name: kbMatch.name,
                observedText: ocrText,
                isMedicine: true,
                riskHint: '离线应急知识库匹配'
              },
              tts: kbTts
            };
          }
        }
      } catch (ocrErr) {
        // ignore
      }
    }

    // 3) 离线无法识别的清晰提示（绝不返回天鹅绒）
    return {
      info: {
        name: '',
        observedText: '',
        isMedicine: false,
        riskHint: '离线模式无法识别药品'
      },
      tts: '当前网络不可用或药品识别超时，请确保连接网络并将药盒正对镜头后重试。'
    };
  }

  /** 围绕当前识别药品进行联网追问，回答文本同时作为 TTS 文案。 */
  public async answerMedicineQuestion(
    info: MedicineInfo,
    question: string
  ): Promise<MedicineQuestionResult> {
    if (question.trim().length === 0) {
      throw new Error('请输入关于当前药品的问题。');
    }
    const prompt: string =
      '你是谨慎的药品信息助手。请联网核对后，只围绕“当前药品”回答用户问题。' +
      '优先依据国家药监局、正式说明书、生产厂家或权威医疗机构。' +
      '图片读取内容优先于搜索摘要；不得猜测包装上未确认的剂量，不诊断疾病，不替代医生或药师。' +
      '若涉及过量、严重过敏、呼吸困难、意识异常等危险情况，应先建议立即停药并联系120或就医。' +
      '请用分段中文回答，每段一行，格式示例：' +
      '概述：一句话说明。\n用途：...\n用法：...\n注意：...\n安全提示：...。' +
      '不要使用 Markdown 符号，控制在300字内，适合直接朗读。' +
      '当前药品资料：' + JSON.stringify(info) + '。用户问题：' + question.trim();
    const answer: string = await this.llmClient.chatWithSearch([
      { role: 'user', content: prompt }
    ]);
    const cleaned: string = answer.replace(/[*#`]/g, '').trim();
    const filteredAnswer: string = this.sanitizeTextByIgnoredObjects(cleaned, [
      '电脑', '笔记本', '键盘', '屏幕', '手机', '平板', '显示器'
    ]);
    const finalAnswer: string = filteredAnswer.length > 0 ? filteredAnswer : cleaned;
    return { answer: finalAnswer, tts: finalAnswer };
  }

  /**
   * 后台全场景识别：先识别画面中所有物体和文字，结果仅供内部筛选，不直接给用户。
   */
  private async scanFullSceneContent(imageBase64: string): Promise<SceneScanResult> {
    const scanPrompt: string =
      '你是后台全场景识别器，识别结果不会直接展示给用户，仅供后续筛选药品信息。' +
      '请完整识别照片中所有物体，以及每个物体上的可见文字。' +
      '严格返回 JSON（不要 markdown）：' +
      '{"objects":[{"name":"六神花露水","category":"medicine"},{"name":"笔记本电脑","category":"electronics"}],' +
      '"text_blocks":[{"source":"六神花露水瓶身","text":"逐字抄录","is_medicine":true},' +
      '{"source":"电脑屏幕","text":"逐字抄录","is_medicine":false}],' +
      '"medicine_object":"六神花露水","non_medicine_objects":["笔记本电脑"],' +
      '"medicine_only_text":"仅汇总 is_medicine=true 的文字块"}。' +
      '规则：花露水、创可贴、眼药水、消毒用品、药盒、药瓶、药板、说明书都算 medicine；' +
      '电脑、手机、键盘、书籍、家具等算 non_medicine；medicine_only_text 不得含非药品文字。';
    try {
      const raw: string = await this.llmClient.chat([
        { role: 'user', content: scanPrompt, image_base64: imageBase64 }
      ]);
      return this.parseSceneScanJson(raw);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `后台全场景识别失败，继续药品定位流程: ${msg}`);
      return {
        objects: [],
        textBlocks: [],
        medicineLabel: '',
        nonMedicineObjects: [],
        medicineOnlyText: ''
      };
    }
  }

  /** 用全场景扫描结果补充定位信息。 */
  private mergeLocateWithSceneScan(
    locate: MedicineLocateResult,
    scan: SceneScanResult
  ): MedicineLocateResult {
    const mergedIgnored: Array<string> = this.mergeIgnoredLists(locate.ignoredObjects, scan.nonMedicineObjects);
    let medicineLabel: string = locate.medicineLabel;
    if (scan.medicineLabel.length > 0) {
      medicineLabel = scan.medicineLabel;
    }
    let medicineFound: boolean = locate.medicineFound;
    if (scan.medicineLabel.length > 0 || scan.medicineOnlyText.length > 0) {
      medicineFound = true;
    }
    return {
      medicineFound: medicineFound,
      medicineLabel: medicineLabel,
      medicineType: locate.medicineType,
      ignoredObjects: mergedIgnored,
      regionDescription: locate.regionDescription,
      bbox: locate.bbox,
      confidence: Math.max(locate.confidence, scan.medicineLabel.length > 0 ? 0.8 : 0)
    };
  }

  /**
   * 输出筛选：从全量识别结果中只保留药品相关内容，非药品信息一律不输出给用户。
   */
  private async filterMedicineOutputForUser(
    info: MedicineInfo,
    tts: string,
    scan: SceneScanResult,
    locate: MedicineLocateResult
  ): Promise<MedicineRecognitionResult> {
    const ignored: Array<string> = this.mergeIgnoredLists(scan.nonMedicineObjects, locate.ignoredObjects);
    for (let i = 0; i < scan.objects.length; i++) {
      const obj: SceneObjectItem = scan.objects[i];
      if (obj.category !== 'medicine' && obj.name.length > 0 && ignored.indexOf(obj.name) < 0) {
        ignored.push(obj.name);
      }
    }

    let filteredInfo: MedicineInfo = this.sanitizeMedicineInfo(info, ignored);
    if (scan.medicineOnlyText.length > 0) {
      filteredInfo.observedText = scan.medicineOnlyText;
    }
    let filteredTts: string = this.sanitizeTextByIgnoredObjects(tts, ignored);

    if (ignored.length > 0 || scan.textBlocks.length > 0) {
      try {
        const polished = await this.polishMedicineOutputWithLlm(
          filteredInfo,
          filteredTts,
          locate.medicineLabel || scan.medicineLabel,
          ignored
        );
        filteredInfo = polished.info;
        filteredTts = polished.tts;
      } catch (filterError) {
        Logger.warn(TAG, `药品输出 LLM 筛选失败，使用规则筛选结果: ${
          filterError instanceof Error ? filterError.message : JSON.stringify(filterError)}`);
      }
    }

    Logger.info(TAG, `药品输出筛选完成，已丢弃非药品物体: ${ignored.join('、')}`);
    return { info: filteredInfo, tts: filteredTts };
  }

  /** LLM 二次筛选：确保给用户的文案只含药品信息。 */
  private async polishMedicineOutputWithLlm(
    info: MedicineInfo,
    tts: string,
    medicineLabel: string,
    ignored: Array<string>
  ): Promise<MedicineRecognitionResult> {
    const filterPrompt: string =
      '以下是药品识别结果，可能混入了电脑、键盘等非药品物体的文字或描述。' +
      `目标药品：${medicineLabel || '画面中的药品'}。` +
      `必须完全删除以下来源的内容：${ignored.join('、')}。` +
      '请只保留与目标药品相关的字段和表述，非药品内容一律清空或删除。' +
      'tts_message 和 observed_text 不得提及任何非药品物体。' +
      '严格返回 JSON：' +
      '{"name":"","active_ingredient":"","specification":"","dosage":"","indications":"",' +
      '"contraindications":"","adverse_reactions":"","interactions":"","special_population":"",' +
      '"expiration":"","manufacturer":"","observed_text":"","risk_hint":"","tts_message":""}。' +
      '待筛选内容：' + JSON.stringify({ info: info, tts: tts });
    const raw: string = await this.llmClient.chat([
      { role: 'user', content: filterPrompt }
    ]);
    const parsed: MedicineModelResponse = this.parseMedicineJson(raw);
    const filteredInfo: MedicineInfo = this.mergeMedicineInfo(info, parsed);
    if (parsed.observed_text && parsed.observed_text.length > 0) {
      filteredInfo.observedText = parsed.observed_text;
    }
    filteredInfo.isMedicine = true;
    let filteredTts: string = parsed.tts_message ?? '';
    if (filteredTts.length === 0) {
      filteredTts = this.sanitizeTextByIgnoredObjects(tts, ignored);
    }
    filteredTts = this.sanitizeTextByIgnoredObjects(filteredTts, ignored);
    return { info: filteredInfo, tts: filteredTts };
  }

  private sanitizeMedicineInfo(info: MedicineInfo, ignored: Array<string>): MedicineInfo {
    return {
      name: this.sanitizeTextByIgnoredObjects(info.name ?? '', ignored),
      activeIngredient: this.sanitizeTextByIgnoredObjects(info.activeIngredient ?? '', ignored),
      specification: this.sanitizeTextByIgnoredObjects(info.specification ?? '', ignored),
      dosage: this.sanitizeTextByIgnoredObjects(info.dosage ?? '', ignored),
      indications: this.sanitizeTextByIgnoredObjects(info.indications ?? '', ignored),
      contraindications: this.sanitizeTextByIgnoredObjects(info.contraindications ?? '', ignored),
      adverseReactions: this.sanitizeTextByIgnoredObjects(info.adverseReactions ?? '', ignored),
      interactions: this.sanitizeTextByIgnoredObjects(info.interactions ?? '', ignored),
      specialPopulation: this.sanitizeTextByIgnoredObjects(info.specialPopulation ?? '', ignored),
      expiration: this.sanitizeTextByIgnoredObjects(info.expiration ?? '', ignored),
      manufacturer: this.sanitizeTextByIgnoredObjects(info.manufacturer ?? '', ignored),
      riskLevel: info.riskLevel,
      riskHint: this.sanitizeTextByIgnoredObjects(info.riskHint ?? '', ignored),
      observedText: this.sanitizeTextByIgnoredObjects(info.observedText ?? '', ignored),
      sourceSummary: this.sanitizeTextByIgnoredObjects(info.sourceSummary ?? '', ignored),
      isMedicine: true
    };
  }

  /** 按句删除含非药品物体关键词的内容。 */
  private sanitizeTextByIgnoredObjects(text: string, ignored: Array<string>): string {
    if (!text || text.trim().length === 0) {
      return '';
    }
    const keywords: Array<string> = ['电脑', '笔记本', '键盘', '屏幕', '显示器', '手机', '平板', '桌面', '背景'];
    for (let i = 0; i < ignored.length; i++) {
      if (ignored[i].length > 0 && keywords.indexOf(ignored[i]) < 0) {
        keywords.push(ignored[i]);
      }
    }
    const parts: Array<string> = text.split(/(?<=[。！？；\n])/);
    const kept: Array<string> = [];
    for (let i = 0; i < parts.length; i++) {
      const sentence: string = parts[i];
      if (this.sentenceMentionsIgnored(sentence, keywords)) {
        continue;
      }
      kept.push(sentence);
    }
    const result: string = kept.join('').trim();
    return result.length > 0 ? result : text;
  }

  private sentenceMentionsIgnored(sentence: string, keywords: Array<string>): boolean {
    for (let i = 0; i < keywords.length; i++) {
      if (keywords[i].length >= 2 && sentence.indexOf(keywords[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private mergeIgnoredLists(listA: Array<string>, listB: Array<string>): Array<string> {
    const merged: Array<string> = [];
    for (let i = 0; i < listA.length; i++) {
      if (listA[i].length > 0 && merged.indexOf(listA[i]) < 0) {
        merged.push(listA[i]);
      }
    }
    for (let i = 0; i < listB.length; i++) {
      if (listB[i].length > 0 && merged.indexOf(listB[i]) < 0) {
        merged.push(listB[i]);
      }
    }
    return merged;
  }

  private parseSceneScanJson(raw: string): SceneScanResult {
    let cleaned: string = raw.replace(/```json|```/g, '').trim();
    const firstBrace: number = cleaned.indexOf('{');
    const lastBrace: number = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    let parsed: Record<string, Object> = {};
    try {
      parsed = JSON.parse(cleaned) as Record<string, Object>;
    } catch (e) {
      Logger.warn(TAG, `解析场景扫描 JSON 失败: ${e instanceof Error ? e.message : 'SyntaxError'}`);
    }
    const objects: Array<SceneObjectItem> = [];
    const objectsRaw: Object | undefined = parsed['objects'];
    if (objectsRaw instanceof Array) {
      for (let i = 0; i < objectsRaw.length; i++) {
        const item = objectsRaw[i] as Record<string, Object>;
        objects.push({
          name: (item['name'] as string) ?? '',
          category: (item['category'] as string) ?? 'unknown'
        });
      }
    }
    const textBlocks: Array<SceneTextBlock> = [];
    const blocksRaw: Object | undefined = parsed['text_blocks'];
    if (blocksRaw instanceof Array) {
      for (let i = 0; i < blocksRaw.length; i++) {
        const block = blocksRaw[i] as Record<string, Object>;
        textBlocks.push({
          source: (block['source'] as string) ?? '',
          text: (block['text'] as string) ?? '',
          isMedicine: Boolean(block['is_medicine'] ?? false)
        });
      }
    }
    const nonMedicineRaw: Object | undefined = parsed['non_medicine_objects'];
    const nonMedicineObjects: Array<string> = [];
    if (nonMedicineRaw instanceof Array) {
      for (let i = 0; i < nonMedicineRaw.length; i++) {
        if (typeof nonMedicineRaw[i] === 'string') {
          nonMedicineObjects.push(nonMedicineRaw[i] as string);
        }
      }
    }
    let medicineOnlyText: string = (parsed['medicine_only_text'] as string) ?? '';
    if (medicineOnlyText.length === 0) {
      const medicineTexts: Array<string> = [];
      for (let i = 0; i < textBlocks.length; i++) {
        if (textBlocks[i].isMedicine && textBlocks[i].text.length > 0) {
          medicineTexts.push(textBlocks[i].text);
        }
      }
      medicineOnlyText = medicineTexts.join('\n');
    }
    return {
      objects: objects,
      textBlocks: textBlocks,
      medicineLabel: (parsed['medicine_object'] as string) ?? '',
      nonMedicineObjects: nonMedicineObjects,
      medicineOnlyText: medicineOnlyText
    };
  }

  /**
   * 第一阶段：在多物体场景中找出药品，并明确需忽略的非药品物体。
   */
  private async locateMedicineInScene(imageBase64: string): Promise<MedicineLocateResult> {
    const locatePrompt: string =
      '你是药品定位助手。照片中可能同时出现多个物体（如电脑、手机、键盘、书籍、花露水、药盒等）。' +
      '第一步：找出哪个物体属于药品/药械/外用药品（含花露水、创可贴、眼药水、消毒用品、药盒、药瓶、药板、说明书）。' +
      '第二步：列出必须完全忽略的非药品物体。' +
      '第三步：给出药品在画面中的位置和包围框。' +
      '严格返回 JSON（不要 markdown）：' +
      '{"medicine_found":true,"medicine_label":"六神花露水","medicine_type":"外用驱蚊花露水",' +
      '"ignored_objects":["笔记本电脑","键盘"],"region_description":"画面左侧绿色小瓶",' +
      '"bbox":{"x_min":100,"y_min":200,"x_max":450,"y_max":900},"confidence":0.95}。' +
      '规则：bbox 为 0-1000 归一化坐标，只框药品本体及标签；无药品时 medicine_found=false；' +
      '不要把电脑屏幕、键盘、桌面杂物上的文字当成药品。';
    try {
      const raw: string = await this.llmClient.chat([
        { role: 'user', content: locatePrompt, image_base64: imageBase64 }
      ]);
      return this.parseLocateJson(raw);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `药品定位失败，回退为全图识别: ${msg}`);
      return {
        medicineFound: true,
        medicineLabel: '画面中的药品',
        medicineType: 'unknown',
        ignoredObjects: [],
        regionDescription: '未精确定位',
        bbox: null,
        confidence: 0
      };
    }
  }

  /**
   * 第二阶段：只读取已定位药品上的包装文字，严禁混入其他物体文字。
   */
  private async extractMedicineContent(
    imageBase64: string,
    locate: MedicineLocateResult
  ): Promise<MedicineModelResponse> {
    const ignoredText: string = locate.ignoredObjects.length > 0
      ? locate.ignoredObjects.join('、')
      : '电脑、手机、键盘、书籍等非药品物体';
    const extractionPrompt: string =
      `照片中有多物体。目标药品：${locate.medicineLabel}（${locate.regionDescription}，类型：${locate.medicineType}）。` +
      `必须完全忽略：${ignoredText}。` +
      '只逐字读取目标药品包装/瓶身/说明书上的中文、英文、数字、批准文号、规格、用法、厂家。' +
      '严禁读取被忽略物体上的任何文字，不要描述背景，不要凭常识补全看不清的内容。' +
      '严格返回 JSON：' +
      '{"is_medicine":true,"is_blurry":false,"name":"","active_ingredient":"","specification":"",' +
      '"dosage":"","indications":"","contraindications":"","adverse_reactions":"","expiration":"",' +
      '"manufacturer":"","observed_text":"仅来自目标药品的逐字抄录"}。' +
      '不是药品 is_medicine=false；目标药品文字模糊 is_blurry=true。';
    try {
      const extractionRaw: string = await this.llmClient.chat([
        { role: 'user', content: extractionPrompt, image_base64: imageBase64 }
      ]);
      return this.parseMedicineJson(extractionRaw);
    } catch (firstError) {
      Logger.warn(TAG, `药品内容抽取失败，启动 OCR 重试: ${
        firstError instanceof Error ? firstError.message : JSON.stringify(firstError)}`);
    }

    const retryPrompt: string =
      `目标药品是「${locate.medicineLabel}」，位置：${locate.regionDescription}。` +
      `忽略：${ignoredText}。` +
      '先把目标药品标签上所有可见文字逐字抄到 observed_text，再从中提取 name、成分、规格、用法。' +
      '不要把电脑或其他物体上的字写进 observed_text。严格返回 JSON：' +
      '{"is_medicine":true,"is_blurry":false,"name":"","active_ingredient":"","specification":"",' +
      '"dosage":"","indications":"","contraindications":"","adverse_reactions":"","expiration":"",' +
      '"manufacturer":"","observed_text":""}。';
    const retryRaw: string = await this.llmClient.chat([
      { role: 'user', content: retryPrompt, image_base64: imageBase64 }
    ]);
    return this.parseMedicineJson(retryRaw);
  }

  private parseLocateJson(raw: string): MedicineLocateResult {
    let cleaned: string = raw.replace(/```json|```/g, '').trim();
    const firstBrace: number = cleaned.indexOf('{');
    const lastBrace: number = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    let parsed: Record<string, Object> = {};
    try {
      parsed = JSON.parse(cleaned) as Record<string, Object>;
    } catch (e) {
      Logger.warn(TAG, `解析药品定位 JSON 失败: ${e instanceof Error ? e.message : 'SyntaxError'}`);
    }
    const ignoredRaw: Object | undefined = parsed['ignored_objects'];
    const ignoredList: Array<string> = [];
    if (ignoredRaw instanceof Array) {
      for (let i = 0; i < ignoredRaw.length; i++) {
        if (typeof ignoredRaw[i] === 'string') {
          ignoredList.push(ignoredRaw[i] as string);
        }
      }
    }
    const bboxRaw: Object | undefined = parsed['bbox'];
    let bbox: MedicineBbox | null = null;
    if (bboxRaw !== undefined && bboxRaw !== null) {
      const box = bboxRaw as Record<string, Object>;
      const xMin: number = Number(box['x_min'] ?? -1);
      const yMin: number = Number(box['y_min'] ?? -1);
      const xMax: number = Number(box['x_max'] ?? -1);
      const yMax: number = Number(box['y_max'] ?? -1);
      if (xMax > xMin && yMax > yMin && xMin >= 0 && yMin >= 0 && xMax <= 1000 && yMax <= 1000) {
        bbox = { x_min: xMin, y_min: yMin, x_max: xMax, y_max: yMax };
      }
    }
    return {
      medicineFound: Boolean(parsed['medicine_found'] ?? false),
      medicineLabel: (parsed['medicine_label'] as string) ?? '',
      medicineType: (parsed['medicine_type'] as string) ?? '',
      ignoredObjects: ignoredList,
      regionDescription: (parsed['region_description'] as string) ?? '',
      bbox: bbox,
      confidence: Number(parsed['confidence'] ?? 0)
    };
  }

  /** 按归一化 bbox 裁剪药品区域，失败时返回 null 走全图识别。 */
  private async cropBase64ByBbox(base64: string, bbox: MedicineBbox): Promise<string | null> {
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await this.decodeBase64ToPixelMap(base64);
      const info = await pixelMap.getImageInfo();
      const imgW: number = info.size.width;
      const imgH: number = info.size.height;
      const padRatio: number = 0.06;
      let xMinRatio: number = bbox.x_min / 1000;
      let yMinRatio: number = bbox.y_min / 1000;
      let xMaxRatio: number = bbox.x_max / 1000;
      let yMaxRatio: number = bbox.y_max / 1000;
      const padW: number = (xMaxRatio - xMinRatio) * padRatio;
      const padH: number = (yMaxRatio - yMinRatio) * padRatio;
      xMinRatio = Math.max(0, xMinRatio - padW);
      yMinRatio = Math.max(0, yMinRatio - padH);
      xMaxRatio = Math.min(1, xMaxRatio + padW);
      yMaxRatio = Math.min(1, yMaxRatio + padH);
      const x: number = Math.floor(xMinRatio * imgW);
      const y: number = Math.floor(yMinRatio * imgH);
      const cropW: number = Math.max(1, Math.min(Math.ceil((xMaxRatio - xMinRatio) * imgW), imgW - x));
      const cropH: number = Math.max(1, Math.min(Math.ceil((yMaxRatio - yMinRatio) * imgH), imgH - y));
      const region: CropRegion = {
        x: x,
        y: y,
        size: { width: cropW, height: cropH }
      };
      await pixelMap.crop(region);
      const croppedBase64: string = await this.pixelMapToBase64(pixelMap, 92);
      return croppedBase64;
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `药品区域裁剪失败: ${msg}`);
      return null;
    } finally {
      if (pixelMap !== null) {
        try {
          pixelMap.release();
        } catch (releaseErr) {
          // ignore
        }
      }
    }
  }

  private decodeBase64ToPixelMap(base64: string): Promise<image.PixelMap> {
    return new Promise<image.PixelMap>((resolve, reject) => {
      try {
        const jpegBytes: Uint8Array = this.base64Helper.decodeSync(base64);
        const source: image.ImageSource = image.createImageSource(jpegBytes.buffer);
        const pmOpt: PixelMapCreateOptions = { sampleSize: 1, rotate: 0 };
        source.createPixelMap(pmOpt, (err: BusinessError, pm: image.PixelMap) => {
          if (err) {
            reject(new Error(`解码图像失败: ${err.message}`));
            return;
          }
          resolve(pm);
        });
      } catch (error) {
        reject(error);
      }
    });
  }

  private parseMedicineJson(raw: string): MedicineModelResponse {
    let cleaned: string = raw.replace(/```json|```/g, '').trim();
    const firstBrace: number = cleaned.indexOf('{');
    const lastBrace: number = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    try {
      return JSON.parse(cleaned) as MedicineModelResponse;
    } catch (err) {
      Logger.warn(TAG, `解析药品识别 JSON 失败: ${err instanceof Error ? err.message : 'SyntaxError'}，原文: ${raw}`);
      return {};
    }
  }

  private toMedicineInfo(model: MedicineModelResponse): MedicineInfo {
    return {
      name: model.name ?? '',
      activeIngredient: model.active_ingredient ?? '',
      specification: model.specification ?? '',
      dosage: model.dosage ?? '',
      indications: model.indications ?? '',
      contraindications: model.contraindications ?? '',
      adverseReactions: model.adverse_reactions ?? '',
      interactions: model.interactions ?? '',
      specialPopulation: model.special_population ?? '',
      expiration: model.expiration ?? '',
      manufacturer: model.manufacturer ?? '',
      riskLevel: model.risk_level ?? 0,
      riskHint: model.risk_hint ?? '',
      observedText: model.observed_text ?? '',
      sourceSummary: model.source_summary ?? '',
      isMedicine: model.is_medicine ?? true
    };
  }

  private mergeMedicineInfo(base: MedicineInfo, model: MedicineModelResponse): MedicineInfo {
    return {
      name: base.name || model.name || '',
      activeIngredient: model.active_ingredient ?? base.activeIngredient,
      specification: base.specification || model.specification || '',
      dosage: base.dosage || model.dosage || '',
      indications: model.indications ?? base.indications,
      contraindications: model.contraindications ?? base.contraindications,
      adverseReactions: model.adverse_reactions ?? base.adverseReactions,
      interactions: model.interactions ?? base.interactions,
      specialPopulation: model.special_population ?? base.specialPopulation,
      expiration: base.expiration || model.expiration || '',
      manufacturer: base.manufacturer || model.manufacturer || '',
      riskLevel: model.risk_level ?? base.riskLevel,
      riskHint: model.risk_hint ?? base.riskHint,
      observedText: base.observedText,
      sourceSummary: model.source_summary ?? '',
      isMedicine: true
    };
  }

  private buildMedicineTts(info: MedicineInfo): string {
    let result: string = `识别到${info.name ?? '一种药品'}。`;
    if (info.indications && info.indications.length > 0) {
      result += `通常用于${info.indications}。`;
    }
    if (info.dosage && info.dosage.length > 0) {
      result += `包装显示的用法是${info.dosage}。`;
    } else {
      result += '图片中没有看清明确用法用量，请查看说明书或咨询医生药师。';
    }
    if (info.riskHint && info.riskHint.length > 0) {
      result += `注意：${info.riskHint}。`;
    }
    return result + '请以药品包装说明书和医生或药师指导为准。';
  }
}
