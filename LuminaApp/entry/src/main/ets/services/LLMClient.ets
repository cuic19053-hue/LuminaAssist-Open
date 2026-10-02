/**
 * @file LLMClient.ets
 * @module services
 * @description 端侧 LLM 客户端（阿里云百炼 OpenAI 兼容接口直连版）。
 *
 * 职责（spec: add-screen-tap-vision-assist）：
 * 1. 端侧直连阿里云百炼 DashScope compatible-mode（OpenAI 兼容协议）；
 * 2. 端侧持有 API Key（由 EntryAbility 启动时通过 updateConfig 注入）；
 * 3. chat() 返回模型 raw 文本（choices[0].message.content），由上层解析 JSON；
 * 4. 当 messages 含 image_base64 字段时自动切换 visionModel（qwen-vl-plus）；
 * 5. 所有失败抛出中文 Error，由上层 TTS 兜底（铁律 3）。
 *
 * 架构原则（零后端铁律）：
 * - 不依赖任何后端代理（无 HttpClient / FastAPI）；
 * - 端侧直连云端 LLM，是项目唯一网络出口；
 * - API Key 经 EntryAbility 注入（演示阶段硬编码 + TODO 标注，生产环境迁移 KeyStore）。
 *
 * 错误分类（VUI 铁律 3 兜底）：
 * - HTTP 401/403 → "API 鉴权失败，请检查 API Key"
 * - HTTP 429 → "请求过于频繁，请稍后再试"
 * - HTTP 5xx → "服务器暂时不可用，请稍后再试"
 * - 超时 → "识别超时，请重试"
 * - 其他网络异常 → "网络连接失败，请稍后再试"
 */

import http from '@ohos.net.http';
import { Logger } from '../utils/Logger';
import { LLMMessage } from '../agent/types';
import { LocalVLMEngine } from './LocalVLMEngine';
import { NetworkMonitor } from './NetworkMonitor';

const TAG: string = 'LLMClient';

/**
 * LLM 客户端配置。
 */
export interface LLMConfig {
  /** OpenAI 兼容接口基础地址 */
  baseUrl: string;
  /** 阿里云百炼 API Key（sk-xxx） */
  apiKey: string;
  /** 文本对话模型（默认与视觉模型一致，便于演示） */
  model: string;
  /** 视觉识别模型（qwen-vl-plus） */
  visionModel: string;
  /** 单次请求超时（毫秒） */
  timeoutMs: number;
  /** 最大输出 token 数 */
  maxTokens: number;
}

/**
 * OpenAI 兼容接口请求体类型定义
 */
interface TextContent {
  type: string;
  text: string;
}

interface ImageUrl {
  url: string;
}

interface ImageContent {
  type: string;
  image_url: ImageUrl;
}

interface TextRequestMessage {
  role: string;
  content: string;
}

interface VisionRequestMessage {
  role: string;
  content: Array<TextContent | ImageContent>;
}

interface ChatRequestBody {
  model: string;
  messages: Array<TextRequestMessage | VisionRequestMessage>;
  max_tokens: number;
  enable_search?: boolean;
}

/** DashScope OpenAI 兼容接口鉴权请求头 */
interface AuthHttpHeader {
  'Content-Type': string;
  'Authorization': string;
}

/**
 * 端侧推理引擎接口（端云双态架构 - 端侧直连路径）。
 *
 * 由具体端侧引擎实现（如 LocalImageClassifier / LocalOCREngine / LocalVisionLLMEngine），
 * 用于 LLMClient 在低延迟场景下优先调用端侧能力，端侧未就绪或失败时再回退云端。
 *
 * 实现方需保证：
 * 1. ready getter 反映引擎真实就绪状态（模型加载完成 / 标签解析完成）；
 * 2. kind getter 返回引擎类型标识（用于日志与调试）；
 * 3. infer() 接收 LLMMessage[]（与云端 chat() 入参一致），返回中文文本结果；
 * 4. 所有错误抛出中文 Error，由上层 TTS 兜底（VUI 铁律 3）。
 */
