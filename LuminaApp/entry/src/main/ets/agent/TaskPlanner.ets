/**
 * @file TaskPlanner.ets
 * @module agent
 * @description 端侧任务执行器（前后端分离版）。
 *
 * 职责：
 * 1. 接收后端下发的 BackendTask 列表，按顺序逐项执行；
 * 2. 根据 task.action 分发到对应的服务调用（短信 / 叫车 / 视觉分析 / 端侧图像分类 / 紧急电话 / 屏幕朗读）；
 * 3. 支持 image_classify action 调用 VisionService.classifyImage()（P0-3 端侧视觉大模型落地）；
 * 4. 单任务失败不阻断后续，逐项 TTS 反馈（VUI 铁律 3：禁止静默失败）。
 *
 * 设计要点（2026-07-20 前后端分离 + P0-3 端侧视觉落地）：
 * 1. **前后端分离**：任务规划由后端 /api/v1/agent/plan 完成，端侧仅负责执行（铁律 1）；
 * 2. **端侧视觉落地**：image_classify action 走端侧 MobileNetV2 + MindSpore Lite 优先，云端 Qwen-VL 兜底；
 * 3. **图像缓存**：capture_image action 写入 currentImageBase64，供后续 image_classify / vision_analyze 使用；
 * 4. **逐项 TTS 反馈**：每个动作执行前后必须播报，视障用户全程可感知（VUI 铁律 3）；
 * 5. **错误隔离**：单任务 catch 不阻断后续，仅 TTS 提示失败。
 *
 * P0-3 端侧视觉大模型落地路径：
 * - 后端识别"这是什么"意图 → 下发 {action: 'image_classify'} 任务
 * - 端侧 TaskPlanner.executeOne('image_classify') → VisionService.classifyImage()
 * - VisionService 内部端侧 LocalImageClassifier（MobileNetV2）优先 + 云端 LLMClient.chat() 兜底
 * - 端侧就绪时毫秒级响应，兑现作品介绍"端侧视觉"承诺。
 *
 * 系统任务落地说明：
 * - send_sms / call_ride / emergency_call 由 SystemTaskService 拉起系统应用执行；
 * - read_screen 由 ScreenReaderService 朗读本应用当前界面内容（第三方应用无系统级屏幕取词权限）。
 *
 * ⚠️ 前后台交接（Handoff）机制（2026-09-28 修复「拨号后不跳导航」）：
 * 打电话 / 发短信 / 叫车都是「系统级跳转」——执行后本应用立即退到后台，
 * 而鸿蒙禁止普通应用在后台 startAbility 拉起别的应用（需 system_basic 级权限，三方应用拿不到），
 * 旧实现会继续原地执行下一个任务，结果被系统静默拒绝，表现为「打开拨号界面后没有跳转到导航」。
 *
 * 现方案：执行到系统级跳转任务后，若队列还有后续任务，则**挂起**等待用户回到光语助手
 * （EntryAbility.onForeground → notifyForeground()）再继续，最长等 HANDOFF_WAIT_MS；
 * 超时或仍被拒绝则如实播报，绝不静默失败（VUI 铁律 3）。
 */

import common from '@ohos.app.ability.common';
import { Logger } from '../utils/Logger';
import { SpeechService } from '../services/SpeechService';
import { LLMClient } from '../services/LLMClient';
import { VisionService } from '../services/VisionService';
import { SystemTaskService, ERR_BACKGROUND_BLOCKED } from '../services/SystemTaskService';
import { ScreenReaderService } from '../services/ScreenReaderService';
import { BackendTask, MedicineRecognitionResult } from './types';

const TAG: string = 'TaskPlanner';

/** 系统级跳转后等待用户回到本应用的最长时间（毫秒） */
const HANDOFF_WAIT_MS: number = 20000;

/**
 * 系统级跳转成功后的状态沉降时间（毫秒）。
 * 拉起拨号盘 / 地图后，系统回调 onBackground 存在几帧延迟；
 * 若紧接着就执行下一个 startAbility，可能撞上"inForeground 尚未刷新"的竞态而被系统拒绝。
 * 这里主动让出一小段时间，使前后台状态先稳定下来。
 */
const HANDOFF_SETTLE_MS: number = 800;

/** 任务在 UI 上的执行状态 */
export type TaskRunStatus = 'pend' | 'run' | 'done' | 'fail';

/** 单个任务状态变化的订阅回调（驱动任务卡片实时打勾） */
export interface TaskProgressCallback {
  onTaskStatus: (index: number, total: number, task: BackendTask, status: TaskRunStatus, message: string) => void;
}

