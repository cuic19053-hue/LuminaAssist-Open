/**
 * @file SpeechService.ets
 * @module services
 * @description 端侧语音服务（阿里云 DashScope 云端 TTS + 系统本地 TTS 兜底 + AVPlayer + CoreSpeechKit ASR）。
 *
 * 职责：
 * 1. 优先调用阿里云 DashScope TTS API 合成音频并播放；
 * 2. 云端失败（额度不足/鉴权/网络）或无 Key 时，降级鸿蒙系统 TextToSpeech；
 * 3. ASR：优先 SystemCapability.AI.SpeechRecognizer（CoreSpeechKit），真机按住说话。
 *
 * 架构原则（端云双态铁律 1）：
 * - API Key 通过 updateConfig 注入，生产环境由 KeyStoreUtil 解密后注入；
 * - 禁止硬编码 Key、禁止日志打印 Key 值；
 * - TTS 失败时由 AccessibilityUtils 振动兜底（铁律 3）。
 *
 * TTS 调用流程：
 * 1. 优先 POST Qwen3-TTS，失败回退 CosyVoice；
 * 2. 云端失败 → 系统 textToSpeech 本地朗读；
 * 3. 播报串行排队，避免多段 speak 互相打断。
 */

import http from '@ohos.net.http';
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { Logger } from '../utils/Logger';

const TAG: string = 'SpeechService';
const ASR_SESSION_ID: string = 'lumina_asr_session';
const SYSTEM_TTS_WAIT_MS: number = 2000;

/**
 * TTS 配置。
 */
interface TTSConfig {
  /** DashScope API 基础地址 */
  baseUrl: string;
  /** 阿里云百炼 API Key（sk-xxx） */
  apiKey: string;
  /** TTS 模型（Qwen3-TTS，与百炼 LLM 共用 API Key） */
  model: string;
  /** 音色（Cherry 中文女声） */
  voice: string;
  /** 音频格式（mp3 / wav，由接口返回决定） */
  format: string;
  /** 请求超时（毫秒） */
  timeoutMs: number;
}

/**
 * DashScope TTS 请求体 input 对象。
 */
interface TTSInput {
  text: string;
  voice: string;
  format: string;
}

/**
 * DashScope TTS 请求体。
 */
interface TTSRequestBody {
  model: string;
  input: TTSInput;
}

/** Qwen3-TTS 请求体 input */
interface QwenTtsInput {
  text: string;
  voice: string;
  language_type: string;
}

/** Qwen3-TTS 请求体 */
interface QwenTtsRequestBody {
  model: string;
  input: QwenTtsInput;
}

/** Qwen-Audio ASR 消息内容音频项 */
interface QwenAudioAudioItem {
  audio: string;
}

/** Qwen-Audio ASR 消息内容文本项 */
interface QwenAudioTextItem {
  text: string;
}

/** Qwen-Audio ASR 消息体 */
interface QwenAudioMessage {
  role: string;
  content: Array<QwenAudioAudioItem | QwenAudioTextItem>;
}

/** Qwen-Audio ASR input 对象 */
interface QwenAudioInput {
  messages: Array<QwenAudioMessage>;
}

/** Qwen-Audio ASR 请求体 */
interface QwenAudioRequestBody {
  model: string;
  input: QwenAudioInput;
}

/** DashScope TTS 鉴权请求头 */
interface AuthHttpHeader {
  'Content-Type': string;
  'Authorization': string;
}

/**
 * 语音识别结果回调。
 */
export interface ASRResult {
  /** 是否识别完成（最终结果） */
  isFinal: boolean;
  /** 当前识别文本 */
  text: string;
}

/**
 * SpeechService —— 语音服务（单例，云端 TTS + ASR 骨架）。
 *
 * TTS 链路：DashScope TTS API → MP3 下载 → AVPlayer 播放 → 清理临时文件。
 * ASR 链路：OpenHarmony SDK 不含 speechRecognizer，骨架降级。
 *
 * 使用方式：
 * ```ts
 * SpeechService.getInstance().init(context);
 * SpeechService.getInstance().updateConfig({ apiKey: 'sk-xxx' });
 * await SpeechService.getInstance().speak('你好');
 * ```
 */
export class SpeechService {
  private static instance: SpeechService | null = null;
  private config: TTSConfig;
  private context: Context | null = null;
  private ttsReady: boolean = false;
  private asrReady: boolean = false;
  /** 当前播放器（用于并发控制：新 speak 调用时先停旧的） */
  private currentPlayer: media.AVPlayer | null = null;
  /** 当前临时音频文件路径（播放完成或中断时清理） */
  private currentFilePath: string = '';
  /** 系统本地 TTS（云端额度耗尽 / 无 Key / 网络失败时的兜底） */
  private systemTts: textToSpeech.TextToSpeechEngine | null = null;
  private systemTtsReady: boolean = false;
  /** 串行播报队列，避免启动期多段 speak 互相打断导致无声 */
  private speakChain: Promise<void> = Promise.resolve();
  /** 鸿蒙 CoreSpeechKit 语音识别引擎 */
  private asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private currentPlayResolve: (() => void) | null = null;
  private asrFinalText: string = '';
  private asrOnResult: ((text: string, isFinal: boolean) => void) | null = null;
  private asrOnError: ((msg: string) => void) | null = null;
  private asrOnComplete: ((finalText: string) => void) | null = null;
  private asrCompleted: boolean = false;
  /** 阿里云 DashScope 云端 ASR 录音与转写 */
  private avRecorder: media.AVRecorder | null = null;
  private asrRecordFilePath: string = '';
  private asrRecordFileFd: number = -1;
  private asrRecordStartTime: number = 0;
  private asrRecording: boolean = false;
  private asrBase64Helper: util.Base64Helper = new util.Base64Helper();

