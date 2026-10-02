/**
 * @file LocalLLMEngine.ets
 * @module services
 * @description 端侧文本兜底引擎（完整可用，不依赖缺失的 Qwen .ms）。
 *
 * 云端文本 API 失败时由 LLMClient 调用：
 * - 任务规划类 prompt → OfflinePlanner 产出 JSON tasks
 * - 普通对话 → 本地固定话术，保证有反馈
 *
 * 资产：无需额外模型文件；与 OfflinePlanner 共用规则，覆盖打电话/短信/打车/识物/识药。
 */

import { Logger } from '../utils/Logger';
import { LLMMessage } from '../agent/types';
import { LocalEngine } from './LLMClient';
import { planOffline } from '../agent/OfflinePlanner';
import { AgentPlanResponse } from '../agent/types';

const TAG: string = 'LocalLLMEngine';

export class LocalLLMEngine implements LocalEngine {
  private static instance: LocalLLMEngine | null = null;
  private _ready: boolean = false;

  public get ready(): boolean {
    return this._ready;
  }

  public get kind(): string {
    return 'local_llm';
  }

  private constructor() {}

  public static getInstance(): LocalLLMEngine {
    if (LocalLLMEngine.instance === null) {
      LocalLLMEngine.instance = new LocalLLMEngine();
    }
    return LocalLLMEngine.instance;
  }

  /**
   * 初始化：规则引擎即时就绪，不加载大模型权重。
   */
  public async init(_context: Context): Promise<void> {
    this._ready = true;
    Logger.info(TAG, '端侧文本兜底引擎已就绪（离线规则，完整可用）');
  }

  /**
   * 端侧推理：规划类请求返回 JSON，其余返回口语化本地回复。
   */
  public async infer(messages: LLMMessage[]): Promise<string> {
    if (!this._ready) {
      throw new Error('端侧文本兜底引擎未就绪');
    }
    const userText: string = this.lastUserText(messages);
    const systemText: string = this.systemText(messages);
    if (this.isPlanRequest(systemText, userText)) {
      const plan: AgentPlanResponse = planOffline(userText);
      // 与后端 /agent/plan 同构，供 IntentRouter.parsePlanJson 解析
      return JSON.stringify({
        tasks: plan.tasks,
        tts_message: plan.tts_message
      });
    }
    return this.offlineChat(userText);
  }

  private lastUserText(messages: LLMMessage[]): string {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'user' && messages[i].content.length > 0) {
        return messages[i].content.trim();
      }
    }
    return '';
  }

  private systemText(messages: LLMMessage[]): string {
    let s: string = '';
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role === 'system') {
        s += messages[i].content;
      }
    }
    return s;
  }

  private isPlanRequest(systemText: string, userText: string): boolean {
    if (systemText.indexOf('任务规划') >= 0 || systemText.indexOf('"tasks"') >= 0) {
      return true;
    }
    if (systemText.indexOf('action') >= 0 && systemText.indexOf('tts_message') >= 0) {
      return true;
    }
    // 无 system 时，若用户话本身是可执行指令，也当规划处理
    const plan: AgentPlanResponse = planOffline(userText);
    return plan.tasks.length > 0;
  }

  private offlineChat(userText: string): string {
    if (userText.length === 0) {
      return '我在，请说出您的指令。';
    }
    const plan: AgentPlanResponse = planOffline(userText);
    if (plan.tasks.length > 0) {
      return plan.tts_message;
    }
    return '本地模式已开启。您可以说：打电话、发短信、打车、识别物品或识别药品。';
  }

  public destroy(): void {
    this._ready = false;
    Logger.info(TAG, '端侧文本兜底引擎已释放');
  }
}