export interface LocalEngine {
  /** 引擎就绪状态（模型加载完成后返回 true） */
  readonly ready: boolean;
  /** 引擎类型标识（如 'image_classifier' / 'ocr_engine' / 'vision_llm'） */
  readonly kind: string;
  /**
   * 端侧推理：接收多模态消息，返回中文文本结果。
   * @param messages 多模态消息列表（含可选 image_base64）
   * @returns 推理结果文本（用于 TTS 播报）
   * @throws Error 中文 Error，由上层 TTS 兜底
   */
  infer(messages: LLMMessage[]): Promise<string>;
}

/**
 * LLMClient —— 端侧大模型客户端（单例，直连阿里云百炼）。
 *
 * 使用方式：
 * ```ts
 * LLMClient.getInstance().updateConfig({ apiKey: 'sk-xxx' });
 * const raw = await LLMClient.getInstance().chat([
 *   { role: 'system', content: '...' },
 *   { role: 'user', content: '请识别图中的物品。', image_base64: '<base64>' }
 * ]);
 * ```
 */
export class LLMClient {
  private static instance: LLMClient | null = null;
  private config: LLMConfig;
  /** 端侧文本 LLM 引擎（云端失败时降级，可选注入） */
  private localEngine: LocalEngine | null = null;
  /** 端侧视觉 VLM 引擎（云端 Qwen-VL 失败时降级，可选注入） */
  private localVlmEngine: LocalVLMEngine | null = null;

  private constructor() {
    this.config = {
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      apiKey: 'sk-your-aliyun-dashscope-api-key-here',
      model: 'qwen-plus',
      visionModel: 'qwen-vl-max',
      timeoutMs: 30000,
      maxTokens: 1024
    };
  }

  /**
   * 获取 LLMClient 单例。
   * @returns LLMClient 实例
   */
  public static getInstance(): LLMClient {
    if (LLMClient.instance === null) {
      LLMClient.instance = new LLMClient();
    }
    return LLMClient.instance;
  }

  /**
   * 更新配置（逐字段赋值，避免对象展开 ...）。
   *
   * ArkTS 严格模式禁止对象展开运算符，因此通过 Record 类型逐字段判断并赋值。
   * 仅传入需要更新的字段即可，未传入的字段保持原值。
   *
   * @param config 配置项字典（键值对，仅需传入要更新的字段）
   */
  public updateConfig(config: Record<string, Object>): void {
    if (config['baseUrl'] !== undefined) {
      this.config.baseUrl = config['baseUrl'] as string;
    }
    if (config['apiKey'] !== undefined) {
      this.config.apiKey = (config['apiKey'] as string).trim();
    }
    if (config['model'] !== undefined) {
      this.config.model = config['model'] as string;
    }
    if (config['visionModel'] !== undefined) {
      this.config.visionModel = config['visionModel'] as string;
    }
    if (config['timeoutMs'] !== undefined) {
      this.config.timeoutMs = config['timeoutMs'] as number;
    }
    if (config['maxTokens'] !== undefined) {
      this.config.maxTokens = config['maxTokens'] as number;
    }
    Logger.info(TAG, 'LLMClient 配置已更新');
  }

  /**
   * 注入端侧文本 LLM 引擎。注入后 chat() 云端失败时自动降级本地推理。
   * @param engine 端侧文本引擎实例或 null
   */
  public setLocalEngine(engine: LocalEngine | null): void {
    this.localEngine = engine;
    Logger.info(TAG, `端侧文本引擎已${engine ? '注入' : '移除'}，ready=${engine ? engine.ready : false}`);
  }

  /**
   * 注入端侧视觉 VLM 引擎。注入后 analyzeImage() 云端失败时自动降级本地 VLM。
   * @param engine 端侧视觉引擎实例或 null
   */
  public setLocalVlmEngine(engine: LocalVLMEngine | null): void {
    this.localVlmEngine = engine;
    Logger.info(TAG, `端侧视觉引擎已${engine ? '注入' : '移除'}，ready=${engine ? engine.ready : false}`);
  }

  /**
   * 查询当前 API Key 是否已注入。
   * @returns API Key 非空返回 true，否则 false
   */
  public isReady(): boolean {
    return this.config.apiKey.length > 0;
  }

