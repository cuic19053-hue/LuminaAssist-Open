/**
 * @file ScreenReaderService.ets
 * @module services
 * @description 应用内屏幕朗读服务（功能二 read_screen 任务的端侧落地）。
 *
 * 背景：
 * 第三方应用无系统级屏幕取词权限，read_screen 落地为"朗读本应用当前界面内容"：
 * UI 页面（Index 等）注册内容提供者，按需组装当前可见信息（状态、药品详情、对话记录），
 * TaskPlanner 执行 read_screen 时取文本交给 TTS 播报。
 *
 * 设计原则：
 * - 拉取式：不持有 UI 状态副本，朗读时实时向提供者取内容，保证与界面一致；
 * - 页面切换时由页面自行注册/注销，服务只保留最新提供者。
 */

import { Logger } from '../utils/Logger';

const TAG: string = 'ScreenReaderService';

/** 屏幕内容提供者：返回当前页面可朗读的文本（空串表示无内容）。 */
export type ScreenContentProvider = () => string;

/**
 * ScreenReaderService —— 应用内屏幕朗读服务（单例）。
 */
export class ScreenReaderService {
  private static instance: ScreenReaderService | null = null;
  private provider: ScreenContentProvider | null = null;

  private constructor() {
  }

  public static getInstance(): ScreenReaderService {
    if (ScreenReaderService.instance === null) {
      ScreenReaderService.instance = new ScreenReaderService();
    }
    return ScreenReaderService.instance;
  }

  /**
   * 注册当前页面的内容提供者（页面 aboutToAppear 时调用）。
   */
  public registerProvider(provider: ScreenContentProvider): void {
    this.provider = provider;
    Logger.info(TAG, '屏幕内容提供者已注册');
  }

  /**
   * 注销内容提供者（页面 aboutToDisappear 时调用）。
   */
  public unregisterProvider(): void {
    this.provider = null;
    Logger.info(TAG, '屏幕内容提供者已注销');
  }

  /**
   * 获取当前屏幕可朗读文本。
   * @returns 页面组装的朗读文本；无提供者或无内容时返回空串
   */
  public getScreenText(): string {
    if (this.provider === null) {
      Logger.warn(TAG, '未注册屏幕内容提供者');
      return '';
    }
    try {
      return this.provider().trim();
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.error(TAG, `获取屏幕内容失败: ${msg}`);
      return '';
    }
  }
}
