/**
 * @file IntentRouter.ets
 * @module agent
 * @description 端侧意图路由器（端云双态-后端代理路径 + 端侧 LLM 兜底）。
 *
 * 职责：
 * 1. 优先调用后端 /api/v1/agent/plan；
 * 2. 后端不可达时回退端侧 LLMClient 本地任务规划（产出结构化 tasks），保证脱离后端也能完成编排；
 * 3. 本地规划无有效任务时退化为端侧对话回复；
 * 4. 全链路失败时由离线规则规划（OfflinePlanner）兜底，保证任何环境都有语音反馈。
 */

import { Logger } from '../utils/Logger';
import { HttpClient } from '../services/HttpClient';
import { LLMClient } from '../services/LLMClient';
import { SpeechService } from '../services/SpeechService';
import { AgentPlanResponse, BackendTask, LLMMessage, PlanRequestBody } from './types';
import { planOffline } from './OfflinePlanner';

const TAG: string = 'IntentRouter';

/** 端侧规划系统提示词（与后端 /agent/plan 的规划语义对齐，纯前端直连百炼大模型） */
const LOCAL_PLAN_SYSTEM_PROMPT: string =
  '你是光语助手的任务规划器。根据用户指令输出严格 JSON（不要包裹在 ```json 中）：\n' +
  '{"tasks":[{"action":"...","target":"...","content":"..."}],"tts_message":"..."}\n' +
  'action 可选：capture_image / image_classify / medicine_recognition / send_sms / call_ride / vision_analyze / emergency_call / read_screen / read_text\n' +
  '- 出现"打电话/呼叫/拨打"（如"给妈妈打电话"）-> 必须使用 action: "emergency_call", target: "妈妈"（target只写姓名或号码）\n' +
  '- 发短信/发消息（如"给妈妈发短信说我到了"）-> action: "send_sms", target: "妈妈", content: "我到了"\n' +
  '- 识别药品/这药怎么吃/说明书 -> action: "medicine_recognition", target: "camera"\n' +
  '- 这是什么/识别一下/帮我看看 -> tasks: [{"action":"capture_image","target":"camera","content":""},{"action":"image_classify","target":"camera","content":""}]\n' +
  '- 读文字/读文档/朗读文字/念一下上面的字 -> tasks: [{"action":"capture_image","target":"camera","content":""},{"action":"read_text","target":"camera","content":""}]\n' +
  '- 读书/阅读/复杂视觉描述 -> action: "vision_analyze", target: "camera"\n' +
  '- 打车去X -> action: "call_ride", target: "X"\n' +
  '- 读屏幕/朗读屏幕 -> action: "read_screen", target: "screen"\n' +
  '- 普通闲聊或无明确设备任务 -> tasks 返回空数组 []，由 tts_message 进行简短口语化中文回复（不超过 25 字）。';

export type FallbackChoice = 'OFFLINE' | 'RETRY_CLOUD';
export type FallbackPromptHandler = (reason: string) => Promise<FallbackChoice>;

/**
 * IntentRouter —— 端侧意图路由器（单例）。
 */
export class IntentRouter {
  private static instance: IntentRouter | null = null;
  private httpClient: HttpClient;
  private speechService: SpeechService;
  private llmClient: LLMClient;
  private promptHandler: FallbackPromptHandler | null = null;

  private constructor() {
    this.httpClient = HttpClient.getInstance();
    this.speechService = SpeechService.getInstance();
    this.llmClient = LLMClient.getInstance();
  }

  public static getInstance(): IntentRouter {
    if (IntentRouter.instance === null) {
      IntentRouter.instance = new IntentRouter();
    }
    return IntentRouter.instance;
  }

  /**
   * 注册网络劣化/云端不可达时的用户抉择提示处理器。
   */
  public setFallbackPromptHandler(handler: FallbackPromptHandler | null): void {
    this.promptHandler = handler;
  }

