/**
 * @file Logger.ets
 * @module utils
 * @description 轻量日志工具。
 *
 * 统一封装 hilog 调用，避免业务代码散落 domain/tag 字面量。
 */

import hilog from '@ohos.hilog';

const APP_DOMAIN: number = 0x0000;
const APP_TAG: string = 'LuminaAssist';

/**
 * Logger —— 静态日志工具。
 */
export class Logger {
  public static debug(tag: string, message: string): void {
    hilog.debug(APP_DOMAIN, APP_TAG, `[${tag}] ${message}`);
  }

  public static info(tag: string, message: string): void {
    hilog.info(APP_DOMAIN, APP_TAG, `[${tag}] ${message}`);
  }

  public static warn(tag: string, message: string): void {
    hilog.warn(APP_DOMAIN, APP_TAG, `[${tag}] ${message}`);
  }

  public static error(tag: string, message: string): void {
    hilog.error(APP_DOMAIN, APP_TAG, `[${tag}] ${message}`);
  }
}
