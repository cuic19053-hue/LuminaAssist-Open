/**
 * @file LocalOCREngine.ets
 * @module services
 * @description 端侧离线极速 OCR 引擎（PaddleOCR PP-OCRv3 FP32 标准版转 FP16，det + rec 双模型）。
 *
 * 定位：20MB 级别的纯视觉“速读员”。
 * 职责：专职处理信件朗读、快递单读取等纯文字提取任务。
 * 优势：单图处理 < 300ms，极度省电，断网可用，绝不唤醒视觉大模型。
 *
 * 管线（真实实现）：
 *   base64 -> PixelMap(原图) -> det 预处理(320x320, CHW, (x/255-0.5)/0.5)
 *   -> DBNet 概率图 -> 连通域文本框 -> 映射回原图 -> 阅读顺序排序
 *   -> 逐行裁剪 -> rec 预处理(48x320) -> CRNN -> CTC 贪心解码 -> 文本
 *
 * 模型资产（由 scripts/get_model_weights.ps1 + convert_models.sh ocr 生成）：
 *   rawfile/models/paddle_ocr_det_fp16.ms   检测模型 [1,3,320,320]（~1.2MB）
 *   rawfile/models/paddle_ocr_rec_fp16.ms   识别模型 [1,3,48,320]（~5.3MB）
 *   rawfile/models/ppocr_keys_v1.txt        识别字符表（6623 类 + blank）
 */

import mindSporeLite from '@ohos.ai.mindSporeLite';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Logger } from '../utils/Logger';
import { LLMMessage } from '../agent/types';
import { LocalEngine } from './LLMClient';
import {
  OcrBox, OcrLine, OcrLineText,
  findTextBoxes, mapBoxesToSource, sortBoxesReadingOrder,
  ctcGreedyDecode, detPreprocess, recPreprocess
} from '../utils/OcrPostprocess';

const TAG: string = 'LocalOCREngine';
const DET_MODEL: string = 'paddle_ocr_det_fp16.ms';
const REC_MODEL: string = 'paddle_ocr_rec_fp16.ms';
const CHARSET_NAME: string = 'ppocr_keys_v1.txt';
/** 解码时最长边限制（防大图内存峰值） */
const MAX_SIDE: number = 960;

export class LocalOCREngine implements LocalEngine {
  private static instance: LocalOCREngine | null = null;
  private detModel: mindSporeLite.Model | null = null;
  private recModel: mindSporeLite.Model | null = null;
  private charset: Array<string> = [];
  private _ready: boolean = false;
  private base64Helper: util.Base64Helper = new util.Base64Helper();

  public get ready(): boolean {
    return this._ready;
  }

  public get kind(): string {
    return 'local_ocr';
  }

  private constructor() {}

  public static getInstance(): LocalOCREngine {
    if (LocalOCREngine.instance === null) {
      LocalOCREngine.instance = new LocalOCREngine();
    }
    return LocalOCREngine.instance;
  }