/** execute() 的可选项 */
export interface ExecuteOptions {
  /**
   * 前置统一播报文案（通常是后端 tts_message）。
   * 存在系统级跳转任务时，会在**应用仍在前台**时先播完这句，
   * 避免跳转后应用退到后台导致长文案播报被系统打断。
   */
  preAnnounce?: string;
  /** 任务状态回调，用于 UI 实时打勾 */
  progress?: TaskProgressCallback;
}

/**
 * TaskPlanner —— 任务执行器（单例）。
 *
 * 前后端分离架构下作为 BackendTask 的分发执行器，不持有本地任务规划逻辑。
 * P0-3 增强：支持 image_classify action 调用端侧 MobileNetV2 图像分类。
 */
export class TaskPlanner {
  private static instance: TaskPlanner | null = null;
  private speechService: SpeechService;
  private llmClient: LLMClient;
  private visionService: VisionService;
  private systemTaskService: SystemTaskService;
  /** 当前请求的图像 base64（由 capture_image action 写入，供后续 action 使用） */
  private currentImageBase64: string = '';
  /** 等待「应用回到前台」的挂起回调队列（系统级跳转后恢复执行用） */
  private foregroundWaiters: Array<() => void> = [];
  /** 全局任务进度订阅者（UI 挂一次即可同时覆盖语音链路与文本链路） */
  private progressListener: TaskProgressCallback | null = null;

  private constructor() {
    this.speechService = SpeechService.getInstance();
    this.llmClient = LLMClient.getInstance();
    this.visionService = VisionService.getInstance();
    this.systemTaskService = SystemTaskService.getInstance();
  }

  /**
   * 获取 TaskPlanner 单例。
   * @returns TaskPlanner 实例
   */
  public static getInstance(): TaskPlanner {
    if (TaskPlanner.instance === null) {
      TaskPlanner.instance = new TaskPlanner();
    }
    return TaskPlanner.instance;
  }

  /**
   * 注入 UIAbilityContext，使拨号 / 短信 / 叫车等系统任务可用。
   * 由 Agent.init() 统一调用。
   * @param context UIAbilityContext
   */
  public init(context: common.UIAbilityContext): void {
    this.systemTaskService.init(context);
    Logger.info(TAG, 'TaskPlanner 已注入系统任务上下文');
  }

  /**
   * 应用回到前台（EntryAbility.onForeground 调用）。
   * 唤醒所有挂起等待的续跑任务。
   */
  public notifyForeground(): void {
    this.systemTaskService.markForeground();
    const waiters: Array<() => void> = this.foregroundWaiters;
    this.foregroundWaiters = [];
    if (waiters.length > 0) {
      Logger.info(TAG, `应用回到前台，唤醒 ${waiters.length} 个挂起任务`);
    }
    for (let i: number = 0; i < waiters.length; i++) {
      waiters[i]();
    }
  }

  /** 应用退到后台（EntryAbility.onBackground 调用）。 */
  public notifyBackground(): void {
    this.systemTaskService.markBackground();
  }

  /** 是否存在挂起等待前台的任务（供 UI 提示"请返回光语助手"）。 */
  public hasPendingHandoff(): boolean {
    return this.foregroundWaiters.length > 0;
  }

  /**
   * 注册全局任务进度订阅者（UI 层在页面 onAppear 时调用一次即可）。
   * @param listener 进度回调，传 null 取消订阅
   */
  public setProgressListener(listener: TaskProgressCallback | null): void {
    this.progressListener = listener;
    Logger.info(TAG, listener === null ? '任务进度订阅已取消' : '任务进度订阅已注册');
  }

