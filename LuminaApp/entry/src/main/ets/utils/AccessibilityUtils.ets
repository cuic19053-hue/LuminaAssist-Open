/**
 * @file AccessibilityUtils.ets
 * @module utils
 * @description 无障碍能力工具类（TTS 委托给 SpeechService，振动兜底）。
 *
 * 职责：
 * 1. TTS 播报（委托给 SpeechService：云端优先 + 系统本地兜底）；
 * 2. 触觉反馈降级（TTS 完全不可用时使用振动）。
 *
 * 设计原则：
 * - VUI 优先：视障用户从语音获取一切信息；
 * - 错误兜底：TTS 失败时记录日志并尝试振动，禁止"无声失败"（铁律 3）。
 */

import vibrator from '@ohos.vibrator';
import { Logger } from './Logger';
import { SpeechService } from '../services/SpeechService';

const TAG: string = 'AccessibilityUtils';

/**
 * AccessibilityUtils —— 无障碍能力工具类（单例）。
 */
export class AccessibilityUtils {
  private static instance: AccessibilityUtils | null = null;
  private ttsReady: boolean = false;

  private constructor() {
  }

  public static getInstance(): AccessibilityUtils {
    if (AccessibilityUtils.instance === null) {
      AccessibilityUtils.instance = new AccessibilityUtils();
    }
    return AccessibilityUtils.instance;
  }

  /**
   * 初始化 TTS 通道（应用启动时调用一次）。
   * 真实播报由 SpeechService 完成（云端 + 系统本地兜底）。
   */
  public initTTS(): void {
    this.ttsReady = true;
    Logger.info(TAG, 'TTS 通道已初始化（委托给 SpeechService）');
  }

  /**
   * 异步播报（委托给 SpeechService，失败时降级为振动）。
   *
   * @param message 中文文本
   */
  public async speak(message: string): Promise<void> {
    if (!message || message.length === 0) {
      return;
    }
    if (!this.ttsReady) {
      Logger.warn(TAG, `TTS 通道未初始化，触发振动降级: "${message}"`);
      await this.vibrateFallback();
      return;
    }
    try {
      // 始终交给 SpeechService：内部会云端优先、失败后系统朗读
      await SpeechService.getInstance().speak(message);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.error(TAG, `TTS 播报失败，降级振动: ${msg}`);
      await this.vibrateFallback();
    }
  }

  /**
   * 停止当前播报。
   */
  public stopSpeak(): void {
    try {
      SpeechService.getInstance().stopSpeak();
    } catch (error) {
      Logger.error(TAG, `TTS 停止失败: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 振动降级（TTS 不可用时的兜底反馈）。
   */
  private async vibrateFallback(): Promise<void> {
    try {
      vibrator.startVibration({ type: 'time', duration: 200 }, { id: 0, usage: 'touch' });
    } catch (error) {
      Logger.error(TAG, `振动降级失败: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 触发短振动（公共方法，供外部调用）。
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
   * 释放资源。
   */
  public destroy(): void {
    try {
      SpeechService.getInstance().destroy();
    } catch (error) {
      Logger.error(TAG, `TTS 销毁失败: ${JSON.stringify(error)}`);
    }
    this.ttsReady = false;
  }
}
