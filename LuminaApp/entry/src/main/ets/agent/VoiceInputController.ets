/**
 * @file VoiceInputController.ets
 * @module agent
 * @description 语音输入控制器 — 端云双态架构的核心协调器。
 *
 * 职责：
 * 1. 启动 ASR（SpeechService.startASR → ASRService → DashScope Paraformer WebSocket）；
 * 2. 识别完成后，将文本发送到后端 /api/v1/agent/plan 进行任务规划；
 * 3. 规划结果交由 TaskPlanner.execute() 执行（紧急电话/短信/打车/拍照识别等）；
 * 4. TTS 播报规划结果的 tts_message。
 *
 * 闭环流程：
 * 用户长按屏幕 → VoiceInputController.start()
 *   → ASR 实时识别 → onResult（中间结果 UI 更新）
 * 用户松开 → VoiceInputController.stop()
 *   → ASR onComplete(finalText)
 *   → HttpClient.post('/api/v1/agent/plan', {text: finalText})
 *   → AgentPlanResponse {tasks, tts_message}
 *   → SpeechService.speak(tts_message)
 *   → TaskPlanner.execute(tasks)
 *
 * 架构原则（端云双态架构 - 铁律 1）：
 * - ASR 走端侧直连（低延迟路径），不经过后端；
 * - Agent 任务规划走后端代理（复杂推理路径）；
 * - 任务执行回端侧（打电话/发短信/打车/拍照）。
 */

import { SpeechService } from '../services/SpeechService';
import { TaskPlanner } from './TaskPlanner';
import { IntentRouter } from './IntentRouter';
import { AccessibilityUtils } from '../utils/AccessibilityUtils';
import { Logger } from '../utils/Logger';
import { BackendTask, AgentPlanResponse } from './types';

const TAG: string = 'VoiceInputController';

/** 语音输入状态 */
export type VoiceInputState =
  | 'idle'          // 空闲
  | 'listening'     // 正在录音识别
  | 'processing'    // 识别完成，正在请求后端规划
  | 'executing'     // 规划完成，正在执行任务
  | 'done'          // 全部完成
  | 'error';        // 出错

/** 语音输入回调 */
export interface VoiceInputCallbacks {
  onStateChange: (state: VoiceInputState) => void;
  onPartialResult: (text: string) => void;
  onError: (msg: string) => void;
  /**
   * 规划已生成、任务即将开始执行（execute 之前触发）。
   * 用于把【任务拆解 Task List】卡片先上屏，随后由 TaskPlanner 的进度回调实时打勾。
   */
  onPlanReady?: (tasks: Array<BackendTask>) => void;
  /** 规划完成：用户话术 + 助手回复 + 规划任务列表（用于上屏完整展示） */
  onPlanDone?: (userText: string, assistantText: string, tasks?: Array<BackendTask>) => void;
}

export class VoiceInputController {
  private static instance: VoiceInputController | null = null;
  private speechService: SpeechService;
  private intentRouter: IntentRouter;
  private taskPlanner: TaskPlanner;
  private callbacks: VoiceInputCallbacks | null = null;
  private currentState: VoiceInputState = 'idle';
  private isRunning: boolean = false;

  private constructor() {
    this.speechService = SpeechService.getInstance();
    this.intentRouter = IntentRouter.getInstance();
    this.taskPlanner = TaskPlanner.getInstance();
  }

  public static getInstance(): VoiceInputController {
    if (VoiceInputController.instance === null) {
      VoiceInputController.instance = new VoiceInputController();
    }
    return VoiceInputController.instance;
  }

