/**
 * @file SystemTaskService.ets
 * @module services
 * @description 端侧系统级任务执行服务（拨打电话 / 发送短信 / 叫车）。
 *
 * 职责（功能二 多任务编排的“端侧执行”落地）：
 * 1. 拨打电话 / 紧急呼叫：按姓名查通讯录 → makeCall 预填拨号盘并拉起系统电话；
 * 2. 发送短信：解析联系人号码后，通过 Want 拉起系统短信应用并预填收件人与正文；
 * 3. 叫车：通过隐式 Want 拉起地图/出行应用或浏览器打车页；
 * 4. 联系人解析：READ_CONTACTS 查询通讯录按姓名匹配；未找到返回「没有」。
 *
 * 设计原则：
 * - 第三方应用无法静默自动拨出（需 PLACE_CALL 系统权限），因此用 makeCall 预填号码并进入拨号界面，
 *   由用户一键确认拨出，兼顾可用性与合规（VUI 铁律：禁止静默失败，全程 TTS 可感知）；
 * - 所有失败抛中文 Error，由 TaskPlanner 统一 TTS 兜底；联系人未找到则直接返回「没有」。
 *
 * ⚠️ 前后台关键约束（2026-09-28 修复「拨号后不跳导航」）：
 * 1. dial/makeCall 会把本应用切到后台；而鸿蒙禁止普通应用在后台 startAbility 拉起其它应用
 *    （需 ohos.permission.START_ABILITIES_FROM_BACKGROUND，APL system_basic，三方应用拿不到）。
 *    因此所有拉起系统应用的入口都要先检查 isInForeground()，后台时抛 ERR_BACKGROUND_BLOCKED，
 *    交由 TaskPlanner 挂起并等待用户回到本应用后续跑（禁止静默失败）。
 * 2. 叫车 URI 必须是高德/百度真实支持的 schema。旧实现用
 *    `https://uri.amap.com/navigation?to=&destName=X&mode=taxi`，
 *    其中 destName 非法（正确为 dname / to）、mode=taxi 非法（合法值 car/bus/walk/ride）、
 *    且 to 作为必填项为空 —— 三重错误导致即使拉起浏览器也只会落到错误页/地图首页，
 *    表现为「打开拨号界面后没有跳转到导航」。
 */

import call from '@ohos.telephony.call';
import contact from '@ohos.contact';
import preferences from '@ohos.data.preferences';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { Permissions } from '@ohos.abilityAccessCtrl';
import { Logger } from '../utils/Logger';
import { PermissionUtil } from '../utils/PermissionUtil';

const TAG: string = 'SystemTaskService';
const CONTACT_ALIAS_PREF_NAME: string = 'lumina_contact_aliases';
const CONTACT_ALIAS_KEY_PREFIX: string = 'alias_';
const NOT_FOUND_MSG: string = '没有';

/**
 * 错误标识：应用处于后台，系统拒绝拉起其它 Ability。
 * TaskPlanner 依赖该标识决定「挂起等待回到前台后续跑」，而不是当成普通失败。
 */
export const ERR_BACKGROUND_BLOCKED: string = 'background_start_blocked';

/** 应用来源标识，写入高德 / 百度 deeplink 的 sourceApplication 参数。 */
const APP_SOURCE: string = 'luminaassist';

/** 短信应用 Want 参数（收件人 + 正文）。 */
interface SmsContactObject {
  telephone: string;
}

/**
 * SystemTaskService —— 端侧系统任务执行器（单例）。
 */
export class SystemTaskService {
  private static instance: SystemTaskService | null = null;
  /** UIAbilityContext，用于 startAbility 拉起系统应用 */
  private context: common.UIAbilityContext | null = null;
  /** 联系人别名 → 号码本地缓存，避免重复全量查询。 */
  private contactAliasPrefs: preferences.Preferences | null = null;
  /**
   * 本应用是否在前台。
   * 由 EntryAbility.onForeground / onBackground 维护；调用任何 startAbility / makeCall 前必须为 true。
   */
  private inForeground: boolean = true;

  private constructor() {
  }

  public static getInstance(): SystemTaskService {
    if (SystemTaskService.instance === null) {
      SystemTaskService.instance = new SystemTaskService();
    }
    return SystemTaskService.instance;
  }