  public async init(context: Context): Promise<void> {
    try {
      const detPath: string = await this.ensureAsset(context, DET_MODEL);
      const recPath: string = await this.ensureAsset(context, REC_MODEL);
      const charsetPath: string = await this.ensureAsset(context, CHARSET_NAME);
      this.charset = await loadCharsetFromFile(charsetPath);

      const msContext: mindSporeLite.Context = {};
      // OCR 模型极小，CPU 即可极速跑完，无需占用 NPU
      msContext.target = ['cpu'];
      msContext.cpu = { threadNum: 2, threadAffinityMode: 0, precisionMode: 'enforce_fp32' };
      this.detModel = await mindSporeLite.loadModelFromFile(detPath, msContext);
      this.recModel = await mindSporeLite.loadModelFromFile(recPath, msContext);
      this._ready = true;
      Logger.info(TAG, `端侧离线 OCR 引擎已就绪 (det+rec, 字符表 ${this.charset.length} 类)`);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `端侧 OCR 初始化失败，将退回 VLM 或云端: ${msg}`);
      this._ready = false;
      this.detModel = null;
      this.recModel = null;
    }
  }

  public async infer(messages: LLMMessage[]): Promise<string> {
    let imageBase64: string = '';
    for (let i = 0; i < messages.length; i++) {
      const m: LLMMessage = messages[i];
      if (m.image_base64 !== undefined && m.image_base64.length > 0) {
        imageBase64 = m.image_base64;
      }
    }
    if (imageBase64.length === 0) {
      throw new Error('端侧离线 OCR 需要图像输入');
    }
    return await this.recognizeText(imageBase64);
  }

  /**
   * 完整离线 OCR 识别：检测 + 识别全管线。
   * @param imageBase64 图像（不含 dataURL 前缀的纯 base64）
   * @returns 按阅读顺序拼接的纯文本
   */
  public async recognizeText(imageBase64: string): Promise<string> {
    if (!this._ready || this.detModel === null || this.recModel === null) {
      throw new Error('LocalOCREngine 未就绪');
    }

    const frame: ImageFrame = await this.decodeToFrame(imageBase64);
    try {
      // 1. det：整图 -> 文本框
      const detInput: Float32Array = detPreprocess(frame.rgba, frame.width, frame.height);
      const probMap: Float32Array = await this.runDet(detInput);
      let boxes: Array<OcrBox> = findTextBoxes(probMap);
      boxes = mapBoxesToSource(boxes, frame.width, frame.height);
      boxes = sortBoxesReadingOrder(boxes);
      Logger.info(TAG, `OCR 检测到 ${boxes.length} 个文本区域`);

      if (boxes.length === 0) {
        return '';
      }

      // 2. rec：逐行识别
      const lines: Array<OcrLine> = [];
      for (const box of boxes) {
        const crop: CroppedLine = cropBox(frame, box);
        if (crop.width < 4 || crop.height < 4) {
          continue;
        }
        const recInput: Float32Array = recPreprocess(crop.rgba, crop.width, crop.height);
        const lineText: OcrLineText = await this.runRec(recInput);
        if (lineText.text.trim().length > 0) {
          lines.push({ text: lineText.text, confidence: lineText.confidence, box: box });
        }
      }

      // 3. 拼接（行间换行）
      let result: string = '';
      for (const line of lines) {
        result += line.text + '\n';
      }
      Logger.info(TAG, `OCR 识别完成，共 ${lines.length} 行`);
      return result.trim();
    } finally {
      frame.release();
    }
  }

  /** det 推理：输出 [1,1,320,320] 概率图 -> 展平 */
  private async runDet(input: Float32Array): Promise<Float32Array> {
    const detModel = this.detModel;
    if (detModel === null) {
      throw new Error('det 模型未加载');
    }
    const inputs: mindSporeLite.MSTensor[] = detModel.getInputs();
    if (inputs.length === 0) {
      throw new Error('det 模型无输入张量');
    }
    inputs[0].setData(input.buffer as ArrayBuffer);
    const outputs: mindSporeLite.MSTensor[] = await detModel.predict(inputs);
    if (outputs.length === 0) {
      throw new Error('det 模型无输出张量');
    }
    return new Float32Array(outputs[0].getData());
  }

  /** rec 推理：自适应 [seq, class] / [1, seq, class] / [seq, 1, class] 输出布局 */
  private async runRec(input: Float32Array): Promise<OcrLineText> {
    const recModel = this.recModel;
    if (recModel === null) {
      throw new Error('rec 模型未加载');
    }
    const inputs: mindSporeLite.MSTensor[] = recModel.getInputs();
    if (inputs.length === 0) {
      throw new Error('rec 模型无输入张量');
    }
    inputs[0].setData(input.buffer as ArrayBuffer);
    const outputs: mindSporeLite.MSTensor[] = await recModel.predict(inputs);
    if (outputs.length === 0) {
      throw new Error('rec 模型无输出张量');
    }
    const shape: Array<number> = outputs[0].shape;
    const data: Float32Array = new Float32Array(outputs[0].getData());
    const numClasses: number = this.charset.length + 1; // + blank

    // 在 shape 中定位类别轴（= numClasses），剩余轴取非 1 者为 seq
    let classAxis: number = -1;
    for (let i = 0; i < shape.length; i++) {
      if (shape[i] === numClasses) {
        classAxis = i;
        break;
      }
    }
    if (classAxis === -1 || shape.length < 2) {
      Logger.warn(TAG, `rec 输出形状异常: [${shape.join(',')}]，按 [seq, class] 处理`);
      const seq: number = Math.floor(data.length / numClasses);
      return ctcGreedyDecode(data, seq, numClasses, this.charset);
    }
    let seqLen: number = 1;
    for (let i = 0; i < shape.length; i++) {
      if (i !== classAxis && shape[i] > 1) {
        seqLen = shape[i];
        break;
      }
    }
    // 类别轴不在最后时需要重排（按 [seq, class] 逐帧取样）
    if (classAxis === shape.length - 1) {
      return ctcGreedyDecode(data, seqLen, numClasses, this.charset);
    }
    const reordered: Float32Array = new Float32Array(seqLen * numClasses);
    const strideTail: number = numClasses;
    for (let s = 0; s < seqLen; s++) {
      for (let c = 0; c < numClasses; c++) {
        // 假设布局 [seq, 1, class]：index = (s * 1) * numClasses + c
        reordered[s * strideTail + c] = data[s * numClasses + c];
      }
    }
    return ctcGreedyDecode(reordered, seqLen, numClasses, this.charset);
  }

  /** 解码 base64 -> 原始尺寸 RGBA 帧（最长边限制 MAX_SIDE） */
  private async decodeToFrame(base64: string): Promise<ImageFrame> {
    return new Promise<ImageFrame>((resolve: (v: ImageFrame) => void, reject: (e: Error) => void) => {
      try {
        const bytes: Uint8Array = this.base64Helper.decodeSync(base64);
        const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
        // 先读尺寸信息决定缩放
        source.getImageInfo((infoErr: BusinessError, info: image.ImageInfo) => {
          if (infoErr) {
            reject(new Error(`读取图像信息失败: ${infoErr.message}`));
            return;
          }
          const scale: number = Math.min(1, MAX_SIDE / Math.max(info.size.width, info.size.height));
          const opts: image.DecodingOptions = {
            sampleSize: 1,
            editable: true,
            desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
            desiredSize: {
              width: Math.max(1, Math.floor(info.size.width * scale)),
              height: Math.max(1, Math.floor(info.size.height * scale))
            }
          };
          source.createPixelMap(opts, async (pmErr: BusinessError, pm: image.PixelMap) => {
            if (pmErr) {
              reject(new Error(`解码图像失败: ${pmErr.message}`));
              return;
            }
            const frame: ImageFrame = new ImageFrame(pm);
            await frame.fill();
            resolve(frame);
          });
        });
      } catch (e) {
        reject(e instanceof Error ? e : new Error(JSON.stringify(e)));
      }
    });
  }

  private async ensureAsset(context: Context, name: string): Promise<string> {
    const dest: string = `${context.filesDir}/${name}`;
    try {
      if (fs.accessSync(dest)) {
        const st = fs.statSync(dest);
        if (st.size > 0) {
          return dest;
        }
      }
    } catch (e) {}

    const content: Uint8Array = await context.resourceManager.getRawFileContent(`models/${name}`);
    const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
    return dest;
  }

  public destroy(): void {
    this.detModel = null;
    this.recModel = null;
    this._ready = false;
    this.charset = [];
    Logger.info(TAG, '端侧 OCR 引擎已释放');
  }
}

