/**
 * @file Agent.ets
 * @module agent
 * @description 端侧 Agent 主控（前后端分离版）。
 *
 * 职责：
 * 1. 对外暴露统一入口 invoke()，接收 AgentRequest 返回 AgentResponse；
 * 2. 串联 IntentRouter（后端意图识别）→ TaskPlanner（端侧任务执行）；
 * 3. 维护会话上下文（多轮对话）。
 *
 * 设计要点（前后端分离架构 + P0-3 端侧视觉落地）：
 * 1. 前后端分离：意图识别与任务规划由后端 /api/v1/agent/plan 完成（铁律 1）；
 * 2. 端侧执行：TaskPlanner.execute() 执行后端下发的 BackendTask 列表；
 * 3. 端侧视觉：image_classify action 走端侧 MobileNetV2 优先 + 云端兜底（P0-3 落地）；
 * 4. TTS 兜底：所有错误路径通过 accessibility.speak() 反馈（VUI 铁律 3）。
 */

import common from '@ohos.app.ability.common';
import { Logger } from '../utils/Logger';
import { AccessibilityUtils } from '../utils/AccessibilityUtils';
import { IntentRouter } from './IntentRouter';
import { TaskPlanner } from './TaskPlanner';
import { VisionService } from '../services/VisionService';
import { LLMClient } from '../services/LLMClient';
import { LocalSLMEngine } from '../services/LocalSLMEngine';
import { LocalOCREngine } from '../services/LocalOCREngine';
import { DatabaseUtil } from '../utils/DatabaseUtil';
import { AgentRequest, AgentResponse, SubTask, BackendTask, MedicineInfo, AgentPlanResponse, ActionType } from './types';

const TAG: string = 'Agent';

/**
 * 会话历史项接口定义
 */
interface SessionHistoryItem {
  role: string;
  text: string;
}

/**
 * Agent —— 端侧智能体主控（单例）。
 */
export class Agent {
  private static instance: Agent | null = null;
  private context: Context | null = null;
  private intentRouter: IntentRouter;
  private taskPlanner: TaskPlanner;
  private visionService: VisionService;
  private llmClient: LLMClient;
  private accessibility: AccessibilityUtils;

  /** 会话历史（多轮对话） */
  private sessionHistory: Map<string, Array<SessionHistoryItem>> = new Map();

  private constructor() {
    this.intentRouter = IntentRouter.getInstance();
    this.taskPlanner = TaskPlanner.getInstance();
    this.visionService = VisionService.getInstance();
    this.llmClient = LLMClient.getInstance();
    this.accessibility = AccessibilityUtils.getInstance();
  }

  /**
   * 获取 Agent 单例。
   */
  public static getInstance(): Agent {
    if (Agent.instance === null) {
      Agent.instance = new Agent();
    }
    return Agent.instance;
  }

  /**
   * 初始化 Agent（注入 UIAbilityContext）。
   * 同时把上下文注入 TaskPlanner，使拨号 / 短信 / 叫车等系统任务可用。
   */
  public async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.visionService.init(context);
    this.taskPlanner.init(context);
    
    // 初始化并注入离线大模型引擎 (SLM) 与 OCR 引擎
    try {
      await LocalSLMEngine.getInstance().init(context);
      await LocalOCREngine.getInstance().init(context);
      this.visionService.setLocalOcrEngine(LocalOCREngine.getInstance());
      await DatabaseUtil.getInstance().init(context);
      Logger.info(TAG, '本地 SLM 和 OCR 引擎初始化并注入完成');
    } catch (e) {
      Logger.warn(TAG, `本地引擎或数据库初始化失败: ${e}`);
    }