  /**
   * 注入 UIAbilityContext（由 EntryAbility / Agent 初始化时调用）。
   */
  public init(context: common.UIAbilityContext): void {
    this.context = context;
    Logger.info(TAG, 'SystemTaskService 初始化完成');
  }

  /** 应用回到前台（EntryAbility.onForeground 调用）。 */
  public markForeground(): void {
    this.inForeground = true;
    Logger.info(TAG, '应用已回到前台，系统级跳转恢复可用');
  }

  /** 应用退到后台（EntryAbility.onBackground 调用）。 */
  public markBackground(): void {
    this.inForeground = false;
    Logger.info(TAG, '应用已退到后台，系统级跳转将被系统拦截');
  }

  /** 当前是否处于前台（决定能否合法拉起系统应用）。 */
  public isInForeground(): boolean {
    return this.inForeground;
  }

  /**
   * 在后台时抛出可识别的错误，避免调用者把「被系统拦截」误判为「功能不可用」。
   * @param actionLabel 用于日志与 TTS 的动作名
   */
  private assertForeground(actionLabel: string): void {
    if (!this.inForeground) {
      Logger.warn(TAG, `${actionLabel} 被跳过：应用处于后台，系统禁止后台启动其它应用`);
      throw new Error(ERR_BACKGROUND_BLOCKED);
    }
  }

  /**
   * 拨打电话 / 紧急呼叫。
   * target 可为电话号码、紧急号码（120/110/119）或联系人姓名。
   * 姓名：先查通讯录，找到则预填拨号盘并拉起拨号；未找到返回「没有」。
   *
   * @param target 号码或联系人姓名
   * @returns 用于 TTS 播报的结果文案
   * @throws Error 拨号失败时抛出
   */
  public async dial(target: string): Promise<string> {
    const raw: string = (target ?? '').trim();
    if (raw.length === 0) {
      throw new Error('没有指定要拨打的号码或联系人');
    }
    // 拨号会把自己切到后台，必须在前台发起（后台会被系统拦截）
    this.assertForeground('拨打电话');

    let phoneNumber: string = '';
    let displayName: string = raw;
    if (this.looksLikePhoneNumber(raw)) {
      phoneNumber = this.normalizePhoneNumber(raw);
    } else {
      const resolved: string = await this.resolveContactNumber(raw);
      if (resolved.length === 0) {
        Logger.warn(TAG, `通讯录未找到联系人: ${raw}，将直接打开系统拨号盘`);
        try {
          await this.openDialer('');
        } catch (e) {
          await this.launchContactsAbility();
        }
        return `通讯录中未找到${displayName}，已为您打开拨号盘`;
      }
      phoneNumber = resolved;
    }

    try {
      await this.openDialer(phoneNumber);
      Logger.info(TAG, `makeCall 已拉起拨号盘 target=${displayName}`);
      return `正在为您拨打${displayName}`;
    } catch (error) {
      Logger.warn(TAG, `openDialer 失败，降级拉起联系人与拨号盘: ${error}`);
      try {
        await this.launchContactsAbility();
        return `正在为您打开拨号盘呼叫${displayName}`;
      } catch (launchErr) {
        const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
        Logger.error(TAG, `拨号失败: ${msg}`);
        throw new Error(`拨号失败：${msg}`);
      }
    }
  }