  /**
   * 挂起等待应用回到前台。
   * @param timeoutMs 最长等待时间
   * @returns 是否在超时前回到前台
   */
  private waitForForeground(timeoutMs: number): Promise<boolean> {
    if (this.systemTaskService.isInForeground()) {
      return Promise.resolve(true);
    }
    Logger.info(TAG, `挂起任务队列，等待用户回到光语助手（最长 ${timeoutMs}ms）`);
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        Logger.warn(TAG, '等待回到前台超时');
        resolve(false);
      }, timeoutMs);
      const handler: () => void = () => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(true);
      };
      this.foregroundWaiters.push(handler);
    });
  }

  /** 简单延时（用于系统跳转后的状态沉降）。 */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 判断 action 是否为「执行后本应用会退到后台」的系统级跳转任务。 */
  private isSystemHandoff(action: string): boolean {
    return action === 'emergency_call'
      || action === 'make_call'
      || action === 'dial'
      || action === 'call_ride'
      || action === 'send_sms';
  }

  /** 上报任务状态（无回调时静默）。 */
  private emitStatus(index: number, total: number, task: BackendTask,
    status: TaskRunStatus, message: string, progress?: TaskProgressCallback): void {
    if (progress) {
      progress.onTaskStatus(index, total, task, status, message);
    }
  }

  /**
   * 顺序执行后端下发的任务列表。
   *
   * 执行策略：
   * 1. 按 tasks 数组顺序逐项执行，逐项上抛状态（UI 实时打勾）；
   * 2. 根据 task.action 分发到对应服务调用；
   * 3. **前后台交接**：遇到系统级跳转任务（拨号/短信/叫车）时，
   *    执行前确保在前台，执行后若还有后续任务则挂起等待用户回到本应用再继续；
   * 4. 单任务失败 catch 不阻断后续，逐项 TTS 反馈（VUI 铁律 3：禁止静默失败）。
   *
   * @param tasks 后端规划的任务列表
   * @param options 前置播报与进度回调等可选项
   * @returns 无返回值，所有反馈通过 TTS 与 progress 回调完成
   */
  public async execute(tasks: Array<BackendTask>, options?: ExecuteOptions): Promise<void> {
    if (!tasks || tasks.length === 0) {
      Logger.warn(TAG, 'execute: 任务列表为空，跳过执行');
      return;
    }

    // 每次执行前重置图像缓存
    this.currentImageBase64 = '';
    const total: number = tasks.length;
    // 进度订阅优先取本次调用的回调，否则用全局订阅（UI 只挂一次即可覆盖所有链路）
    let progress: TaskProgressCallback | undefined = options?.progress;
    if (!progress && this.progressListener !== null) {
      progress = this.progressListener;
    }
    Logger.info(TAG, `execute: 开始执行 ${total} 个任务`);

    // 1) 含系统级跳转时，先在仍处于前台时播完统一文案，
    //    否则跳转后应用退到后台，长文案会被系统音频策略打断。
    //    跳转类任务自身不再重复播报（避免"已为您拨通…"念两遍）。
    const quietHandoffTts: boolean = !!options?.preAnnounce && this.containsHandoff(tasks);
    if (quietHandoffTts && options && options.preAnnounce) {
      await this.speechService.speak(options.preAnnounce);
    }

    for (let i: number = 0; i < total; i++) {
      const task: BackendTask = tasks[i];
      // 本次任务是否抑制独立播报：默认沿用统一前置播报的设置
      let suppressThis: boolean = quietHandoffTts;

      // 2) 系统级跳转任务必须在前台发起：若此时已在后台（上一次跳转留下的状态），先挂起等用户返回
      if (this.isSystemHandoff(task.action) && !this.systemTaskService.isInForeground()) {
        this.emitStatus(i, total, task, 'run', '等待返回光语助手', progress);
        const back: boolean = await this.waitForForeground(HANDOFF_WAIT_MS);
        if (!back) {
          const tip: string = '需要回到光语助手才能继续执行，请按返回键回到应用';
          Logger.warn(TAG, `任务 [${task.action}] 等待回到前台超时`);
          this.emitStatus(i, total, task, 'fail', '需要返回应用继续', progress);
          this.speechService.speak(tip);
          continue;
        }
        // 刚回到前台，此时播报能正常被听到：放开该任务的独立播报作为续跑反馈
        suppressThis = false;
      }

      this.emitStatus(i, total, task, 'run', '执行中', progress);
      Logger.info(TAG, `执行任务 [${i + 1}/${total}] action=${task.action} target=${task.target}`);

      try {
        const resultMsg: string = await this.executeOne(task, suppressThis);
        this.emitStatus(i, total, task, 'done', resultMsg.length > 0 ? resultMsg : '已完成', progress);
        // 系统级跳转后让出一点时间，等系统的 onBackground 回调把前后台状态刷新到位，
        // 否则下一个任务的 startAbility 可能撞上竞态被判为"后台启动"而失败。
        if (this.isSystemHandoff(task.action) && i < total - 1) {
          await this.delay(HANDOFF_SETTLE_MS);
        }
      } catch (error) {
        const msg: string = error instanceof Error ? error.message : '未知错误';

        // 3) 竞态兜底：恰好被系统判定为后台而拒绝 → 等回到前台重试一次
        if (msg === ERR_BACKGROUND_BLOCKED && this.isSystemHandoff(task.action)) {
          Logger.warn(TAG, `任务 [${task.action}] 因后台限制被拒，等待回到前台后重试`);
          this.emitStatus(i, total, task, 'run', '等待返回光语助手', progress);
          const back: boolean = await this.waitForForeground(HANDOFF_WAIT_MS);
          if (back) {
            try {
              const retryMsg: string = await this.executeOne(task, false);
              this.emitStatus(i, total, task, 'done', retryMsg.length > 0 ? retryMsg : '已完成', progress);
              continue;
            } catch (retryErr) {
              const retryMsg: string = retryErr instanceof Error ? retryErr.message : '未知错误';
              Logger.error(TAG, `任务 [${task.action}] 重试仍失败: ${retryMsg}`);
              this.emitStatus(i, total, task, 'fail', '执行失败', progress);
              this.speechService.speak(`任务执行失败：${retryMsg}`);
              continue;
            }
          }
        }

        // 单任务失败不阻断后续，仅 TTS 反馈（VUI 铁律 3：禁止静默失败）
        Logger.error(TAG, `任务 [${task.action}] 执行失败: ${msg}`);
        this.emitStatus(i, total, task, 'fail', '执行失败', progress);
        this.speechService.speak(`任务执行失败：${msg}`);
      }
    }

    Logger.info(TAG, 'execute: 所有任务执行完毕');
  }

  /** 任务列表中是否含系统级跳转任务。 */
  private containsHandoff(tasks: Array<BackendTask>): boolean {
    for (let i: number = 0; i < tasks.length; i++) {
      if (this.isSystemHandoff(tasks[i].action)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 执行单个 BackendTask。
   *
   * 分发规则：
   * - send_sms                 -> SystemTaskService.sendSms() 解析联系人并拉起系统短信应用预填正文；
   * - call_ride                -> SystemTaskService.callRide() 拉起地图/出行应用叫车或规划路线；
   * - capture_image            -> 调用 VisionService.captureFrame() 取帧并缓存；
   * - image_classify           -> 调用 VisionService.classifyImage()（端侧 MobileNetV2 优先 + 云端兜底）；
   * - vision_analyze           -> 调用 LLMClient.analyzeImage()（云端视觉分析）；
   * - medicine_recognition     -> 自动取帧 + VisionService.recognizeMedicine() 药品识别；
   * - emergency_call/make_call/dial -> SystemTaskService.dial() 查通讯录并预填拨号盘；未找到播报「没有」；
   * - read_screen              -> ScreenReaderService.getScreenText() 朗读当前界面内容；
   * - 未知 action              -> TTS 播报"未知指令：${action}"，但不阻断后续任务。
   *
   * @param task 单个后端任务
   * @param suppressHandoffTts 是否抑制系统级跳转任务的独立播报（已由 execute 统一前置播报）
   * @returns 用于任务卡片展示的简短结果文案
   * @throws Error 任务执行失败时抛出，由 execute() catch 后 TTS 反馈
   */
  private async executeOne(task: BackendTask, suppressHandoffTts: boolean = false): Promise<string> {
    // 仅对系统级跳转任务抑制重复播报；视觉识别等任务的朗读结果必须保留
    const quiet: boolean = suppressHandoffTts && this.isSystemHandoff(task.action);

    switch (task.action) {
      case 'send_sms': {
        const target: string = task.target ?? '';
        const content: string = task.content ?? '';
        const resultMsg: string = await this.systemTaskService.sendSms(target, content);
        if (!quiet) {
          await this.speechService.speak(resultMsg);
        }
        Logger.info(TAG, `send_sms: target=${target} content_len=${content.length}`);
        return resultMsg;
      }
      case 'call_ride': {
        const resultMsg: string = await this.systemTaskService.callRide(task.target ?? '');
        if (!quiet) {
          await this.speechService.speak(resultMsg);
        }
        Logger.info(TAG, 'call_ride: 已触发叫车流程');
        return resultMsg;
      }
      case 'capture_image': {
        // 拍摄/取帧，缓存图像供后续 image_classify / vision_analyze 使用
        this.currentImageBase64 = await this.visionService.captureFrame();
        Logger.info(TAG, `capture_image: base64_len=${this.currentImageBase64.length}`);
        return this.currentImageBase64.length > 0 ? '已取帧' : '取帧失败';
      }
      case 'image_classify': {
        // P0-3 端侧视觉大模型落地核心路径：
        // 端侧 MobileNetV2 + MindSpore Lite 优先，云端 Qwen-VL 兜底
        if (this.currentImageBase64.length === 0) {
          this.speechService.speak('视觉识别需要图像数据，请先拍摄或取帧。');
          Logger.warn(TAG, 'image_classify: 图像缓存为空，跳过调用');
          return '缺少图像';
        }
        const classifyResult: string = await this.visionService.classifyImage(this.currentImageBase64);
        if (classifyResult.length > 0) {
          this.speechService.speak(classifyResult);
        }
        Logger.info(TAG, `image_classify: result_len=${classifyResult.length}`);
        return classifyResult.length > 0 ? '识别完成' : '未识别出结果';
      }
      case 'vision_analyze': {
        // 云端视觉分析（向后兼容，与 image_classify 区别：纯云端 Qwen-VL）
        if (this.currentImageBase64.length === 0) {
          this.speechService.speak('视觉分析需要图像数据，请先拍摄或取帧。');
          Logger.warn(TAG, 'vision_analyze: 图像缓存为空，跳过调用');
          return '缺少图像';
        }
        const ttsMessage: string = await this.llmClient.analyzeImage(this.currentImageBase64);
        if (ttsMessage.length > 0) {
          this.speechService.speak(ttsMessage);
        }
        Logger.info(TAG, `vision_analyze: tts_len=${ttsMessage.length}`);
        return ttsMessage.length > 0 ? '分析完成' : '分析失败';
      }
      case 'read_text': {
        // 纯文字/文档朗读（本地 OCR 优先 + 云端视觉大模型兜底）
        if (this.currentImageBase64.length === 0) {
          this.speechService.speak('正在拍摄文档，请把纸质文档对准镜头。');
          this.currentImageBase64 = await this.visionService.captureFrame();
        }
        if (this.currentImageBase64.length === 0) {
          this.speechService.speak('未拍摄到清晰画面，请把纸质文档对准镜头后重试。');
          Logger.warn(TAG, 'read_text: 图像缓存为空，跳过调用');
          return '缺少图像';
        }
        const textMessage: string = await this.visionService.readTextOffline(this.currentImageBase64);
        if (textMessage.length > 0) {
          this.speechService.speak(textMessage);
        }
        Logger.info(TAG, `read_text: text_len=${textMessage.length}`);
        return textMessage.length > 0 ? '朗读完成' : '未识别到文字';
      }
      case 'emergency_call':
      case 'make_call':
      case 'dial': {
        const target: string = task.target ?? '';
        const resultMsg: string = await this.systemTaskService.dial(target);
        if (!quiet) {
          await this.speechService.speak(resultMsg);
        }
        Logger.info(TAG, `${task.action}: target=${target}`);
        return resultMsg;
      }
      case 'medicine_recognition':
      case 'medicine_recognize': {
        return await this.executeMedicineRecognition();
      }
      case 'read_screen': {
        const screenText: string = ScreenReaderService.getInstance().getScreenText();
        if (screenText.length > 0) {
          await this.speechService.speak(screenText);
          Logger.info(TAG, `read_screen: 已朗读屏幕内容 len=${screenText.length}`);
          return '已朗读屏幕内容';
        }
        this.speechService.speak('当前屏幕没有可朗读的内容');
        Logger.info(TAG, 'read_screen: 无可朗读内容');
        return '无可朗读内容';
      }
      default: {
        // 未知 action：TTS 提示但不阻断后续任务
        const unknownMsg: string = `未知指令：${task.action}`;
        this.speechService.speak(unknownMsg);
        Logger.warn(TAG, `未知 action: ${task.action}`);
        return unknownMsg;
      }
    }
  }

  /**
   * 药品识别任务：确保有图像后调用 VisionService.recognizeMedicine 并 TTS 播报。
   * 若图像缓存为空则先静默取帧。
   * @returns 用于任务卡片展示的简短结果文案
   */
  private async executeMedicineRecognition(): Promise<string> {
    if (this.currentImageBase64.length === 0) {
      this.speechService.speak('正在拍摄药品，请把药盒对准镜头。');
      this.currentImageBase64 = await this.visionService.captureFrame();
    }
    if (this.currentImageBase64.length === 0) {
      this.speechService.speak('没有拍到药品图像，请重试。');
      Logger.warn(TAG, 'medicine_recognition: 图像缓存为空');
      return '缺少图像';
    }
    const result: MedicineRecognitionResult =
      await this.visionService.recognizeMedicine(this.currentImageBase64);
    if (result.tts.length > 0) {
      this.speechService.speak(result.tts);
    }
    Logger.info(TAG, `medicine_recognition: name=${result.info.name ?? ''}`);
    return result.tts.length > 0 ? '药品识别完成' : '未识别出药品';
  }
}