  private constructor() {
    this.config = {
      baseUrl: 'https://dashscope.aliyuncs.com',
      apiKey: 'sk-your-aliyun-dashscope-api-key-here',
      model: 'qwen3-tts-flash',
      voice: 'Cherry',
      format: 'wav',
      timeoutMs: 20000
    };
  }

  /**
   * 获取 SpeechService 单例。
   */
  public static getInstance(): SpeechService {
    if (SpeechService.instance === null) {
      SpeechService.instance = new SpeechService();
    }
    return SpeechService.instance;
  }

  /**
   * 初始化（注入 Context，供 cacheDir 使用）。
   * 同时预热系统本地 TTS，保证云端失败时仍可出声。
   */
  public init(context: Context): void {
    this.context = context;
    this.prepareSystemTts(0);
    Logger.info(TAG, 'SpeechService 初始化完成（云端优先 + 系统 TTS 兜底）');
  }

  /**
   * 更新配置（注入 API Key 等）。
   * 端云双态架构：API Key 由外部注入，不硬编码。
   *
   * @param config 配置项字典（支持 apiKey / model / voice 字段）
   */
  public updateConfig(config: Record<string, Object>): void {
    if (config['apiKey'] !== undefined) {
      this.config.apiKey = (config['apiKey'] as string).trim();
    }
    if (config['model'] !== undefined) {
      this.config.model = config['model'] as string;
    }
    if (config['voice'] !== undefined) {
      this.config.voice = config['voice'] as string;
    }
    if (this.config.apiKey.length > 0) {
      this.ttsReady = true;
      Logger.info(TAG, 'SpeechService API Key 已注入，云端 TTS 就绪');
    } else {
      this.ttsReady = false;
      Logger.warn(TAG, 'SpeechService API Key 已清空，TTS 未就绪');
    }
  }

  /**
   * 检查 TTS 是否就绪（云端 Key 或系统本地引擎任一可用即可）。
   */
  public isReady(): boolean {
    const cloudReady: boolean = this.ttsReady && this.config.apiKey.length > 0;
    return cloudReady || this.systemTtsReady;
  }

  /**
   * 初始化 TTS 通道（向后兼容，云端模式下为空操作）。
   * 实际 TTS 就绪由 updateConfig 注入 API Key 后触发。
   */
  public initTTS(): void {
    Logger.info(TAG, 'TTS 通道已初始化（云端 DashScope 模式，API Key 注入后可用）');
  }

  /**
   * 播报文本（串行队列）。
   * 优先云端 DashScope TTS；失败或无 Key 时自动降级系统本地朗读。
   *
   * @param message 中文文本
   */
  public async speak(message: string): Promise<void> {
    if (!message || message.length === 0) {
      return;
    }
    const run: Promise<void> = this.speakChain.then(async (): Promise<void> => {
      try {
        await Promise.race([
          this.speakInternal(message),
          new Promise<void>((r: () => void) => setTimeout(r, 12000))
        ]);
      } catch (err) {
        const msg: string = err instanceof Error ? err.message : JSON.stringify(err);
        Logger.warn(TAG, `speakInternal 异常（不阻断后续）: ${msg}`);
      }
    });
    this.speakChain = run.catch((err: Error | Object): void => {
      const msg: string = err instanceof Error ? err.message : JSON.stringify(err);
      Logger.warn(TAG, `播报队列项失败（不阻断后续）: ${msg}`);
    });
    return run;
  }

  /**
   * 实际播报：云端优先 → 系统 TTS 兜底。
   */
  private async speakInternal(message: string): Promise<void> {
    await this.stopPlayback();
    this.stopSystemTts();

    if (this.config.apiKey.length > 0) {
      try {
        const audioUrl: string = await this.requestTTS(message);
        Logger.info(TAG, '云端 TTS 合成成功，开始下载音频');
        const filePath: string = await this.downloadAudio(audioUrl);
        Logger.info(TAG, `音频下载完成: ${filePath}`);
        await this.playAudioFile(filePath);
        return;
      } catch (cloudError) {
        const cloudMsg: string = cloudError instanceof Error ? cloudError.message : JSON.stringify(cloudError);
        Logger.warn(TAG, `云端 TTS 失败，改用系统朗读: ${cloudMsg}`);
      }
    } else {
      Logger.info(TAG, '未配置云端 API Key，直接使用系统朗读');
    }

    await this.ensureSystemTtsReady();
    if (this.systemTtsReady && this.systemTts !== null) {
      await this.speakWithSystemTts(message);
      return;
    }

    throw new Error('语音播报不可用：云端合成失败且系统朗读未就绪');
  }

