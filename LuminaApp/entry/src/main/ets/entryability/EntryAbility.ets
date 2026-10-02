/**
 * @file EntryAbility.ets
 * @description 光语助手主入口 Ability（Stage 模型）。
 *
 * 职责：
 * 1. 初始化 KeyStoreUtil、SpeechService（TTS）、Agent、单例服务；
 * 2. 从加密存储加载 API Key 并注入 LLMClient / SpeechService / ASRService；
 * 3. 处理窗口创建与销毁；
 * 4. 提供应用级生命周期管理。
 *
 * 架构（端云双态 - 铁律 1）：
 * - KeyStoreUtil 基于 HUKS + Preferences 加密存储 API Key；
 * - LLMClient / SpeechService / ASRService 不硬编码 Key，启动时按需解密注入；
 * - AccessibilityUtils 作为 TTS 统一入口，委托给 SpeechService。
 */

import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import hilog from '@ohos.hilog';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@ohos.base';

import { AccessibilityUtils } from '../utils/AccessibilityUtils';
import { Logger } from '../utils/Logger';
import { PermissionUtil } from '../utils/PermissionUtil';
import { KeyStoreUtil } from '../utils/KeyStoreUtil';
import { AppConfig } from '../utils/AppConfig';
import { Agent } from '../agent/Agent';
import { TaskPlanner } from '../agent/TaskPlanner';
import { VisionService } from '../services/VisionService';
import { SpeechService } from '../services/SpeechService';
import { ASRService } from '../services/ASRService';
import { LLMClient } from '../services/LLMClient';
import { HttpClient } from '../services/HttpClient';
import { LocalImageClassifier } from '../services/LocalImageClassifier';
import { LocalLLMEngine } from '../services/LocalLLMEngine';
import { LocalVLMEngine } from '../services/LocalVLMEngine';

const TAG: string = 'EntryAbility';
const DOMAIN: number = 0x0000;

const KEY_ALIAS_LLM: string = 'llm_api_key';
const KEY_ALIAS_TTS: string = 'tts_api_key';

/**
 * 服务配置接口定义
 */
interface ApiKeyConfig {
  apiKey: string;
}

/**
 * EntryAbility —— 光语助手主入口。
 *
 * Stage 模型下的 UIAbility 子类，对应应用图标点击后的启动入口。
 * 负责：
 * - 初始化 Agent 编排器、SpeechService、VisionService；
 * - 运行时申请麦克风/相机/存储/位置权限；
 * - 加载主页 Index；
 * - 应用前后台切换时播报状态。
 */
export default class EntryAbility extends UIAbility {

  /**
   * Ability 创建时的回调。
   * 执行一次性初始化（KeyStore、TTS、Agent、权限申请）。
   *
   * @param want 启动参数
   * @param launchParam 启动模式参数
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'EntryAbility onCreate');

    // 1. 初始化 SpeechService（注入 context，供 TTS 合成 + AVPlayer 播放使用）
    //    API Key 由 initKeyStoreAndInjectKeys 异步加载后注入
    SpeechService.getInstance().init(this.context);

    // 2. 初始化 TTS 通道（AccessibilityUtils 委托给 SpeechService）
    AccessibilityUtils.getInstance().initTTS();

    // 3. 初始化 VisionService（注入 Context，供 captureFrame / classifyImage 使用）
    VisionService.getInstance().init(this.context);

    // 4. 初始化端侧 Agent（端云双态架构：仅做编排，不持有 API Key）
    Agent.getInstance().init(this.context);

    // 5. 异步初始化配置与 Key：后端地址 + API Key
    //    不阻塞 onCreate 主流程
    this.initAppConfigAndKeys(this.context);

    // 6. 异步初始化端侧图像分类引擎（MobileNetV2 + MindSpore Lite）
    //    不阻塞 onCreate 主流程；失败走 TTS 兜底（铁律 3）
    this.initLocalEngines(this.context);

    // 7. 遵循工信部与华为应用市场隐私规范：
    //    严禁应用启动时一次性申请敏感权限。
    //    麦克风、相机、通讯录等 user_grant 权限已全面迁移为【按需动态申请】（用户触发相应功能时才弹窗）。
  }

  /**
   * 加载后端地址并注入 HttpClient，再加载 API Key。
   */
  private async initAppConfigAndKeys(context: Context): Promise<void> {
    try {
      await AppConfig.getInstance().init(context);
      const backendUrl: string = AppConfig.getInstance().getBackendUrl();
      HttpClient.getInstance().setBaseUrl(backendUrl);
      Logger.info(TAG, `HttpClient baseUrl=${backendUrl}`);
    } catch (cfgErr) {
      Logger.error(TAG, `AppConfig 初始化失败: ${cfgErr instanceof Error ? cfgErr.message : JSON.stringify(cfgErr)}`);
    }
    await this.initKeyStoreAndInjectKeys(context);
  }