    Logger.info(TAG, 'Agent 初始化完成');
  }

  /**
   * Agent 对外统一入口。
   *
   * 流程：
   * 1. 意图识别（后端代理）；
   * 2. 任务执行（TaskPlanner 执行后端下发的 BackendTask 列表）；
   * 3. 汇总返回 AgentResponse。
   *
   * @param request 端侧请求
   * @param onPlanReady 规划生成后、任务执行前的回调（用于把任务卡片先上屏）
   * @returns Agent 响应
   */
  public async invoke(request: AgentRequest,
    onPlanReady?: (tasks: Array<BackendTask>) => void): Promise<AgentResponse> {
    const startTime: number = Date.now();
    Logger.info(TAG, `invoke: text=${request.text}`);

    try {
      // 1) 意图识别 + 任务规划（后端优先，失败则端侧 LLM 兜底）
      const sessionId = request.session_id ?? 'default';
      const historyItems = this.sessionHistory.get(sessionId) || [];
      const historyRecord: Array<Record<string, string>> = historyItems.map((item): Record<string, string> => {
        const rec: Record<string, string> = {
          'role': item.role,
          'text': item.text
        };
        return rec;
      });
      
      const plan: AgentPlanResponse = await this.intentRouter.route(request.text, sessionId, historyRecord);
      const backendTasks: BackendTask[] = plan.tasks ?? [];
      const ttsMessage: string = plan.tts_message.length > 0
        ? plan.tts_message
        : (backendTasks.length > 0 ? '指令已执行。' : '');

      // 2) 端侧执行任务
      //    先回调上屏任务卡片，再执行；preAnnounce 保证跳转类任务的长文案在应用仍在前台时播完
      if (backendTasks.length > 0) {
        if (onPlanReady) {
          onPlanReady(backendTasks);
        }
        await this.taskPlanner.execute(backendTasks, { preAnnounce: ttsMessage });
      }

      // 3) 维护会话历史
      this.appendHistory(request.session_id ?? 'default', 'user', request.text);
      this.appendHistory(request.session_id ?? 'default', 'assistant', ttsMessage);

      const subTasks: Array<SubTask> = backendTasks.map((t: BackendTask, idx: number): SubTask => {
        const item: SubTask = {
          id: `task_${idx}`,
          action: t.action as ActionType,
          params: {
            destination: t.target,
            text: t.content
          },
          description: (t.content && t.content.length > 0) ? t.content : t.target,
          critical: true
        };
        return item;
      });

      return {
        intent: 'backend_routed',
        tasks: subTasks,
        tts_message: ttsMessage,
        metadata: {
          duration_ms: Date.now() - startTime
        }
      };
    } catch (error) {
      const errMsg: string = error instanceof Error ? error.message : '未知错误';
      Logger.error(TAG, `invoke 失败: ${errMsg}`);
      const fallback: string = `操作失败：${errMsg}。请重试。`;
      this.accessibility.speak(fallback);
      return {
        intent: 'unknown',
        tasks: [],
        tts_message: fallback,
        metadata: { error: errMsg, duration_ms: Date.now() - startTime }
      };
    }
  }

  /**
   * 直接调用视觉识别（供 UI 层直接调用，绕过后端代理）。
   * P0-3 端侧视觉落地：端侧 MobileNetV2 优先 + 云端 Qwen-VL 兜底。
   *
   * @param imageBase64 图像 base64
   * @returns TTS 播报文本
   */
  public async classifyImage(imageBase64: string): Promise<string> {
    const result = await this.visionService.classifyImage(imageBase64);
    DatabaseUtil.getInstance().insertActionLog('vision_classify', result).catch((err: Error) => {
      Logger.error(TAG, `Failed to save action log: ${err.message}`);
    });
    return result;
  }

  /**
   * 追加会话历史
   */ 
  private appendHistory(sessionId: string, role: string, text: string): void {
    let history = this.sessionHistory.get(sessionId);
    if (!history) {
      history = [];
      this.sessionHistory.set(sessionId, history);
    }
    const historyItem: SessionHistoryItem = { role: role, text: text };
    history.push(historyItem);
    if (history.length > 20) {
      history.shift();
    }
    
    // Offline-first: save to SQLite
    DatabaseUtil.getInstance().insertChatLog(role, text).catch((err: Error) => {
      Logger.error(TAG, `Failed to save chat log: ${err.message}`);
    });
  }

  /**
   * 释放资源。
   */
  public destroy(): void {
    this.sessionHistory.clear();
    Logger.info(TAG, 'Agent 已销毁');
  }
}
