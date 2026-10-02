/**
 * @file AppConfig.ets
 * @module utils
 * @description 应用配置持久化（后端地址等）。
 *
 * 真机调试时 127.0.0.1 指向手机自身，必须配置电脑局域网 IP。
 */

import preferences from '@ohos.data.preferences';
import { Logger } from './Logger';

const TAG: string = 'AppConfig';
const PREF_NAME: string = 'lumina_app_config';
const KEY_BACKEND_URL: string = 'backend_base_url';
const KEY_LOCAL_LLM: string = 'local_llm_enabled';
const KEY_LOCAL_VLM: string = 'local_vlm_enabled';
const KEY_LOCAL_CLS: string = 'local_classifier_enabled';
const KEY_CLOUD_TIMEOUT: string = 'cloud_first_timeout_ms';
const KEY_AUTH_TOKEN: string = 'auth_jwt_token';
const KEY_USER_PROFILE: string = 'auth_user_profile';
const KEY_HAS_AGREED_PRIVACY: string = 'has_agreed_privacy';
const KEY_MIIT_ICP: string = 'miit_icp_code';
/** 部署于旧电脑服务器的公网 Cloudflare HTTPS 地址（支持全球访问） */
const DEFAULT_BACKEND_URL: string = 'https://invision-lewis-theatre-bids.trycloudflare.com';
const DEFAULT_CLOUD_TIMEOUT_MS: number = 30000;
const DEFAULT_MIIT_ICP: string = '粤ICP备20260001号-1A';

/**
 * AppConfig —— 应用配置单例。
 */
export class AppConfig {
  private static instance: AppConfig | null = null;
  private context: Context | null = null;
  private prefs: preferences.Preferences | null = null;
  private backendUrl: string = DEFAULT_BACKEND_URL;
  private localLlmEnabled: boolean = true;
  private localVlmEnabled: boolean = true;
  private localClassifierEnabled: boolean = true;
  private cloudFirstTimeoutMs: number = DEFAULT_CLOUD_TIMEOUT_MS;
  private authToken: string = '';
  private userProfile: string = '';

  private constructor() {
  }

  public static getInstance(): AppConfig {
    if (AppConfig.instance === null) {
      AppConfig.instance = new AppConfig();
    }
    return AppConfig.instance;
  }

  /**
   * 初始化并加载已保存的后端地址。
   */
  public async init(context: Context): Promise<void> {
    this.context = context;
    try {
      this.prefs = await preferences.getPreferences(context, PREF_NAME);
      const saved: preferences.ValueType = await this.prefs.get(KEY_BACKEND_URL, DEFAULT_BACKEND_URL);
      const url: string = typeof saved === 'string' ? saved : DEFAULT_BACKEND_URL;
      // 真机上 127.0.0.1 或旧调试 IP 自动迁移到最新部署地址。
      if (url.indexOf('127.0.0.1') >= 0 || url.indexOf('localhost') >= 0 || url.indexOf('172.20.10.2') >= 0) {
        this.backendUrl = DEFAULT_BACKEND_URL;
        await this.prefs.put(KEY_BACKEND_URL, this.backendUrl);
        await this.prefs.flush();
        Logger.info(TAG, `已将本机/旧地址迁移为 ${this.backendUrl}`);
      } else {
        this.backendUrl = this.normalizeUrl(url);
        Logger.info(TAG, `已加载 backendUrl=${this.backendUrl}`);
      }
      // 加载端侧模型开关
      const llmVal: preferences.ValueType = await this.prefs.get(KEY_LOCAL_LLM, true);
      this.localLlmEnabled = typeof llmVal === 'boolean' ? llmVal : true;
      const vlmVal: preferences.ValueType = await this.prefs.get(KEY_LOCAL_VLM, true);
      this.localVlmEnabled = typeof vlmVal === 'boolean' ? vlmVal : true;
      const clsVal: preferences.ValueType = await this.prefs.get(KEY_LOCAL_CLS, true);
      this.localClassifierEnabled = typeof clsVal === 'boolean' ? clsVal : true;
      const toVal: preferences.ValueType = await this.prefs.get(KEY_CLOUD_TIMEOUT, DEFAULT_CLOUD_TIMEOUT_MS);
      this.cloudFirstTimeoutMs = typeof toVal === 'number' ? toVal : DEFAULT_CLOUD_TIMEOUT_MS;
      
      const tokenVal: preferences.ValueType = await this.prefs.get(KEY_AUTH_TOKEN, '');
      this.authToken = typeof tokenVal === 'string' ? tokenVal : '';
      const profileVal: preferences.ValueType = await this.prefs.get(KEY_USER_PROFILE, '');
      this.userProfile = typeof profileVal === 'string' ? profileVal : '';

      Logger.info(TAG, `端侧开关: LLM=${this.localLlmEnabled} VLM=${this.localVlmEnabled} CLS=${this.localClassifierEnabled} timeout=${this.cloudFirstTimeoutMs}`);
    } catch (error) {
      Logger.error(TAG, `AppConfig 初始化失败: ${JSON.stringify(error)}`);
      this.backendUrl = DEFAULT_BACKEND_URL;
    }
  }

