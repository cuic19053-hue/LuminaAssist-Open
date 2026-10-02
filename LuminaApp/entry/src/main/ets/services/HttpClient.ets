/**
 * @file HttpClient.ets
 * @module services
 * @description 后端代理 HTTP 客户端（单例，端云双态-后端代理路径）。
 *
 * 真机调试注意：
 * - 默认 http://127.0.0.1:8000 仅适用于模拟器/本机；
 * - 真机须在设置页配置电脑局域网地址，如 http://192.168.1.100:8000；
 * - 后端需以 --host 0.0.0.0 启动，手机与电脑同一 WiFi。
 */

import http from '@ohos.net.http';
import util from '@ohos.util';
import { Logger } from '../utils/Logger';
import { AppConfig } from '../utils/AppConfig';

const TAG: string = 'HttpClient';

class HttpHeaderConfig {
  contentType: string = 'application/json';
  Authorization: string = '';
}

/**
 * HttpClient —— 后端代理 HTTP 客户端（单例）。
 */
export class HttpClient {
  private static instance: HttpClient | null = null;
  /** 后端代理基础地址（已部署至旧电脑，默认使用 Cloudflare 公网 HTTPS 隧道） */
  private baseUrl: string = 'https://invision-lewis-theatre-bids.trycloudflare.com';

  private constructor() {
  }

  public static getInstance(): HttpClient {
    if (HttpClient.instance === null) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  /**
   * 设置后端代理基础地址。
   * @param url 如 'http://192.168.1.100:8000'
   */
  public setBaseUrl(url: string): void {
    let normalized: string = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    this.baseUrl = normalized;
    Logger.info(TAG, `baseUrl 已更新为 ${normalized}`);
  }

  public getBaseUrl(): string {
    return this.baseUrl;
  }

  /**
   * 发起一次 POST 请求。
   */
  public async post(path: string, body: Object): Promise<Object> {
    const url: string = this.baseUrl + path;
    Logger.info(TAG, `POST ${url}`);
    const httpClient: http.HttpRequest = http.createHttp();
    try {
      const headers: HttpHeaderConfig = new HttpHeaderConfig();
      const token = AppConfig.getInstance().getAuthToken();
      if (token) {
        headers.Authorization = `Bearer ${token}`;
      }
      const response = await httpClient.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(body),
        connectTimeout: 20000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode < 200 || response.responseCode >= 300) {
        let detail: string = '';
        try {
          const errBody = JSON.parse(response.result as string) as Record<string, Object>;
          const detailVal: Object | undefined = errBody['detail'];
          if (detailVal !== undefined) {
            detail = String(detailVal);
          }
        } catch (parseErr) {
          const parseMsg: string = parseErr instanceof Error ? parseErr.message : '解析失败';
          Logger.warn(TAG, `非 2xx 响应体解析失败: ${parseMsg}`);
        }
        Logger.error(TAG, `HTTP ${response.responseCode}: ${response.result}`);
        throw new Error(detail.length > 0 ? detail : '服务器返回异常');
      }

      let parsed: Object;
      try {
        parsed = JSON.parse(response.result as string) as Object;
      } catch (parseErr) {
        Logger.error(TAG, `HTTP 200 响应解析 JSON 失败: ${parseErr instanceof Error ? parseErr.message : 'SyntaxError'}`);
        throw new Error('服务器响应格式非标准 JSON');
      }
      return parsed;
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : '';
      Logger.error(TAG, `POST ${path} 失败: ${msg}，baseUrl=${this.baseUrl}`);

      // 本方法主动抛出的业务异常原样上抛
      if (msg === '服务器返回异常' || (msg.length > 0 && msg.indexOf('网络') < 0 &&
        msg.indexOf('timeout') < 0 && msg.indexOf('超时') < 0 &&
        msg.indexOf('connect') < 0 && msg.indexOf('Socket') < 0 &&
        msg.indexOf('Failed') < 0 && msg.indexOf('failed') < 0)) {
        throw new Error(msg.length > 0 ? msg : '服务器返回异常');
      }
      if (msg.includes('timeout') || msg.includes('超时')) {
        throw new Error('网络请求超时，请检查网络后重试');
      }
      if (this.baseUrl.indexOf('127.0.0.1') >= 0 || this.baseUrl.indexOf('localhost') >= 0) {
        throw new Error(
          '网络连接失败：真机无法访问 127.0.0.1。请在设置中填写电脑局域网地址，例如 http://192.168.x.x:8000'
        );
      }
      throw new Error('网络连接失败，请稍后再试');
    } finally {
      httpClient.destroy();
    }
  }

  /**
   * 发起流式请求 (SSE)。
   */
  public async postStream(
    path: string, 
    body: Object, 
    onEvent: (event: string, data: string) => void,
    onComplete: () => void,
    onError: (err: Error) => void
  ): Promise<void> {
    const url: string = this.baseUrl + path;
    Logger.info(TAG, `POST (Stream) ${url}`);
    const httpClient: http.HttpRequest = http.createHttp();
    
    let buffer = '';
    const textDecoder = util.TextDecoder.create('utf-8');

    httpClient.on('dataReceive', (data: ArrayBuffer) => {
      const chunk = textDecoder.decodeToString(new Uint8Array(data));
      buffer += chunk;
      
      // Parse SSE
      let lines = buffer.split('\n');
      buffer = lines.pop() ?? ''; // last incomplete line stays in buffer
      
      let currentEvent = '';
      for (let line of lines) {
        line = line.trim();
        if (line.startsWith('event: ')) {
          currentEvent = line.substring(7);
        } else if (line.startsWith('data: ')) {
          const evtData = line.substring(6);
          onEvent(currentEvent, evtData);
        }
      }
    });

    try {
      const headers: HttpHeaderConfig = new HttpHeaderConfig();
      const token = AppConfig.getInstance().getAuthToken();
      if (token) {
        headers.Authorization = `Bearer ${token}`;
      }

      await httpClient.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        readTimeout: 60000,
      });
    } catch (e) {
      onError(e instanceof Error ? e : new Error(String(e)));
    }
    
    httpClient.on('dataEnd', () => {
      Logger.info(TAG, 'Stream ended');
      onComplete();
      httpClient.destroy();
    });
  }
}