  /**
   * 意图路由入口：云端优先 → 网络较差/异常时提示用户抉择 → 端侧 LLM / 离线规则。
   * @param text 用户指令原文
   * @returns 规划结果（tasks + tts_message）
   */
  public async route(text: string, sessionId?: string, history?: Array<Record<string, string>>): Promise<AgentPlanResponse> {
    // 优先：前端持有 API Key 直连阿里云百炼大模型（零依赖本地服务器与内网穿透隧道，秒级响应）
    if (this.llmClient.isReady()) {
      try {
        Logger.info(TAG, '前端直连阿里云百炼大模型进行意图规划');
        return await this.routeViaLocalLlm(text, '');
      } catch (directErr) {
        const directMsg: string = directErr instanceof Error ? directErr.message : '未知错误';
        Logger.warn(TAG, `前端直连大模型规划失败: ${directMsg}，准备尝试后端代理或离线兜底`);
      }
    }

    try {
      return await this.routeViaBackend(text, sessionId, history);
    } catch (backendErr) {
      const backendMsg: string = backendErr instanceof Error ? backendErr.message : '未知错误';
      Logger.warn(TAG, `后端云端不可达: ${backendMsg}`);

      // 若注册了用户抉择回调，提示用户选择是否使用离线模型或重试
      let choice: FallbackChoice = 'OFFLINE';
      if (this.promptHandler !== null) {
        try {
          choice = await this.promptHandler(backendMsg);
        } catch (promptErr) {
          Logger.warn(TAG, `用户抉择处理失败，默认采用端侧模型: ${promptErr instanceof Error ? promptErr.message : '未知'}`);
        }
      }

      if (choice === 'RETRY_CLOUD') {
        Logger.info(TAG, '用户选择重试云端服务');
        return await this.routeViaBackend(text, sessionId, history);
      }

      Logger.info(TAG, '切换为端侧离线模型继续处理');
      try {
        return await this.routeViaLocalLlm(text, backendMsg);
      } catch (localErr) {
        const localMsg: string = localErr instanceof Error ? localErr.message : '未知错误';
        Logger.warn(TAG, `端侧 LLM 规划失败，回退离线规则: ${localMsg}`);
        return await this.routeViaOfflineRules(text);
      }
    }
  }

  /**
   * 后端代理路径：POST /api/v1/agent/plan。
   */
  private async routeViaBackend(text: string, sessionId?: string, history?: Array<Record<string, string>>): Promise<AgentPlanResponse> {
    const requestBody: PlanRequestBody = { 
      text: text,
      session_id: sessionId,
      history: history
    };
    
    return new Promise<AgentPlanResponse>((resolve, reject) => {
      let tasks: Array<BackendTask> = [];
      this.httpClient.postStream(
        '/api/v1/agent/plan',
        requestBody,
        (event: string, data: string) => {
           if (event === 'tts_chunk') {
             this.speechService.speak(data).catch((e: Error) => Logger.error(TAG, 'TTS chunk error: ' + e.message));
           } else if (event === 'tasks') {
             try {
                const rawTasks = JSON.parse(data) as Array<Record<string, string>>;
                tasks = rawTasks.map((t): BackendTask => {
                  const item: BackendTask = {
                    action: t['action'] ?? '',
                    target: t['target'] ?? '',
                    content: t['content'] ?? ''
                  };
                  return item;
                });
             } catch(e) {
               Logger.error(TAG, 'Failed to parse tasks JSON from stream');
             }
           }
        },
        () => {
           resolve({ tasks: tasks, tts_message: '' }); // tts_message is streamed so we don't return it
        },
        (err: Error) => {
           reject(err);
        }
      );
    });
  }