  /**
   * 端侧文本引擎是否可用（无云端 Key 时也可兜底）。
   */
  public hasLocalEngine(): boolean {
    return this.localEngine !== null && this.localEngine.ready;
  }

  /**
   * 端侧视觉引擎是否可用。
   */
  public hasLocalVlm(): boolean {
    return this.localVlmEngine !== null && this.localVlmEngine.ready;
  }

  /**
   * 发起一次 Chat 调用（OpenAI 兼容接口 /chat/completions）。
   *
   * 行为：
   * - 当 messages 中任一条 user 消息含 image_base64 字段时，自动切换 visionModel；
   * - 返回 choices[0].message.content 字符串（raw text，由上层解析 JSON）；
   * - HTTP 401/403 → 抛 "API 鉴权失败，请检查 API Key"；
   * - HTTP 429 → 抛 "请求过于频繁，请稍后再试"；
   * - HTTP 5xx → 抛 "服务器暂时不可用，请稍后再试"；
   * - 超时 → 抛 "识别超时，请重试"；
   * - 其他网络异常 → 抛 "网络连接失败，请稍后再试"。
   *
   * @param messages 多模态消息列表
   * @returns 模型 raw 文本响应（content 字段）
   * @throws Error 中文 Error，由上层 TTS 兜底
   */
  public async chat(messages: LLMMessage[]): Promise<string> {
    return await this.chatInternal(messages, false);
  }

  /** 启用 DashScope 联网搜索，供药品资料核对和追问使用。 */
  public async chatWithSearch(messages: LLMMessage[]): Promise<string> {
    return await this.chatInternal(messages, true);
  }

  private async chatInternal(messages: LLMMessage[], enableSearch: boolean): Promise<string> {
    // 云端不可用（无 Key）时直接走本地文本引擎兜底
    if (!this.isReady()) {
      if (this.localEngine !== null && this.localEngine.ready) {
        Logger.info(TAG, '云端未配置 Key，直接走端侧文本引擎');
        return await this.localEngine.infer(messages);
      }
      throw new Error('未配置 API Key，请在设置页录入阿里云百炼 API Key。');
    }

    const hasImage: boolean = this.hasImage(messages);
    if (!hasImage) {
      const netOk: boolean = await NetworkMonitor.getInstance().isNetworkAvailable();
      if (!netOk && this.localEngine !== null && this.localEngine.ready) {
        Logger.info(TAG, '探测到当前处于离线模式，直接走端侧离线文本引擎');
        return await this.localEngine.infer(messages);
      }
    }
    const models: Array<string> = hasImage ? this.buildVisionModelChain() : this.buildTextModelChain();
    let lastError: Error = new Error('大模型调用失败');

    for (let i = 0; i < models.length; i++) {
      try {
        return await this.requestChatCompletion(models[i], messages, enableSearch);
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(JSON.stringify(error));
        if (this.isKeyInvalidError(lastError.message)) {
          // 仅当 API Key 本身不存在或格式错误时才终止云端重试
          Logger.warn(TAG, `API Key 鉴权无效，终止云端模型链: ${lastError.message}`);
          break;
        }
        if (i < models.length - 1) {
          Logger.warn(TAG, `模型 ${models[i]} 遇到异常(${lastError.message})，后台自动路由切换至备用模型: ${models[i + 1]}`);
        }
      }
    }

    // 云端全部失败 → 降级端侧文本引擎
    if (this.localEngine !== null && this.localEngine.ready) {
      Logger.warn(TAG, `云端文本调用失败，降级端侧文本引擎: ${lastError.message}`);
      try {
        return await this.localEngine.infer(messages);
      } catch (localErr) {
        const localMsg: string = localErr instanceof Error ? localErr.message : JSON.stringify(localErr);
        Logger.error(TAG, `端侧文本引擎也失败: ${localMsg}`);
      }
    }
    throw new Error(lastError.message);
  }