async function readTextFile(path: string): Promise<string> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const st = fs.statSync(path);
    const buf = new ArrayBuffer(st.size);
    fs.readSync(file.fd, buf);
    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
  } finally {
    fs.closeSync(file);
  }
}

/** init 中的字符表加载（从沙箱文件读取） */
async function loadCharsetFromFile(path: string): Promise<Array<string>> {
  const text: string = await readTextFile(path);
  return text.split('\n')
    .map((line: string): string => line.replace(/\r/g, ''))
    .filter((line: string): boolean => line.length > 0);
}

/** 原始图像帧（RGBA 像素 + 尺寸），rec 裁剪数据源 */
class ImageFrame {
  public rgba: Uint8Array;
  public width: number;
  public height: number;
  private pixelMap: image.PixelMap;

  constructor(pm: image.PixelMap) {
    this.pixelMap = pm;
    // 尺寸与像素在构造时同步填充（由引擎在 resolve 前调用 fill）
    this.rgba = new Uint8Array(0);
    this.width = 0;
    this.height = 0;
  }

  public async fill(): Promise<void> {
    const info: image.ImageInfo = await this.pixelMap.getImageInfo();
    this.width = info.size.width;
    this.height = info.size.height;
    const buf: ArrayBuffer = new ArrayBuffer(this.width * this.height * 4);
    await this.pixelMap.readPixelsToBuffer(buf);
    this.rgba = new Uint8Array(buf);
  }

  public release(): void {
    this.pixelMap.release();
  }
}

interface CroppedLine {
  rgba: Uint8Array;
  width: number;
  height: number;
}

/** 裁剪文本框区域（外扩 2px，clamp 到图内） */
function cropBox(frame: ImageFrame, box: OcrBox): CroppedLine {
  let minX: number = frame.width;
  let minY: number = frame.height;
  let maxX: number = 0;
  let maxY: number = 0;
  for (const p of box.points) {
    if (p[0] < minX) { minX = p[0]; }
    if (p[0] > maxX) { maxX = p[0]; }
    if (p[1] < minY) { minY = p[1]; }
    if (p[1] > maxY) { maxY = p[1]; }
  }
  const pad: number = 2;
  const x0: number = Math.max(0, Math.floor(minX) - pad);
  const y0: number = Math.max(0, Math.floor(minY) - pad);
  const x1: number = Math.min(frame.width - 1, Math.ceil(maxX) + pad);
  const y1: number = Math.min(frame.height - 1, Math.ceil(maxY) + pad);
  const w: number = x1 - x0 + 1;
  const h: number = y1 - y0 + 1;
  const out: Uint8Array = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const srcStart: number = ((y0 + y) * frame.width + x0) * 4;
    out.set(frame.rgba.subarray(srcStart, srcStart + w * 4), y * w * 4);
  }
  return { rgba: out, width: w, height: h };
}