  /**
   * 端侧本地任务规划兜底（后端不可达时仍可完成完整编排）。
   *
   * 流程：
   * 1. 端侧直连大模型，用与后端一致的规划提示词产出结构化 tasks + tts_message；
   * 2. 解析成功且有任务 → 返回 tasks 交给 TaskPlanner 执行（打电话/发短信/打车/识别等）；
   * 3. 解析失败或无任务 → 退化为端侧对话回复，保证有语音反馈。
   */
  private async routeViaLocalLlm(text: string, backendError: string): Promise<AgentPlanResponse> {
    // 云端 Key 或端侧文本引擎任一可用即可尝试规划
    if (!this.llmClient.isReady() && !this.llmClient.hasLocalEngine()) {
      throw new Error('后端不可达且无可用大模型（云端 Key / 端侧 LLM）');
    }

    const planMessages: Array<LLMMessage> = [
      { role: 'system', content: LOCAL_PLAN_SYSTEM_PROMPT },
      { role: 'user', content: text }
    ];

    let tasks: Array<BackendTask> = [];
    let ttsMessage: string = '';
    try {
      const raw: string = await this.llmClient.chat(planMessages);
      const parsed: AgentPlanResponse = this.parsePlanJson(raw);
      tasks = parsed.tasks;
      ttsMessage = parsed.tts_message;
      Logger.info(TAG, `端侧本地规划成功 tasks=${tasks.length} backendErr=${backendError}`);
    } catch (planErr) {
      const planMsg: string = planErr instanceof Error ? planErr.message : '未知错误';
      Logger.warn(TAG, `端侧本地规划失败，退化为对话回复: ${planMsg}`);
      // 抛出让上层走离线规则（比空对话更有用）
      throw new Error(planMsg);
    }

    if (ttsMessage.length === 0) {
      ttsMessage = '好的，正在为您处理。';
    }

    // 语音播报与规划返回解耦，不阻断任务立即下发执行
    this.speechService.speak(ttsMessage).catch((ttsErr: Error) => {
      Logger.error(TAG, `本地规划 TTS 失败: ${ttsErr instanceof Error ? ttsErr.message : '未知'}`);
    });

    const plan: AgentPlanResponse = { tasks: tasks, tts_message: ttsMessage };
    return plan;
  }

  /**
   * 最终离线兜底：纯关键词规则，不依赖网络与大模型权重。
   */
  private async routeViaOfflineRules(text: string): Promise<AgentPlanResponse> {
    const plan: AgentPlanResponse = planOffline(text);
    Logger.info(TAG, `离线规则规划 tasks=${plan.tasks.length} tts=${plan.tts_message}`);
    if (plan.tts_message.length > 0) {
      this.speechService.speak(plan.tts_message).catch((ttsErr: Error) => {
        Logger.error(TAG, `离线规划 TTS 失败: ${ttsErr instanceof Error ? ttsErr.message : '未知'}`);
      });
    }
    return plan;
  }

  /**
   * 解析端侧规划 JSON（兼容 ```json 代码块包裹）。
   * @param raw 大模型原始文本
   * @returns 规划结果（tasks + tts_message）
   */
  private parsePlanJson(raw: string): AgentPlanResponse {
    let cleaned: string = raw.replace(/```json|```/g, '').trim();
    const firstBrace: number = cleaned.indexOf('{');
    const lastBrace: number = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    try {
      const parsed = JSON.parse(cleaned) as Record<string, Object>;
      const tasks: Array<BackendTask> = [];
      const tasksRaw: Object | undefined = parsed['tasks'];
      if (tasksRaw instanceof Array) {
        const taskList: Array<Object> = tasksRaw as Array<Object>;
        for (let i = 0; i < taskList.length; i++) {
          const item = taskList[i] as Record<string, Object>;
          const action: string = (item['action'] as string) ?? '';
          if (action.length === 0) {
            continue;
          }
          const task: BackendTask = {
            action: action,
            target: (item['target'] as string) ?? '',
            content: (item['content'] as string) ?? ''
          };
          tasks.push(task);
        }
      }
      const ttsMsg: string = (parsed['tts_message'] as string) ?? '好的';
      return { tasks: tasks, tts_message: ttsMsg };
    } catch (parseErr) {
      Logger.warn(TAG, `解析 Agent 规划 JSON 失败: ${parseErr instanceof Error ? parseErr.message : 'SyntaxError'}，原文字: ${raw}`);
      return { tasks: [], tts_message: '我没听明白，请再说一遍' };
    }
  }

  public destroy(): void {
    Logger.info(TAG, 'IntentRouter 已销毁');
  }
}