  private buildVisionModelChain(): Array<string> {
    const chain: Array<string> = [];
    // 优先最高精度视觉旗舰 qwen-vl-max，额度用完或受限自动降级至 qwen-vl-plus
    const candidates: Array<string> = [this.config.visionModel, 'qwen-vl-max', 'qwen-vl-plus'];
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length > 0 && chain.indexOf(candidates[i]) < 0) {
        chain.push(candidates[i]);
      }
    }
    return chain;
  }

  private buildTextModelChain(): Array<string> {
    const chain: Array<string> = [];
    // 优先高智力文本模型 qwen-plus，额度用完或受限自动降级至 qwen-turbo
    const candidates: Array<string> = [this.config.model, 'qwen-plus', 'qwen-turbo'];
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length > 0 && chain.indexOf(candidates[i]) < 0) {
        chain.push(candidates[i]);
      }
    }
    return chain;
  }

  private isKeyInvalidError(message: string): boolean {
    const lower: string = message.toLowerCase();
    return lower.indexOf('invalid api key') >= 0 ||
      lower.indexOf('invalid_api_key') >= 0 ||
      lower.indexOf('key does not exist') >= 0 ||
      lower.indexOf('apikey is not found') >= 0;
  }

  private async requestChatCompletion(
    model: string,
    messages: LLMMessage[],
    enableSearch: boolean
  ): Promise<string> {
    const payload: Object = this.buildPayload(model, messages, enableSearch);
    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const url: string = this.config.baseUrl + '/chat/completions';
      const headers: AuthHttpHeader = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`
      };
      const response = await httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: Math.min(this.config.timeoutMs, 5000),
        readTimeout: this.config.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });

      const code: number = response.responseCode;
      const raw: string = response.result as string;
      if (code === 401 || code === 403) {
        const detail: string = this.extractDashScopeError(raw);
        const lowerDetail: string = detail.toLowerCase();
        if (lowerDetail.indexOf('quota') >= 0 || lowerDetail.indexOf('allocation') >= 0 ||
            lowerDetail.indexOf('arrears') >= 0 || detail.indexOf('额度') >= 0 || detail.indexOf('配额') >= 0) {
          throw new Error(`模型 ${model} 额度已耗尽(${detail})`);
        }
        throw new Error(detail.length > 0 ? detail : 'API 鉴权失败，请检查 API Key 是否有效');
      }
      if (code === 429) {
        throw new Error('请求过于频繁，请稍后再试');
      }
      if (code >= 500) {
        throw new Error('服务器暂时不可用，请稍后再试');
      }
      if (code < 200 || code >= 300) {
        const detail: string = this.extractDashScopeError(raw);
        throw new Error(detail.length > 0 ? detail : `大模型调用失败，HTTP ${code}`);
      }

      let parsed: Record<string, Object> = {};
      try {
        parsed = JSON.parse(raw) as Record<string, Object>;
      } catch (jsonErr) {
        Logger.error(TAG, `LLM 响应 JSON 解析失败: ${jsonErr instanceof Error ? jsonErr.message : 'SyntaxError'}, raw=${raw}`);
        throw new Error('大模型响应格式异常，请稍后再试');
      }
      const choicesVal: Object | undefined = parsed['choices'];
      const choices = (choicesVal === undefined ? [] : choicesVal) as Array<Object>;
      if (choices.length === 0) {
        throw new Error('大模型未返回有效内容');
      }
      const firstChoice = choices[0] as Record<string, Object>;
      const messageObj = firstChoice['message'] as Record<string, Object>;
      const content: string = (messageObj['content'] as string) ?? '';
      Logger.info(TAG, `chat 成功 model=${model} len=${content.length} search=${enableSearch}`);
      return content;
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : '未知错误';
      Logger.error(TAG, `LLM chat 调用失败 model=${model}: ${msg}`);
      if (msg.includes('timeout') || msg.includes('超时')) {
        throw new Error('识别超时，请重试');
      }
      if (error instanceof Error && msg.length > 0 && !msg.includes('BusinessError')) {
        throw new Error(msg);
      }
      throw new Error('网络连接失败，请稍后再试');
    } finally {
      httpClient.destroy();
    }
  }

  private extractDashScopeError(raw: string): string {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const errObj: Object | undefined = parsed['error'];
      if (errObj !== undefined) {
        const err = errObj as Record<string, Object>;
        const message: string = (err['message'] as string) ?? '';
        if (message.length > 0) {
          return message;
        }
      }
      const message: string = (parsed['message'] as string) ?? '';
      const code: string = (parsed['code'] as string) ?? '';
      if (message.length > 0) {
        return code.length > 0 ? `${message} (${code})` : message;
      }
    } catch (e) {
      // ignore
    }
    return '';
  }

  /**
   * 图像分析（兼容包装方法）。
   *
   * 内部调用 chat() 传递 image_base64，返回模型 raw 文本。
   * 保留此方法是为了兼容 TaskPlanner.ets 等旧代码的调用（向后兼容）。
   *
   * @param imageBase64 图像 base64 字符串（不含 data:image/jpeg;base64, 前缀）
   * @returns 模型识别文本
   * @throws Error 中文 Error，由上层 TTS 兜底
   */
  public async analyzeImage(imageBase64: string): Promise<string> {
    if (imageBase64.length === 0) {
      throw new Error('图像数据为空，无法识别。');
    }
    try {
      return await this.chat([
        { role: 'user', content: '请识别图中的物品并用中文口语化描述。', image_base64: imageBase64 }
      ]);
    } catch (cloudErr) {
      // chat() 内部已尝试云端模型链 + 端侧文本引擎兜底；
      // 视觉场景下若仍失败，再尝试端侧视觉 VLM 引擎做图文问答
      if (this.localVlmEngine !== null && this.localVlmEngine.ready) {
        Logger.warn(TAG, `云端视觉识别失败，降级端侧 VLM: ${
          cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr)}`);
        return await this.localVlmEngine.analyzeImage(imageBase64, '请识别图中的物品并用中文口语化描述。');
      }
      throw new Error(cloudErr instanceof Error ? cloudErr.message : JSON.stringify(cloudErr));
    }
  }

  /**
   * 释放资源。
   */
  public destroy(): void {
    Logger.info(TAG, 'LLMClient 已销毁');
  }

  /**
   * 判断 messages 中是否含 image_base64 字段（用于自动切换视觉模型）。
   * @param messages 多模态消息列表
   * @returns 含图像返回 true，否则 false
   */
  private hasImage(messages: LLMMessage[]): boolean {
    for (let i = 0; i < messages.length; i++) {
      const m: LLMMessage = messages[i];
      if (m.image_base64 !== undefined && m.image_base64.length > 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 构建 OpenAI 兼容接口请求体。
   *
   * - 文本消息：content 为字符串；
   * - 视觉消息（含 image_base64）：content 为数组，含 text 与 image_url 对象，
   *   image_url.url 使用 `data:image/jpeg;base64,<base64>` 形式。
   *
   * @param model 模型名（visionModel 或 model）
   * @param messages 多模态消息列表
   * @returns OpenAI 兼容接口请求体对象
   */
  private buildPayload(model: string, messages: LLMMessage[], enableSearch: boolean): Object {
    const reqMessages: Array<TextRequestMessage | VisionRequestMessage> = [];
    for (let i = 0; i < messages.length; i++) {
      const m: LLMMessage = messages[i];
      if (m.image_base64 !== undefined && m.image_base64.length > 0) {
        // 视觉消息：content 为数组（OpenAI 兼容协议要求）
        const textContent: TextContent = { type: 'text', text: m.content };
        const imageUrl: ImageUrl = { url: `data:image/jpeg;base64,${m.image_base64}` };
        const imageContent: ImageContent = {
          type: 'image_url',
          image_url: imageUrl
        };
        const contentArr: Array<TextContent | ImageContent> = [textContent, imageContent];
        const visionMsg: VisionRequestMessage = { role: m.role, content: contentArr };
        reqMessages.push(visionMsg);
      } else {
        // 纯文本消息：content 为字符串
        const textMsg: TextRequestMessage = { role: m.role, content: m.content };
        reqMessages.push(textMsg);
      }
    }
    const requestBody: ChatRequestBody = {
      model: model,
      messages: reqMessages,
      max_tokens: this.config.maxTokens
    };
    if (enableSearch) {
      requestBody.enable_search = true;
    }
    return requestBody as Object;
  }
}