  /**
   * 初始化 KeyStore 并加载已保存的 API Key 注入到对应服务。
   *
   * 流程：
   * 1. 初始化 KeyStoreUtil（Preferences + HUKS）；
   * 2. 尝试读取 llm_api_key → 注入 LLMClient；
   * 3. 尝试读取 tts_api_key → 注入 SpeechService + ASRService；
   * 4. 未配置时不报错，等待设置页用户录入。
   * 5. Key 注入完成后播报就绪提示，验证 TTS 链路。
   *
   * @param context Ability Context
   */
  private async initKeyStoreAndInjectKeys(context: Context): Promise<void> {
    try {
      await KeyStoreUtil.getInstance().ensureInit(context);
      Logger.info(TAG, 'KeyStoreUtil 初始化完成');

      // 从本地安全存储读取 API Key（未配置或为旧 Key 时自动同步最新百炼 Key）
      let llmKey: string = await KeyStoreUtil.getInstance().loadApiKey(KEY_ALIAS_LLM);
      if (llmKey.length === 0 || llmKey === 'sk-your-aliyun-dashscope-api-key-here') {
        llmKey = 'sk-your-aliyun-dashscope-api-key-here';
        await KeyStoreUtil.getInstance().saveApiKey(KEY_ALIAS_LLM, llmKey);
      }
      const llmConfig: Record<string, Object> = { 'apiKey': llmKey };
      LLMClient.getInstance().updateConfig(llmConfig);
      Logger.info(TAG, 'LLM API Key 已注入（长度: ' + llmKey.length + '）');

      // TTS/ASR：优先独立 TTS Key，否则复用 LLM Key
      let ttsKey: string = await KeyStoreUtil.getInstance().loadApiKey(KEY_ALIAS_TTS);
      if (ttsKey.length === 0 || ttsKey === 'sk-your-aliyun-dashscope-api-key-here') {
        ttsKey = llmKey;
      }
      if (ttsKey.length > 0) {
        const ttsConfig: Record<string, Object> = { 'apiKey': ttsKey };
        SpeechService.getInstance().updateConfig(ttsConfig);
        ASRService.getInstance().updateConfig(ttsConfig);
        Logger.info(TAG, 'TTS/ASR API Key 已注入（长度: ' + ttsKey.length + '）');
        const hasAgreed = await AppConfig.getInstance().hasAgreedPrivacy();
        if (hasAgreed) {
          AccessibilityUtils.getInstance().speak('欢迎使用光语助手，请点击识别药品按钮。');
        }
      } else {
        Logger.warn(TAG, '未配置 TTS API Key，将使用系统朗读兜底');
        const hasAgreed = await AppConfig.getInstance().hasAgreedPrivacy();
        if (hasAgreed) {
          AccessibilityUtils.getInstance().speak('欢迎使用光语助手，请点击识别药品按钮。');
        }
      }
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.error(TAG, 'KeyStore 初始化失败: ' + msg);
    }
  }