  /**
   * 预热系统本地 TTS（优先离线，失败再试在线）。
   */
  private prepareSystemTts(online: number): void {
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      Logger.warn(TAG, '当前设备不支持 SystemCapability.AI.TextToSpeech');
      return;
    }
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: 0,
      online: online
    };
    textToSpeech.createEngine(params, (err: BusinessError, engine: textToSpeech.TextToSpeechEngine) => {
      if (!err && engine) {
        this.systemTts = engine;
        this.systemTtsReady = true;
        Logger.info(TAG, `系统 TTS 就绪（online=${online}）`);
        return;
      }
      const errMsg: string = err ? `${err.code}:${err.message}` : 'engine 为空';
      if (online === 0) {
        Logger.warn(TAG, `离线系统 TTS 创建失败，尝试在线: ${errMsg}`);
        this.prepareSystemTts(1);
        return;
      }
      Logger.error(TAG, `系统 TTS 创建失败: ${errMsg}`);
    });
  }

  private async ensureSystemTtsReady(): Promise<void> {
    if (this.systemTtsReady) {
      return;
    }
    const start: number = Date.now();
    while (!this.systemTtsReady && (Date.now() - start) < SYSTEM_TTS_WAIT_MS) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 100);
      });
    }
  }

  private speakWithSystemTts(message: string): Promise<void> {
    const engine: textToSpeech.TextToSpeechEngine | null = this.systemTts;
    if (engine === null) {
      return Promise.reject(new Error('系统 TTS 引擎为空'));
    }
    const text: string = message.length > 9000 ? message.substring(0, 9000) : message;
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let settled: boolean = false;
      const finish = (ok: boolean, errMsg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (ok) {
          resolve();
        } else {
          reject(new Error(errMsg));
        }
      };
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          Logger.info(TAG, `系统 TTS 开始播报 requestId=${requestId}`);
        },
        onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse): void => {
          Logger.info(TAG, '系统 TTS 播报完成');
          finish(true, '');
        },
        onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
          Logger.info(TAG, '系统 TTS 播报停止');
          finish(true, '');
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse): void => {
          // 系统自动播放，无需处理 PCM 数据
        },
        onError: (_requestId: string, errorCode: number, errorMessage: string): void => {
          Logger.error(TAG, `系统 TTS 错误 ${errorCode}: ${errorMessage}`);
          finish(false, `系统朗读失败: ${errorMessage}`);
        }
      };
      try {
        engine.setListener(listener);
        const speakParams: textToSpeech.SpeakParams = {
          requestId: `lumina_${Date.now()}`
        };
        engine.speak(text, speakParams);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
        finish(false, `系统朗读启动失败: ${msg}`);
      }
    });
  }

  private stopSystemTts(): void {
    if (this.systemTts === null) {
      return;
    }
    try {
      this.systemTts.stop();
    } catch (e) {
      // 忽略 stop 错误
    }
  }

  /**
   * 调用 DashScope TTS：优先 Qwen3-TTS（与 LLM 同 Key），失败回退 CosyVoice。
   */
  private async requestTTS(text: string): Promise<string> {
    try {
      return await this.requestQwenTTS(text);
    } catch (qwenError) {
      const qwenMsg: string = qwenError instanceof Error ? qwenError.message : JSON.stringify(qwenError);
      Logger.warn(TAG, `Qwen3-TTS 失败，回退 CosyVoice: ${qwenMsg}`);
      return await this.requestCosyVoiceTTS(text);
    }
  }

  /** Qwen3-TTS（multimodal-generation，与 LLM 共用百炼 API Key） */
  private async requestQwenTTS(text: string): Promise<string> {
    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const url: string = `${this.config.baseUrl}/api/v1/services/aigc/multimodal-generation/generation`;
      const inputObj: QwenTtsInput = {
        text: text,
        voice: this.config.voice,
        language_type: 'Chinese'
      };
      const bodyObj: QwenTtsRequestBody = {
        model: this.config.model,
        input: inputObj
      };
      const headers: AuthHttpHeader = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`
      };
      const response = await httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(bodyObj),
        connectTimeout: this.config.timeoutMs,
        readTimeout: this.config.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      }).catch((err: BusinessError) => {
        Logger.error(TAG, `Qwen3-TTS 请求异常: ${err.code}:${err.message}`);
        throw new Error(`${err.code}:${err.message}`);
      });
      return this.parseTtsAudioUrl(response.responseCode, response.result as string, 'Qwen3-TTS');
    } finally {
      httpClient.destroy();
    }
  }

  /** CosyVoice 兜底（旧接口） */
  private async requestCosyVoiceTTS(text: string): Promise<string> {
    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const url: string = `${this.config.baseUrl}/api/v1/services/audio/tts/SpeechSynthesizer`;
      const inputObj: TTSInput = {
        text: text,
        voice: 'longanyang',
        format: 'mp3'
      };
      const bodyObj: TTSRequestBody = {
        model: 'cosyvoice-v3-flash',
        input: inputObj
      };
      const headers: AuthHttpHeader = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`
      };
      const response = await httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(bodyObj),
        connectTimeout: this.config.timeoutMs,
        readTimeout: this.config.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      }).catch((err: BusinessError) => {
        Logger.error(TAG, `CosyVoice 请求异常: ${err.code}:${err.message}`);
        throw new Error(`${err.code}:${err.message}`);
      });
      return this.parseTtsAudioUrl(response.responseCode, response.result as string, 'CosyVoice');
    } finally {
      httpClient.destroy();
    }
  }

  private parseTtsAudioUrl(code: number, raw: string, provider: string): string {
    if (code === 401 || code === 403) {
      const detail: string = this.extractDashScopeError(raw);
      const lower: string = detail.toLowerCase();
      if (lower.indexOf('allocationquota') >= 0 || lower.indexOf('free quota') >= 0 ||
        detail.indexOf('额度') >= 0 || detail.indexOf('配额') >= 0) {
        throw new Error('云端语音额度已用完，请在阿里云百炼控制台关闭仅免费额度或充值');
      }
      throw new Error(detail.length > 0 ? detail : 'TTS 鉴权失败，请检查 API Key 是否有效并已开通语音合成');
    }
    if (code === 429) {
      throw new Error('TTS 请求过于频繁，请稍后再试');
    }
    if (code >= 500) {
      throw new Error('TTS 服务器暂时不可用');
    }
    if (code < 200 || code >= 300) {
      const detail: string = this.extractDashScopeError(raw);
      throw new Error(detail.length > 0 ? detail : `TTS 合成失败，HTTP ${code}`);
    }
    let parsed: Record<string, Object> = {};
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (parseErr) {
      Logger.error(TAG, `${provider} TTS 响应 JSON 解析失败: ${parseErr instanceof Error ? parseErr.message : 'SyntaxError'}`);
      throw new Error(`${provider} 语音合成响应格式非标准 JSON`);
    }
    const outputVal: Object | undefined = parsed['output'];
    if (outputVal === undefined) {
      throw new Error(`${provider} 响应格式异常`);
    }
    const output = outputVal as Record<string, Object>;
    const audioVal: Object | undefined = output['audio'];
    if (audioVal === undefined) {
      throw new Error(`${provider} 响应缺少音频数据`);
    }
    const audio = audioVal as Record<string, Object>;
    let audioUrl: string = (audio['url'] as string) ?? '';
    if (audioUrl.length === 0) {
      throw new Error(`${provider} 响应缺少音频 URL`);
    }
    if (audioUrl.startsWith('http://')) {
      audioUrl = 'https://' + audioUrl.substring(7);
    }
    Logger.info(TAG, `${provider} 音频 URL 已获取`);
    return audioUrl;
  }

  private extractDashScopeError(raw: string): string {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const message: string = (parsed['message'] as string) ?? '';
      const code: string = (parsed['code'] as string) ?? '';
      if (message.length > 0) {
        return code.length > 0 ? `${message} (${code})` : message;
      }
    } catch (e) {
      // ignore parse error
    }
    return '';
  }

  /**
   * 下载 MP3 音频到临时文件。
   *
   * @param audioUrl 音频文件 URL
   * @returns 本地文件路径
   * @throws Error 下载或写入失败
   */
  private async downloadAudio(audioUrl: string): Promise<string> {
    if (this.context === null) {
      throw new Error('SpeechService 未初始化 context');
    }

    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const response = await httpClient.request(audioUrl, {
        method: http.RequestMethod.GET,
        connectTimeout: this.config.timeoutMs,
        readTimeout: this.config.timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });

      const code: number = response.responseCode;
      if (code < 200 || code >= 300) {
        throw new Error(`音频下载失败，HTTP ${code}`);
      }

      const audioBuffer: ArrayBuffer = response.result as ArrayBuffer;
      if (audioBuffer.byteLength === 0) {
        throw new Error('音频数据为空');
      }

      // 写入 cacheDir 临时文件
      const cacheDir: string = this.context.cacheDir;
      const ext: string = audioUrl.indexOf('.wav') >= 0 ? 'wav' : 'mp3';
      const filePath: string = `${cacheDir}/tts_${Date.now()}.${ext}`;

      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, audioBuffer);
      fs.closeSync(file);

      Logger.info(TAG, `音频已保存: ${audioBuffer.byteLength} bytes`);
      return filePath;
    } finally {
      httpClient.destroy();
    }
  }

  /**
   * 使用 AVPlayer 播放本地音频文件。
   *
   * AVPlayer 状态流转：idle → initialized → prepared → playing → completed
   * - 设置 url 后自动转入 initialized
   * - initialized 时调用 prepare() 转入 prepared
   * - prepared 时调用 play() 转入 playing
   * - 播放完毕转入 completed，释放资源并 resolve
   *
   * @param filePath 本地 MP3 文件路径
   * @returns 播放完成的 Promise
   */
  private async playAudioFile(filePath: string): Promise<void> {
    let player: media.AVPlayer;
    let audioFd: number = -1;
    try {
      player = await media.createAVPlayer();
    } catch (e) {
      throw new Error('音频播放器创建失败');
    }
    this.currentPlayer = player;
    this.currentFilePath = filePath;

    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      let settled: boolean = false;
      let timeoutId: number = -1;

      const safeResolve = (): void => {
        if (!settled) {
          settled = true;
          if (timeoutId >= 0) {
            clearTimeout(timeoutId);
            timeoutId = -1;
          }
          if (this.currentPlayResolve === safeResolve) {
            this.currentPlayResolve = null;
          }
          resolve();
        }
      };

      const safeReject = (err: Error): void => {
        if (!settled) {
          settled = true;
          if (timeoutId >= 0) {
            clearTimeout(timeoutId);
            timeoutId = -1;
          }
          if (this.currentPlayResolve === safeResolve) {
            this.currentPlayResolve = null;
          }
          reject(err);
        }
      };

      this.currentPlayResolve = safeResolve;

      // 8 秒超时兜底保护
      timeoutId = setTimeout(() => {
        if (!settled) {
          Logger.warn(TAG, 'AVPlayer 播放超时，自动解阻断');
          this.releasePlayer(player);
          cleanup();
          safeResolve();
        }
      }, 8000);

      const cleanup = (): void => {
        if (audioFd >= 0) {
          try {
            fs.closeSync(audioFd);
          } catch (e) {
            // ignore
          }
          audioFd = -1;
        }
        if (this.currentPlayer === player) {
          this.currentPlayer = null;
        }
        if (this.currentFilePath === filePath) {
          this.currentFilePath = '';
        }
        this.cleanupFile(filePath);
      };

      player.on('stateChange', (state: string, reason: media.StateChangeReason): void => {
        if (settled) {
          return;
        }
        switch (state) {
          case 'initialized':
            try {
              player.prepare();
            } catch (e) {
              this.releasePlayer(player);
              cleanup();
              safeReject(new Error('音频准备失败'));
            }
            break;
          case 'prepared':
            try {
              player.play();
              Logger.info(TAG, '开始播放音频');
            } catch (e) {
              this.releasePlayer(player);
              cleanup();
              safeReject(new Error('音频播放启动失败'));
            }
            break;
          case 'completed':
          case 'stopped':
          case 'released':
            Logger.info(TAG, `音频状态流转: ${state}`);
            this.releasePlayer(player);
            cleanup();
            safeResolve();
            break;
          case 'error':
            this.releasePlayer(player);
            cleanup();
            safeReject(new Error('音频播放失败'));
            break;
          default:
            break;
        }
      });

      player.on('error', (error: BusinessError): void => {
        if (settled) {
          return;
        }
        settled = true;
        const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
        Logger.error(TAG, `AVPlayer 错误: ${msg}`);
        this.releasePlayer(player);
        cleanup();
        reject(new Error('音频播放错误'));
      });

      // 鸿蒙本地音频须用 fd:// 协议，直接传路径会导致播放失败。
      try {
        const audioFile = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
        audioFd = audioFile.fd;
        player.url = `fd://${audioFd}`;
      } catch (e) {
        settled = true;
        this.releasePlayer(player);
        cleanup();
        reject(new Error('音频源设置失败'));
      }
    });
  }

  /**
   * 释放 AVPlayer 资源。
   */
  private releasePlayer(player: media.AVPlayer): void {
    try {
      player.release();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      Logger.warn(TAG, `AVPlayer 释放失败: ${msg}`);
    }
  }

  /**
   * 清理临时音频文件（阅后即焚）。
   */
  private cleanupFile(filePath: string): void {
    try {
      fs.unlinkSync(filePath);
    } catch (e) {
      // 文件可能不存在或已被清理，忽略
    }
  }

  /**
   * 停止当前播放并清理资源。
   */
  private async stopPlayback(): Promise<void> {
    if (this.currentPlayResolve !== null) {
      const fn = this.currentPlayResolve;
      this.currentPlayResolve = null;
      fn();
    }
    if (this.currentPlayer !== null) {
      try {
        this.currentPlayer.stop();
      } catch (e) {
        // 忽略 stop 错误
      }
      try {
        this.currentPlayer.release();
      } catch (e) {
        // 忽略 release 错误
      }
      this.currentPlayer = null;
    }
    if (this.currentFilePath.length > 0) {
      this.cleanupFile(this.currentFilePath);
      this.currentFilePath = '';
    }
  }

  /**
   * 停止当前播报（云端播放 + 系统朗读）。
   */
  public stopSpeak(): void {
    this.stopPlayback();
    this.stopSystemTts();
  }

  /**
   * 启动 ASR 识别（按住说话）。
   * 核心铁律：优先使用阿里云百炼 DashScope 多模态音频大模型（qwen-audio-turbo）端到端云端识别；
   * 未配置 API Key 时回退系统原生 CoreSpeechKit 引擎。
   */
  public startASR(
    onResult: (text: string, isFinal: boolean) => void,
    onError: (msg: string) => void,
    onComplete?: (finalText: string) => void
  ): void {
    this.asrOnResult = onResult;
    this.asrOnError = onError;
    this.asrOnComplete = onComplete ?? null;
    this.asrFinalText = '';
    this.asrCompleted = false;

    // 录音前先停止当前播放，避免录入扬声器外放声音
    this.stopSpeak();

    if (this.asrRecording || (this.asrReady && this.asrEngine !== null)) {
      Logger.warn(TAG, 'ASR 录音或识别已在进行中');
      return;
    }

    // 优先：使用阿里云 DashScope 云端大模型多模态转写
    if (this.config.apiKey.length > 0) {
      this.startCloudASR();
      return;
    }

    // 兜底：未配置云端 Key 时使用系统原生 CoreSpeechKit
    this.startSystemASR();
  }

  /**
   * 启动云端 ASR 录音（基于 HarmonyOS AVRecorder 录制 AAC 高保真音频）
   */
  private async startCloudASR(): Promise<void> {
    try {
      this.cleanUpRecorder();
      this.asrRecording = true;

      const cacheDir: string = this.context ? this.context.cacheDir : '/data/storage/el2/base/haps/entry/cache';
      const filePath: string = `${cacheDir}/asr_rec_${Date.now()}.m4a`;
      this.asrRecordFilePath = filePath;

      const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.asrRecordFileFd = file.fd;

      const recorder: media.AVRecorder = await media.createAVRecorder();
      this.avRecorder = recorder;

      recorder.on('error', (err: BusinessError) => {
        Logger.error(TAG, `AVRecorder 错误: ${err.code} ${err.message}`);
      });

      const profile: media.AVRecorderProfile = {
        audioBitrate: 64000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 16000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A
      };

      const avConfig: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: profile,
        url: `fd://${file.fd}`
      };

      await recorder.prepare(avConfig);
      await recorder.start();
      this.asrRecordStartTime = Date.now();
      Logger.info(TAG, `云端 ASR 录音已启动: ${filePath}`);
      if (this.asrOnResult) {
        this.asrOnResult('正在聆听…', false);
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      Logger.error(TAG, `启动云端麦克风录音失败: ${msg}`);
      this.cleanUpRecorder();
      if (this.asrOnError) {
        this.asrOnError(`无法启动麦克风录音：${msg}`);
      }
    }
  }

  /**
   * 停止 ASR（松手）：结束录音并发送云端大模型转写，或结束本地 CoreSpeechKit 会话。
   */
  public async stopASR(): Promise<void> {
    if (!this.asrRecording && !this.asrReady) {
      if (this.asrFinalText.length > 0) {
        this.finishAsrSession(false);
      }
      return;
    }

    if (this.avRecorder !== null || this.asrRecording) {
      await this.stopCloudASR();
      return;
    }

    if (this.asrEngine !== null) {
      Logger.info(TAG, '[ASR] stopASR / finish');
      try {
        this.asrEngine.finish(ASR_SESSION_ID);
      } catch (e) {
        Logger.warn(TAG, `ASR finish 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
        this.finishAsrSession(true);
      }
    }
  }

  /**
   * 停止云端录音并调用 DashScope qwen-audio-turbo 转写
   */
  private async stopCloudASR(): Promise<void> {
    this.asrRecording = false;
    const recorder = this.avRecorder;
    this.avRecorder = null;

    // 录音至少缓冲 500ms，避免过快松手导致底层抛错
    const elapsed = Date.now() - this.asrRecordStartTime;
    if (elapsed < 500) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 500 - elapsed));
    }

    if (recorder !== null) {
      try {
        await recorder.stop();
      } catch (e) {
        Logger.warn(TAG, `AVRecorder stop 异常: ${JSON.stringify(e)}`);
      }
      try {
        await recorder.reset();
        await recorder.release();
      } catch (e) {
        Logger.warn(TAG, `AVRecorder release 异常: ${JSON.stringify(e)}`);
      }
    }

    if (this.asrRecordFileFd !== -1) {
      try {
        fs.closeSync(this.asrRecordFileFd);
      } catch (e) {}
      this.asrRecordFileFd = -1;
    }

    const filePath = this.asrRecordFilePath;
    this.asrRecordFilePath = '';

    if (!filePath || !fs.accessSync(filePath)) {
      this.handleAsrError('未录制到有效音频');
      return;
    }

    let fileSize = 0;
    try {
      fileSize = fs.statSync(filePath).size;
    } catch (e) {}

    if (fileSize < 2000) {
      this.cleanupFile(filePath);
      this.handleAsrError('说话时间较短或声音较轻，请长按靠近手机重试');
      return;
    }

    if (this.asrOnResult) {
      this.asrOnResult('正在云端解析…', false);
    }

    let base64Audio = '';
    try {
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(fileSize);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      this.cleanupFile(filePath);

      base64Audio = this.asrBase64Helper.encodeToStringSync(new Uint8Array(buf));
    } catch (readErr) {
      this.cleanupFile(filePath);
      const readMsg = readErr instanceof Error ? readErr.message : JSON.stringify(readErr);
      this.handleAsrError(`读取录音数据失败：${readMsg}`);
      return;
    }

    try {
      const recognized = await this.requestDashScopeASR(base64Audio);
      if (recognized.length > 0) {
        this.asrFinalText = recognized;
        if (this.asrOnResult) {
          this.asrOnResult(recognized, true);
        }
        if (this.asrOnComplete) {
          this.asrOnComplete(recognized);
        }
      } else {
        this.handleAsrError('没有听到您的声音，请按住屏幕重试');
      }
    } catch (apiErr) {
      const msg: string = apiErr instanceof Error ? apiErr.message : '云端识别网络异常';
      Logger.error(TAG, `云端 ASR 请求失败: ${msg}`);
      if (msg.indexOf('未清晰收录') >= 0 || msg.indexOf('HTTP 400') >= 0 || msg.indexOf('The audio is empty') >= 0) {
        this.handleAsrError('未检测到清晰声音，请按住屏幕靠近麦克风重试');
      } else if (msg.indexOf('网络') >= 0 || msg.indexOf('failed') >= 0 || msg.indexOf('timeout') >= 0 ||
                 msg.indexOf('connect') >= 0 || msg.indexOf('2300006') >= 0) {
        this.handleAsrError('当前处于离线模式，请改用下方文字输入或点击功能卡片');
      } else {
        this.handleAsrError(`语音识别未完成：${msg}`);
      }
    }
  }

  /**
   * 调用阿里云 DashScope 多模态音频大模型（qwen-audio-turbo）转写语音
   */
  private async requestDashScopeASR(base64Audio: string): Promise<string> {
    try {
      return await this.doRequestDashScopeASR(base64Audio, 'audio/m4a');
    } catch (e) {
      Logger.warn(TAG, `m4a ASR 识别异常，尝试 mp4 格式自愈重试: ${e}`);
      return await this.doRequestDashScopeASR(base64Audio, 'audio/mp4');
    }
  }

  private async doRequestDashScopeASR(base64Audio: string, mime: string): Promise<string> {
    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const url: string = `${this.config.baseUrl}/api/v1/services/aigc/multimodal-generation/generation`;
      const audioItem: QwenAudioAudioItem = {
        audio: `data:${mime};base64,${base64Audio}`
      };
      const textItem: QwenAudioTextItem = {
        text: '转写这段语音的内容，只输出听到的原话文字，不要添加任何标点以外的解释、标号或多余说明；如果是静音、杂音或无法辨认，输出空。'
      };
      const audioReqMsg: QwenAudioMessage = {
        role: 'user',
        content: [audioItem, textItem]
      };
      const input: QwenAudioInput = {
        messages: [audioReqMsg]
      };
      const bodyObj: QwenAudioRequestBody = {
        model: 'qwen-audio-turbo',
        input: input
      };

      const headers: AuthHttpHeader = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`
      };

      const response = await httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(bodyObj),
        connectTimeout: this.config.timeoutMs,
        readTimeout: this.config.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode < 200 || response.responseCode >= 300) {
        const rawRes: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
        Logger.error(TAG, `DashScope ASR HTTP ${response.responseCode}: ${rawRes}`);
        if (response.responseCode === 400 && (rawRes.indexOf('The audio is empty') >= 0 || rawRes.indexOf('InvalidParameter') >= 0)) {
          throw new Error('未清晰收录到说话声音，请靠近麦克风重试');
        }
        throw new Error(`HTTP ${response.responseCode}`);
      }

      const resStr: string = response.result as string;
      const parsed = JSON.parse(resStr) as Record<string, Object>;
      const output = parsed['output'] as Record<string, Object> | undefined;
      if (!output) {
        return '';
      }
      const choices = output['choices'] as Array<Record<string, Object>> | undefined;
      if (!choices || choices.length === 0) {
        return '';
      }
      const respMsg = choices[0]['message'] as Record<string, Object> | undefined;
      if (!respMsg) {
        return '';
      }
      let text = '';
      const contentVal: Object | undefined = respMsg['content'];
      if (contentVal !== undefined) {
        if (typeof contentVal === 'string') {
          text = contentVal;
        } else {
          const contentArr = contentVal as Array<Record<string, string>>;
          if (contentArr.length > 0) {
            const first = contentArr[0];
            text = first['text'] ?? '';
          }
        }
      }

      text = text.trim();
      if ((text.startsWith('"') && text.endsWith('"')) || (text.startsWith('“') && text.endsWith('”'))) {
        text = text.substring(1, text.length - 1).trim();
      }
      let plain = text;
      while (plain.endsWith('。') || plain.endsWith('.') || plain.endsWith('！') || plain.endsWith('!')) {
        plain = plain.substring(0, plain.length - 1).trim();
      }
      if (plain.length === 0 || plain === '[无语音]' || plain === '无语音' || plain === '[静音]' ||
          plain === '静音' || plain === '空' || plain === '无法辨认' || plain === '无声音' ||
          plain === '没有声音') {
        return '';
      }
      return text;
    } finally {
      httpClient.destroy();
    }
  }

  private cleanUpRecorder(): void {
    this.asrRecording = false;
    if (this.avRecorder !== null) {
      try {
        this.avRecorder.release();
      } catch (e) {}
      this.avRecorder = null;
    }
    if (this.asrRecordFileFd !== -1) {
      try {
        fs.closeSync(this.asrRecordFileFd);
      } catch (e) {}
      this.asrRecordFileFd = -1;
    }
    if (this.asrRecordFilePath.length > 0) {
      this.cleanupFile(this.asrRecordFilePath);
      this.asrRecordFilePath = '';
    }
  }

  private handleAsrError(msg: string): void {
    this.asrRecording = false;
    this.asrReady = false;
    if (this.asrOnError) {
      this.asrOnError(msg);
    }
  }

  /**
   * 本地系统 CoreSpeechKit 语音识别（离线兜底）
   */
  private startSystemASR(): void {
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
      const msg: string = '当前设备不支持系统语音识别，请配置云端 API 或改用下方文字输入。';
      Logger.error(TAG, msg);
      if (this.asrOnError) {
        this.asrOnError(msg);
      }
      return;
    }

    try {
      const initParams: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1
      };
      speechRecognizer.createEngine(initParams, (err: BusinessError, engine: speechRecognizer.SpeechRecognitionEngine) => {
        if (err || !engine) {
          const msg: string = `语音引擎创建失败：${err ? err.message : '未知错误'}`;
          Logger.error(TAG, msg);
          if (this.asrOnError) {
            this.asrOnError(msg);
          }
          return;
        }
        this.asrEngine = engine;
        this.asrReady = true;
        this.bindAsrListener(engine);
        this.beginAsrListening(engine);
      });
    } catch (e) {
      const msg: string = `语音识别启动失败：${e instanceof Error ? e.message : JSON.stringify(e)}`;
      Logger.error(TAG, msg);
      if (this.asrOnError) {
        this.asrOnError(msg);
      }
    }
  }

  private bindAsrListener(engine: speechRecognizer.SpeechRecognitionEngine): void {
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (_sessionId: string, _eventMessage: string): void => {
        Logger.info(TAG, '[ASR] onStart');
      },
      onEvent: (_sessionId: string, eventCode: number, eventMessage: string): void => {
        Logger.info(TAG, `[ASR] onEvent code=${eventCode} msg=${eventMessage}`);
      },
      onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        const text: string = result.result ?? '';
        if (text.length > 0) {
          this.asrFinalText = text;
        }
        if (this.asrOnResult) {
          this.asrOnResult(text, result.isFinal === true);
        }
        if (result.isLast === true) {
          this.finishAsrSession(false);
        }
      },
      onComplete: (_sessionId: string, _eventMessage: string): void => {
        Logger.info(TAG, '[ASR] onComplete');
        this.finishAsrSession(false);
      },
      onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
        Logger.error(TAG, `[ASR] onError code=${errorCode} msg=${errorMessage}`);
        this.asrReady = false;
        if (this.asrOnError) {
          this.asrOnError(`语音识别失败：${errorMessage}`);
        }
        this.releaseAsrEngine();
      }
    };
    engine.setListener(listener);
  }

  private beginAsrListening(engine: speechRecognizer.SpeechRecognitionEngine): void {
    const audioInfo: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16
    };
    const extraParam: Record<string, Object> = {};
    extraParam['recognitionMode'] = 0;
    extraParam['vadBegin'] = 2000;
    extraParam['vadEnd'] = 3000;
    extraParam['maxAudioDuration'] = 60000;
    const startParams: speechRecognizer.StartParams = {
      sessionId: ASR_SESSION_ID,
      audioInfo: audioInfo,
      extraParams: extraParam
    };
    try {
      engine.startListening(startParams);
      Logger.info(TAG, '[ASR] startListening 已调用');
    } catch (e) {
      const msg: string = `开始聆听失败：${e instanceof Error ? e.message : JSON.stringify(e)}`;
      Logger.error(TAG, msg);
      if (this.asrOnError) {
        this.asrOnError(msg);
      }
      this.releaseAsrEngine();
    }
  }

  private finishAsrSession(force: boolean): void {
    if (this.asrCompleted && !force) {
      return;
    }
    this.asrCompleted = true;
    this.asrReady = false;
    const finalText: string = this.asrFinalText.trim();
    if (this.asrOnComplete) {
      this.asrOnComplete(finalText);
    } else if (finalText.length === 0 && this.asrOnError) {
      this.asrOnError('没有听到您的声音，请重试或改用文字输入');
    }
    this.releaseAsrEngine();
  }

  private releaseAsrEngine(): void {
    if (this.asrEngine !== null) {
      try {
        this.asrEngine.shutdown();
      } catch (e) {
        Logger.warn(TAG, `ASR shutdown 失败: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      }
    }
    this.asrEngine = null;
    this.asrReady = false;
  }

  /**
   * 释放资源。
   */
  public destroy(): void {
    this.stopPlayback();
    this.stopSystemTts();
    this.cleanUpRecorder();
    if (this.systemTts !== null) {
      try {
        this.systemTts.shutdown();
      } catch (e) {
        // ignore
      }
      this.systemTts = null;
    }
    this.systemTtsReady = false;
    this.releaseAsrEngine();
    this.ttsReady = false;
    this.asrReady = false;
    Logger.info(TAG, 'SpeechService 已销毁');
  }
}