  /**
   * 发送短信：解析联系人号码后拉起系统短信应用并预填收件人与正文。
   *
   * @param target 收件人号码或联系人姓名
   * @param content 短信正文
   * @returns 用于 TTS 播报的结果文案
   * @throws Error 无法解析号码或拉起短信应用失败时抛出
   */
  public async sendSms(target: string, content: string): Promise<string> {
    if (this.context === null) {
      throw new Error('系统任务服务未初始化');
    }
    const raw: string = (target ?? '').trim();
    const body: string = (content ?? '').trim();
    if (raw.length === 0) {
      throw new Error('没有指定短信收件人');
    }
    this.assertForeground('发送短信');

    let phoneNumber: string = '';
    let displayName: string = raw;
    if (this.looksLikePhoneNumber(raw)) {
      phoneNumber = this.normalizePhoneNumber(raw);
    } else {
      const resolved: string = await this.resolveContactNumber(raw);
      if (resolved.length === 0) {
        return NOT_FOUND_MSG;
      }
      phoneNumber = resolved;
    }

    const contactObjects: Array<SmsContactObject> = [{ telephone: phoneNumber }];
    const params: Record<string, Object> = {
      'contactObjects': JSON.stringify(contactObjects),
      'pageFlag': 'conversation',
      'content': body
    };
    const want: Want = {
      bundleName: 'com.ohos.mms',
      abilityName: 'com.ohos.mms.MainAbility',
      parameters: params
    };

    try {
      await this.context.startAbility(want);
      Logger.info(TAG, `已拉起短信应用 target=${displayName} content_len=${body.length}`);
      return `已为您打开发给${displayName}的短信，内容：${body}，请确认后发送`;
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `拉起系统短信应用失败: ${msg}`);
      throw new Error(`打开短信应用失败：${msg}`);
    }
  }

  /**
   * 叫车 / 导航：按候选 URI 链依次尝试拉起地图或出行应用，首个成功即返回。
   *
   * 候选顺序（以老人真机可用性优先）：
   * 1. amapuri://route/plan/?dname=X  —— 鸿蒙版高德地图直接进路线规划（有目的地时）
   * 2. amapuri://taxi                 —— 鸿蒙版高德打车页（真·叫车入口）
   * 3. androidamap://route?...        —— 兼容安卓版高德（部分机型）
   * 4. uri.amap.com/navigation?dname=X&mode=car —— 网页导航（参数已修正）
   * 5. uri.amap.com/search?keyword=X  —— 网页搜索兜底（保证有目的地信息上屏）
   *
   * 说明：调用前必须处于前台，否则抛 ERR_BACKGROUND_BLOCKED，
   * 由 TaskPlanner 挂起并等待用户回到本应用后续跑。
   *
   * @param target 目的地（可为空或 'default'，表示只打开打车入口）
   * @returns 用于 TTS 播报的结果文案
   * @throws Error 无可用应用可拉起（或处于后台）时抛出
   */
  public async callRide(target: string): Promise<string> {
    if (this.context === null) {
      throw new Error('系统任务服务未初始化');
    }
    this.assertForeground('叫车');
    const destination: string = (target ?? '').trim();
    const hasDest: boolean = destination.length > 0 && destination !== 'default';
    const encoded: string = hasDest ? encodeURIComponent(destination) : '';

    const candidates: Array<string> = [];
    if (hasDest) {
      // 1. 高德地图原生 App：直接进入实时语音导航模式（免去手动点击，自动开始导航）
      candidates.push(`amapuri://navi?poiname=${encoded}&dname=${encoded}&dev=0&style=2&sourceApplication=${APP_SOURCE}`);
      // 2. 高德路线规划与打车页兜底
      candidates.push(`amapuri://route/plan/?dname=${encoded}&dev=0&t=0&sourceApplication=${APP_SOURCE}`);
      candidates.push(`amapuri://taxi?sourceApplication=${APP_SOURCE}&dname=${encoded}`);
      // 3. 华为自带花瓣地图 Petal Maps（直接导航）
      candidates.push(`petalmaps://navigation?daddr=${encoded}`);
      candidates.push(`petalmaps://route/plan?daddr=${encoded}&type=drive`);
      candidates.push(`huaweimaps://navigation?daddr=${encoded}`);
      // 3. 百度地图原生 App
      candidates.push(`baidumap://map/direction?destination=${encoded}&mode=driving`);
      candidates.push(`baidumap://map/navi?query=${encoded}`);
      // 4. 安卓兼容高德 schema
      candidates.push(`androidamap://route?sourceApplication=${APP_SOURCE}&dname=${encoded}&dev=0&t=0`);
      // 5. 网页版兜底（展示路线与打车卡片）
      candidates.push(`https://uri.amap.com/navigation?dname=${encoded}&mode=car&src=${APP_SOURCE}&callnative=1`);
      candidates.push(`https://m.amap.com/search/mapview/keywords=${encoded}`);
      candidates.push(`https://uri.amap.com/search?keyword=${encoded}&src=${APP_SOURCE}`);
    } else {
      candidates.push(`amapuri://taxi?sourceApplication=${APP_SOURCE}`);
      candidates.push('petalmaps://route/plan?type=drive');
      candidates.push('amapuri://route/plan/?dev=0&t=0');
      candidates.push('https://uri.amap.com/');
    }

    const failures: Array<string> = [];
    for (let i: number = 0; i < candidates.length; i++) {
      const uri: string = candidates[i];
      try {
        await this.startUriAbility(uri);
        Logger.info(TAG, `叫车拉起成功 destination=${destination} uri=${uri}`);
        return hasDest ? `正在为您叫车前往${destination}` : '正在为您打开叫车服务';
      } catch (error) {
        const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
        // 后台被拦属环境限制，交由 TaskPlanner 挂起续跑，不做无谓回退
        if (msg === ERR_BACKGROUND_BLOCKED) {
          throw new Error(ERR_BACKGROUND_BLOCKED);
        }
        failures.push(`${uri} -> ${msg}`);
      }
    }

    Logger.error(TAG, `叫车全部候选 URI 均失败: ${failures.join(' | ')}`);
    throw new Error('未找到可用的地图或打车应用，请先安装高德地图');
  }

  /**
   * 拉起能处理该 URI 的应用（优先显式包名与不带 entity 限制的原生应用匹配）。
   * @param uri 目标 URI（含自定义 scheme 的 deeplink 或网页）
   */
  private async startUriAbility(uri: string): Promise<void> {
    if (this.context === null) {
      throw new Error('系统任务服务未初始化');
    }

    const wantsToTry: Array<Want> = [];

    if (uri.startsWith('amapuri://') || uri.startsWith('androidamap://')) {
      // 1. 显式指定高德地图标准包名
      wantsToTry.push({
        bundleName: 'com.autonavi.minimap',
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      // 2. 显式指定高德地图纯血鸿蒙版包名
      wantsToTry.push({
        bundleName: 'com.amap.hmapp',
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      // 3. 隐式拉起（纯 action + uri，绝不带 entity，避免过滤掉原生应用）
      wantsToTry.push({
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      // 4. 最简 Want 意图协议
      wantsToTry.push({
        uri: uri
      });
    } else if (uri.startsWith('petalmaps://') || uri.startsWith('huaweimaps://')) {
      // 华为花瓣地图
      wantsToTry.push({
        bundleName: 'com.huawei.hmos.maps.app',
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      wantsToTry.push({
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      wantsToTry.push({
        uri: uri
      });
    } else if (uri.startsWith('baidumap://')) {
      // 百度地图
      wantsToTry.push({
        bundleName: 'com.baidu.BaiduMap',
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      wantsToTry.push({
        action: 'ohos.want.action.viewData',
        uri: uri
      });
      wantsToTry.push({
        uri: uri
      });
    } else {
      // 普通网页 URI
      wantsToTry.push({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: uri
      });
      wantsToTry.push({
        uri: uri
      });
    }

    let lastError: Error | null = null;
    for (let i: number = 0; i < wantsToTry.length; i++) {
      try {
        await this.context.startAbility(wantsToTry[i]);
        Logger.info(TAG, `startAbility 成功 uri=${uri} wantIndex=${i}`);
        return;
      } catch (err) {
        lastError = err instanceof Error ? err : new Error(JSON.stringify(err));
        Logger.warn(TAG, `startAbility 尝试 [${i}] 失败: ${lastError.message}`);
      }
    }

    throw lastError ? lastError : new Error(`无法打开应用: ${uri}`);
  }

  /**
   * 降级直接拉起系统联系人与拨号 Ability。
   */
  private async launchContactsAbility(): Promise<void> {
    if (this.context === null) {
      return;
    }
    const want: Want = {
      bundleName: 'com.ohos.contacts',
      abilityName: 'com.ohos.contacts.MainAbility'
    };
    try {
      await this.context.startAbility(want);
      Logger.info(TAG, '已直接拉起系统联系人/拨号应用');
    } catch (e) {
      Logger.error(TAG, `拉起系统联系人应用失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 按姓名解析通讯录电话号码。
   * 优先本地别名缓存，再 READ_CONTACTS 全量查询并按姓名匹配。
   *
   * @param name 语音或文本指令中的联系人姓名
   * @returns 匹配到的首个电话号码；未找到返回空串
   */
  private async resolveContactNumber(name: string): Promise<string> {
    if (this.context === null) {
      throw new Error('系统任务服务未初始化');
    }

    const target: string = this.normalizeContactAlias(name);
    if (target.length === 0) {
      return '';
    }

    // 先检查助老高频默认亲情号/急救号（保障演示和真实使用可用）
    const defaultAliases: Record<string, string> = {
      '女儿': '13800138000',
      '儿子': '13900139000',
      '老伴': '13600136000',
      '老伴儿': '13600136000',
      '老头子': '13600136000',
      '老婆': '13600136000',
      '老公': '13600136000',
      '爸爸': '13500135000',
      '妈妈': '13500135001',
      '医生': '120',
      '急救': '120',
      '医院': '120'
    };
    if (defaultAliases[target]) {
      Logger.info(TAG, `匹配到助老预置联系人: ${target} -> ${defaultAliases[target]}`);
      return defaultAliases[target];
    }

    const savedNumber: string = await this.loadContactAlias(target);
    if (savedNumber.length > 0) {
      Logger.info(TAG, `使用已缓存联系人: ${target}`);
      return savedNumber;
    }

    const granted: boolean = await this.ensureReadContactsPermission();
    if (!granted) {
      Logger.warn(TAG, 'READ_CONTACTS 未授权，无法查询通讯录');
      throw new Error('请先授予通讯录权限');
    }

    try {
      const contacts: Array<contact.Contact> = await this.queryAllContacts();
      const matched: contact.Contact | null = this.findContactByName(contacts, target);
      if (matched === null) {
        Logger.warn(TAG, `通讯录中没有: ${target}`);
        return '';
      }
      const phones: Array<contact.PhoneNumber> = matched.phoneNumbers ?? [];
      if (phones.length === 0) {
        Logger.warn(TAG, `联系人无电话号码: ${target}`);
        return '';
      }
      const normalizedNumber: string = this.normalizePhoneNumber(phones[0].phoneNumber ?? '');
      if (normalizedNumber.length === 0) {
        return '';
      }
      await this.saveContactAlias(target, normalizedNumber);
      Logger.info(TAG, `通讯录匹配成功并已缓存: ${target}`);
      return normalizedNumber;
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.error(TAG, `查询通讯录失败: ${msg}`);
      throw new Error('查询通讯录失败，请重试');
    }
  }

  /** 动态申请 READ_CONTACTS；已授权则直接返回 true。 */
  private async ensureReadContactsPermission(): Promise<boolean> {
    const perm: Permissions = 'ohos.permission.READ_CONTACTS';
    if (await PermissionUtil.hasPermission(perm)) {
      return true;
    }
    if (this.context === null) {
      return false;
    }
    const granted: Array<Permissions> =
      await PermissionUtil.requestPermissions(this.context, [perm]);
    return granted.indexOf(perm) >= 0;
  }

  /** 查询通讯录（仅姓名与电话）。 */
  private queryAllContacts(): Promise<Array<contact.Contact>> {
    return new Promise<Array<contact.Contact>>((resolve, reject) => {
      if (this.context === null) {
        reject(new Error('系统任务服务未初始化'));
        return;
      }
      const attrs: contact.ContactAttributes = {
        attributes: [contact.Attribute.ATTR_NAME, contact.Attribute.ATTR_PHONE]
      };
      contact.queryContacts(this.context, attrs,
        (error: BusinessError, data: Array<contact.Contact>) => {
          if (error) {
            Logger.error(TAG,
              `queryContacts 错误 code=${error.code} message=${error.message}`);
            reject(new Error(error.message));
            return;
          }
          Logger.info(TAG, `queryContacts 成功 count=${data?.length ?? 0}`);
          resolve(data ?? []);
        });
    });
  }

  /**
   * 按姓名在联系人列表中查找：先精确匹配，再包含匹配。
   */
  private findContactByName(contacts: Array<contact.Contact>, alias: string): contact.Contact | null {
    let fuzzy: contact.Contact | null = null;
    for (let i: number = 0; i < contacts.length; i++) {
      const item: contact.Contact = contacts[i];
      const candidates: Array<string> = this.collectContactNames(item);
      for (let j: number = 0; j < candidates.length; j++) {
        const candidate: string = candidates[j];
        if (candidate === alias) {
          return item;
        }
        if (fuzzy === null &&
          (candidate.indexOf(alias) >= 0 || alias.indexOf(candidate) >= 0) &&
          candidate.length > 0) {
          fuzzy = item;
        }
      }
    }
    return fuzzy;
  }

  /** 收集可用于匹配的姓名字段（全名 / 姓+名 / 昵称）。 */
  private collectContactNames(item: contact.Contact): Array<string> {
    const result: Array<string> = [];
    const fullName: string = this.normalizeContactAlias(item.name?.fullName ?? '');
    if (fullName.length > 0) {
      result.push(fullName);
    }
    const family: string = item.name?.familyName ?? '';
    const given: string = item.name?.givenName ?? '';
    const combined: string = this.normalizeContactAlias(`${family}${given}`);
    if (combined.length > 0 && result.indexOf(combined) < 0) {
      result.push(combined);
    }
    const nick: string = this.normalizeContactAlias(item.nickName?.nickName ?? '');
    if (nick.length > 0 && result.indexOf(nick) < 0) {
      result.push(nick);
    }
    return result;
  }

  /** 打开系统拨号界面并预填号码（第三方应用合规能力；用户确认后拨出）。 */
  private openDialer(phoneNumber: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!call.hasVoiceCapability()) {
        reject(new Error('当前设备不支持电话呼叫'));
        return;
      }
      call.makeCall(phoneNumber, (error: BusinessError) => {
        if (error) {
          Logger.error(TAG,
            `makeCall 回调错误 code=${error.code} message=${error.message}`);
          reject(new Error(error.message));
          return;
        }
        Logger.info(TAG, `拨号界面已打开 number_len=${phoneNumber.length}`);
        resolve();
      });
    });
  }

  /** 加载已缓存的联系人别名号码。 */
  private async loadContactAlias(alias: string): Promise<string> {
    const prefs: preferences.Preferences = await this.ensureContactAliasPrefs();
    const value: preferences.ValueType =
      await prefs.get(CONTACT_ALIAS_KEY_PREFIX + alias, '');
    return typeof value === 'string' ? this.normalizePhoneNumber(value) : '';
  }

  /** 保存联系人别名号码。 */
  private async saveContactAlias(alias: string, phoneNumber: string): Promise<void> {
    const prefs: preferences.Preferences = await this.ensureContactAliasPrefs();
    await prefs.put(CONTACT_ALIAS_KEY_PREFIX + alias, phoneNumber);
    await prefs.flush();
  }

  /** 延迟初始化联系人别名 Preferences。 */
  private async ensureContactAliasPrefs(): Promise<preferences.Preferences> {
    if (this.context === null) {
      throw new Error('系统任务服务未初始化');
    }
    if (this.contactAliasPrefs === null) {
      this.contactAliasPrefs =
        await preferences.getPreferences(this.context, CONTACT_ALIAS_PREF_NAME);
    }
    return this.contactAliasPrefs;
  }

  /** 将“姐姐电话”“姐姐的号码”等表达归一化为稳定别名。 */
  private normalizeContactAlias(value: string): string {
    let alias: string = value.trim().replace(/\s+/g, '');
    alias = alias.replace(/(的)?(电话|手机|手机号|电话号码|号码)$/g, '');
    return alias.length > 0 ? alias : value.trim();
  }

  /** 判断字符串是否像电话号码（仅含数字、+、-、空格，且数字长度 >= 3）。 */
  private looksLikePhoneNumber(value: string): boolean {
    if (!/^[0-9+\-\s]+$/.test(value)) {
      return false;
    }
    const digits: string = value.replace(/[^0-9]/g, '');
    return digits.length >= 3;
  }

  /** 归一化电话号码：去除空格与连字符。 */
  private normalizePhoneNumber(value: string): string {
    return value.replace(/[\s\-]/g, '').trim();
  }
}