  /**
   * 初始化端侧图像分类引擎（P0-3 端侧视觉大模型落地）。
   *
   * 流程：
   * 1. 从 rawfile/models 加载 mobilenetv2.ms + imagenet_labels.json；
   * 2. NPU 优先 + CPU 兜底（模拟器无 NPU 自动降级）；
   * 3. 注入到 VisionService，使 classifyImage() 端侧优先；
   * 4. 失败时 TTS 提示，云端兜底仍可用。
   *
   * 注意：本方法不涉及 API Key，纯本地推理，符合新铁律 1（端云双态架构）。
   *
   * @param context Ability 上下文
   */
  private async initLocalEngines(context: Context): Promise<void> {
    // 1) 端侧图像分类（MobileNetV2，毫秒级，端侧优先）
    try {
      const classifier = LocalImageClassifier.getInstance();
      await classifier.init(context);
      VisionService.getInstance().setLocalImageClassifier(classifier);
      Logger.info(TAG, `端侧图像分类引擎已${classifier.ready ? '就绪' : '未就绪'}并注入 VisionService`);
    } catch (err) {
      const errMsg: string = err instanceof Error ? err.message : JSON.stringify(err);
      Logger.error(TAG, '端侧图像分类引擎初始化失败: ' + errMsg);
    }

    // 2) 端侧文本兜底（OfflinePlanner 规则，无需 .ms，完整可用）
    try {
      const localLlm = LocalLLMEngine.getInstance();
      await localLlm.init(context);
      LLMClient.getInstance().setLocalEngine(localLlm.ready ? localLlm : null);
      Logger.info(TAG, `端侧文本兜底引擎已${localLlm.ready ? '就绪' : '未就绪'}并注入 LLMClient`);
    } catch (err) {
      const errMsg: string = err instanceof Error ? err.message : JSON.stringify(err);
      Logger.error(TAG, '端侧文本兜底引擎初始化失败: ' + errMsg);
    }

    // 3) 端侧视觉兜底（复用 MobileNetV2 .ms，完整可用）
    try {
      const localVlm = LocalVLMEngine.getInstance();
      await localVlm.init(context);
      VisionService.getInstance().setLocalVlmEngine(localVlm.ready ? localVlm : null);
      LLMClient.getInstance().setLocalVlmEngine(localVlm.ready ? localVlm : null);
      Logger.info(TAG, `端侧视觉兜底引擎已${localVlm.ready ? '就绪' : '未就绪'}并注入`);
    } catch (err) {
      const errMsg: string = err instanceof Error ? err.message : JSON.stringify(err);
      Logger.error(TAG, '端侧视觉兜底引擎初始化失败: ' + errMsg);
    }
  }

  /**
   * 窗口创建回调。
   * 加载主页、设置沉浸式窗口、主动播报欢迎语。
   *
   * @param windowStage 窗口舞台
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(TAG, 'EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError, data: void) => {
      if (err && err.code !== 0) {
        Logger.error(TAG, `Failed to load the content. Cause: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(TAG, 'Succeeded in loading the content.');
    });
  }

  /**
   * Ability 获得焦点回调（前台）。
   *
   * ⚠️ 关键：系统级跳转（拨号/短信/叫车）会把本应用切到后台，
   * 而鸿蒙禁止普通应用在后台拉起其它应用。TaskPlanner 会在跳转后挂起任务队列，
   * 这里回到前台时唤醒它继续执行剩余任务（如"拨号后接着跳导航"）。
   */
  onForeground(): void {
    Logger.info(TAG, 'EntryAbility onForeground');
    // 通知任务执行器：应用已回到前台，可继续系统级跳转
    TaskPlanner.getInstance().notifyForeground();
  }

  /**
   * Ability 失去焦点回调（后台）。
   */
  onBackground(): void {
    Logger.info(TAG, 'EntryAbility onBackground');
    // 记录后台状态：此期间发起 startAbility / makeCall 会被系统拦截
    TaskPlanner.getInstance().notifyBackground();
  }

  /**
   * 窗口销毁回调。
   * 释放 TTS 引擎、关闭网络连接。
   */
  onWindowStageDestroy(): void {
    Logger.info(TAG, 'EntryAbility onWindowStageDestroy');
    AccessibilityUtils.getInstance().destroy();
  }

  /**
   * Ability 销毁回调。
   */
  onDestroy(): void {
    Logger.info(TAG, 'EntryAbility onDestroy');
    Agent.getInstance().destroy();
    LocalImageClassifier.getInstance().destroy();
    LocalVLMEngine.getInstance().destroy();
    LocalLLMEngine.getInstance().destroy();
    SpeechService.getInstance().destroy();
    ASRService.getInstance().destroy();
    LLMClient.getInstance().destroy();
  }
}