  public isInitialized(): boolean {
    return this.prefs !== null;
  }

  /** 确保 Preferences 已就绪后再读写配置。 */
  public async ensureInit(context: Context): Promise<void> {
    if (this.prefs === null) {
      await this.init(context);
    }
  }

  public getBackendUrl(): string {
    return this.backendUrl;
  }

  public getDefaultBackendUrl(): string {
    return DEFAULT_BACKEND_URL;
  }

  public isLocalLlmEnabled(): boolean {
    return this.localLlmEnabled;
  }

  public isLocalVlmEnabled(): boolean {
    return this.localVlmEnabled;
  }

  public isLocalClassifierEnabled(): boolean {
    return this.localClassifierEnabled;
  }

  public getCloudFirstTimeoutMs(): number {
    return this.cloudFirstTimeoutMs;
  }

  public async setLocalLlmEnabled(enabled: boolean): Promise<void> {
    this.localLlmEnabled = enabled;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_LOCAL_LLM, enabled);
      await this.prefs.flush();
    }
    Logger.info(TAG, `localLlmEnabled=${enabled}`);
  }

  public async setLocalVlmEnabled(enabled: boolean): Promise<void> {
    this.localVlmEnabled = enabled;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_LOCAL_VLM, enabled);
      await this.prefs.flush();
    }
    Logger.info(TAG, `localVlmEnabled=${enabled}`);
  }

  public async setLocalClassifierEnabled(enabled: boolean): Promise<void> {
    this.localClassifierEnabled = enabled;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_LOCAL_CLS, enabled);
      await this.prefs.flush();
    }
    Logger.info(TAG, `localClassifierEnabled=${enabled}`);
  }

  /**
   * 保存后端地址（去掉末尾斜杠）。
   */
  public async setBackendUrl(url: string): Promise<void> {
    const normalized: string = this.normalizeUrl(url);
    if (normalized.length === 0) {
      throw new Error('后端地址不能为空');
    }
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      throw new Error('后端地址须以 http:// 或 https:// 开头');
    }
    this.backendUrl = normalized;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_BACKEND_URL, normalized);
      await this.prefs.flush();
    }
    Logger.info(TAG, `backendUrl 已保存: ${normalized}`);
  }

  private normalizeUrl(url: string): string {
    let u: string = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  public getAuthToken(): string {
    return this.authToken;
  }

  public async setAuthToken(token: string): Promise<void> {
    this.authToken = token;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_AUTH_TOKEN, token);
      await this.prefs.flush();
    }
  }

  public getUserProfile(): string {
    return this.userProfile;
  }

  public async setUserProfile(profileJson: string): Promise<void> {
    this.userProfile = profileJson;
    if (this.prefs !== null) {
      await this.prefs.put(KEY_USER_PROFILE, profileJson);
      await this.prefs.flush();
    }
  }

  /**
   * 检查用户是否已同意隐私政策与用户协议。
   */
  public async hasAgreedPrivacy(): Promise<boolean> {
    if (this.prefs === null) {
      return false;
    }
    const val: preferences.ValueType = await this.prefs.get(KEY_HAS_AGREED_PRIVACY, false);
    return typeof val === 'boolean' ? val : false;
  }

  /**
   * 设置用户隐私政策授权状态。
   */
  public async setAgreedPrivacy(agreed: boolean): Promise<void> {
    if (this.prefs !== null) {
      await this.prefs.put(KEY_HAS_AGREED_PRIVACY, agreed);
      await this.prefs.flush();
    }
    Logger.info(TAG, `隐私政策授权状态已更新: ${agreed}`);
  }

  /**
   * 获取工信部 APP 备案号。
   */
  public async getMiitIcp(): Promise<string> {
    if (this.prefs === null) {
      return DEFAULT_MIIT_ICP;
    }
    const val: preferences.ValueType = await this.prefs.get(KEY_MIIT_ICP, DEFAULT_MIIT_ICP);
    return typeof val === 'string' ? val : DEFAULT_MIIT_ICP;
  }

  /**
   * 更新工信部 APP 备案号。
   */
  public async setMiitIcp(code: string): Promise<void> {
    if (this.prefs !== null) {
      await this.prefs.put(KEY_MIIT_ICP, code.trim());
      await this.prefs.flush();
    }
  }

  /**
   * 撤回隐私协议授权（重置授权状态）。
   */
  public async withdrawPrivacyAgreement(): Promise<void> {
    await this.setAgreedPrivacy(false);
  }
}

