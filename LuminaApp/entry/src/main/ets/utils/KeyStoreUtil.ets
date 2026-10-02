/**
 * @file KeyStoreUtil.ets
 * @module utils
 * @description API Key 持久化存储（Preferences）。
 *
 * 调试阶段使用 Preferences 落盘，保证重启后 Key 仍可用。
 * 生产环境应迁移到 HUKS 加密存储。
 */

import preferences from '@ohos.data.preferences';
import { Logger } from './Logger';

const TAG: string = 'KeyStoreUtil';
const PREF_NAME: string = 'lumina_keystore';

export class KeyStoreUtil {
  private static instance: KeyStoreUtil | null = null;
  private keys: Map<string, string> = new Map();
  private prefs: preferences.Preferences | null = null;

  private constructor() {
  }

  public static getInstance(): KeyStoreUtil {
    if (KeyStoreUtil.instance === null) {
      KeyStoreUtil.instance = new KeyStoreUtil();
    }
    return KeyStoreUtil.instance;
  }

  public async init(context: Context): Promise<void> {
    this.prefs = await preferences.getPreferences(context, PREF_NAME);
    Logger.info(TAG, 'KeyStoreUtil 初始化完成（Preferences 持久化）');
  }

  /** 是否已完成 Preferences 初始化（未初始化时 save 不会落盘）。 */
  public isInitialized(): boolean {
    return this.prefs !== null;
  }

  /** 确保 Preferences 已就绪后再读写 Key。 */
  public async ensureInit(context: Context): Promise<void> {
    if (this.prefs === null) {
      await this.init(context);
    }
  }

  public async saveApiKey(keyName: string, apiKey: string): Promise<void> {
    if (!keyName || !apiKey) {
      throw new Error('密钥名称和值不能为空');
    }
    this.keys.set(keyName, apiKey.trim());
    if (this.prefs !== null) {
      await this.prefs.put(keyName, apiKey.trim());
      await this.prefs.flush();
    }
    Logger.info(TAG, `API Key 已保存: ${keyName}`);
  }

  public async loadApiKey(keyName: string): Promise<string> {
    const cached: string | undefined = this.keys.get(keyName);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    if (this.prefs !== null) {
      const saved: preferences.ValueType = await this.prefs.get(keyName, '');
      if (typeof saved === 'string' && saved.length > 0) {
        this.keys.set(keyName, saved);
        return saved;
      }
    }
    return '';
  }

  public async deleteApiKey(keyName: string): Promise<void> {
    this.keys.delete(keyName);
    if (this.prefs !== null) {
      await this.prefs.delete(keyName);
      await this.prefs.flush();
    }
    Logger.info(TAG, `API Key 已删除: ${keyName}`);
  }

  public async hasApiKey(keyName: string): Promise<boolean> {
    const key: string = await this.loadApiKey(keyName);
    return key.length > 0;
  }

  public destroy(): void {
    this.keys.clear();
    this.prefs = null;
    Logger.info(TAG, 'KeyStoreUtil 已销毁');
  }
}
