/**
 * @file ASRService.ets
 * @module services
 * @description 端侧实时语音识别服务（骨架降级实现）。
 *
 * 职责：
 * 1. 提供实时语音识别的接口定义；
 * 2. OpenHarmony 开源 SDK 下 WebSocket 与完整音频 API 不可用，统一标记为未就绪；
 * 3. 所有失败抛中文 Error，由 AccessibilityUtils 振动兜底（铁律 3）。
 *
 * 架构原则（端云双态架构 - 铁律 1）：
 * - API Key 经 updateConfig 注入（生产环境由 KeyStoreUtil 解密后注入）；
 * - 禁止硬编码 API Key、禁止日志打印 Key 值；
 * - 端侧直连 DashScope 是低延迟路径，不依赖后端。
 *
 * 说明：
 * - 完整实现依赖 @ohos.net.websocket 和完整 AudioCapturer API；
 * - OpenHarmony 开源 SDK 下此服务为骨架，UI 层应回退到文本输入。
 */

import { Logger } from '../utils/Logger';

const TAG: string = 'ASRService';

export interface ASRConfig {
  apiKey: string;
  model: string;
  languageHints: string[];
}

export interface ASRCallbacks {
  onResult: (text: string, isFinal: boolean) => void;
  onError: (msg: string) => void;
  onComplete: (finalText: string) => void;
}

export class ASRService {
  private static instance: ASRService | null = null;
  private config: ASRConfig;
  private isRunning: boolean = false;
  private callbacks: ASRCallbacks | null = null;

  private constructor() {
    this.config = {
      apiKey: 'sk-your-aliyun-dashscope-api-key-here',
      model: 'paraformer-realtime-v2',
      languageHints: ['zh']
    };
  }

  public static getInstance(): ASRService {
    if (ASRService.instance === null) {
      ASRService.instance = new ASRService();
    }
    return ASRService.instance;
  }

  public updateConfig(config: Record<string, Object>): void {
    if (config['apiKey'] !== undefined) {
      this.config.apiKey = config['apiKey'] as string;
    }
    if (config['model'] !== undefined) {
      this.config.model = config['model'] as string;
    }
    if (config['languageHints'] !== undefined) {
      this.config.languageHints = config['languageHints'] as string[];
    }
    Logger.info(TAG, 'ASRService 配置已更新');
  }

  public isReady(): boolean {
    return false;
  }

  /**
   * 启动实时语音识别（骨架实现，直接返回不可用）。
   * OpenHarmony 开源 SDK 下 WebSocket 与完整音频 API 不可用。
   * @param callbacks 识别回调（onResult/onError/onComplete）
   */
  public async startRecognition(callbacks: ASRCallbacks): Promise<void> {
    if (this.isRunning) {
      Logger.warn(TAG, '识别已在进行中');
      return;
    }

    this.callbacks = callbacks;
    const msg: string = '语音识别暂不可用：当前 SDK 不支持 WebSocket 实时语音识别，请改用文本输入。';
    Logger.error(TAG, msg);
    callbacks.onError(msg);
  }

  /**
   * 停止识别（骨架实现，无实际操作）。
   */
  public async stopRecognition(): Promise<void> {
    if (!this.isRunning) {
      return;
    }
    this.isRunning = false;
    this.cleanup();
  }

  private cleanup(): void {
    this.isRunning = false;
    this.callbacks = null;
  }

  public destroy(): void {
    this.cleanup();
    this.config.apiKey = '';
  }
}