  /**
   * 启动语音输入（用户按下屏幕时调用）。
   * @param callbacks 状态回调
   */
  public start(callbacks: VoiceInputCallbacks): void {
    if (this.isRunning) {
      Logger.warn(TAG, '语音输入已在进行中，通知上层释放');
      // 静默返回会导致上层 isProcessing 闩死（全屏点击无响应），必须回调让 UI 解锁
      callbacks.onError('语音通道被占用，请稍后重试');
      return;
    }
    // 接管上一次未清理的回调引用，避免旧回调干扰本次会话
    this.callbacks = callbacks;
    this.isRunning = true;
    this.setState('listening');

    // 振动反馈：开始录音
    AccessibilityUtils.getInstance().vibrate(20);

    this.speechService.startASR(
      (text: string, isFinal: boolean) => {
        // onResult：中间结果或最终结果
        if (!isFinal && this.callbacks) {
          this.callbacks.onPartialResult(text);
        }
      },
      (msg: string) => {
        // onError
        Logger.error(TAG, 'ASR 错误: ' + msg);
        this.isRunning = false;
        this.setState('error');
        const tip: string = (msg && msg.length > 0) ? msg : '没有听到您的声音，请按住屏幕重试';
        if (this.callbacks) {
          this.callbacks.onError(tip);
        }
        this.speechService.speak(tip).catch(() => {});
      },
      (finalText: string) => {
        // onComplete：识别完成，调用后端规划
        this.onASRComplete(finalText);
      }
    );
  }

  /**
   * 停止语音输入（用户松开屏幕时调用）。
   */
  public stop(): void {
    if (!this.isRunning) {
      return;
    }
    Logger.info(TAG, '用户松开，停止 ASR');
    this.speechService.stopASR();
    // onComplete 回调会在 ASRService 中触发
  }

  /**
   * ASR 识别完成，调用后端 Agent 任务规划。
   */
  private async onASRComplete(text: string): Promise<void> {
    Logger.info(TAG, 'ASR 识别结果: ' + text);

    if (text.length === 0) {
      this.isRunning = false;
      this.setState('error');
      this.speechService.speak('没有听到您的声音，请重试').catch(() => {});
      if (this.callbacks) {
        this.callbacks.onError('识别结果为空');
      }
      return;
    }

    this.setState('processing');

    try {
      // 与文本指令共用 IntentRouter（后端 plan + 端侧 LLM 兜底）
      const plan: AgentPlanResponse = await this.intentRouter.route(text);
      Logger.info(TAG, '规划完成，tasks=' + plan.tasks.length + ', tts=' + plan.tts_message);

      if (plan.tasks && plan.tasks.length > 0) {
        // 1) 先把任务卡片上屏（此时全部为待执行），让用户看到拆解结果
        if (this.callbacks && this.callbacks.onPlanReady) {
          this.callbacks.onPlanReady(plan.tasks as Array<BackendTask>);
        }
        // 2) 再逐项执行：进度由 TaskPlanner 的进度回调驱动卡片实时打勾。
        //    preAnnounce 使「已为您拨通女儿电话，并为您叫车前往医院」在应用仍处前台时播完，
        //    避免系统级跳转把应用切到后台后 TTS 被系统打断。
        this.setState('executing');
        await this.taskPlanner.execute(plan.tasks as Array<BackendTask>, {
          preAnnounce: plan.tts_message
        });
      }

      if (this.callbacks && this.callbacks.onPlanDone) {
        this.callbacks.onPlanDone(text, plan.tts_message, plan.tasks as Array<BackendTask>);
      }

      this.isRunning = false;
      this.setState('done');
    } catch (error) {
      Logger.error(TAG, '指令处理失败: ' + (error as Error).message);
      this.isRunning = false;
      this.setState('error');
      const errMsg: string = '语音指令处理失败：' + (error as Error).message;
      this.speechService.speak(errMsg).catch(() => {});
      if (this.callbacks) {
        this.callbacks.onError(errMsg);
      }
    }
  }

  private setState(state: VoiceInputState): void {
    this.currentState = state;
    Logger.info(TAG, '状态变更: ' + state);
    if (this.callbacks) {
      this.callbacks.onStateChange(state);
    }
  }

  public getState(): VoiceInputState {
    return this.currentState;
  }

  public isBusy(): boolean {
    return this.isRunning;
  }

  public destroy(): void {
    this.isRunning = false;
    this.callbacks = null;
    this.setState('idle');
  }
}
