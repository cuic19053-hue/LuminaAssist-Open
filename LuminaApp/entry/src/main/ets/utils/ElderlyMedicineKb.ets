/**
 * @file ElderlyMedicineKb.ets
 * @description 离线优先混合 RAG 医药知识库（端侧 SQLite + 云端向量搜索）。
 */

import { DatabaseUtil } from './DatabaseUtil';
import { AppConfig } from './AppConfig';
import { Logger } from './Logger';
import http from '@ohos.net.http';

const TAG: string = 'ElderlyMedicineKb';

/** 知识库单一药品的结构化数据 */
export interface MedicineKbEntry {
  /** 药品通用名 */
  name: string;
  /** 药品分类（如：急救药、心血管药） */
  category: string;
  /** 用法用量提示 */
  usage: string;
  /** 致命警告/核心禁忌 */
  fatalWarning: string;
}

export class ElderlyMedicineKb {
  /**
   * 端云混合检索接口
   * 优先查询端侧 SQLite，如果未命中则请求云端 FastAPI ChromaDB 向量接口。
   * @param extractedName 端侧大模型提取的药名
   * @returns 命中则返回结构化的 MedicineKbEntry，未命中返回 null
   */
  public static async query(extractedName: string): Promise<MedicineKbEntry | null> {
    if (!extractedName || extractedName.length === 0) {
      return null;
    }
    
    const keyword: string = extractedName.trim();

    // 1. 本地 SQLite 查询 (离线应急)
    try {
      const dbUtil = DatabaseUtil.getInstance();
      const localResult = await dbUtil.queryMedicine(keyword);
      if (localResult) {
        Logger.info(TAG, `【端侧命中】SQLite 本地命中急救药: ${keyword}`);
        return {
          name: (localResult.name as string) + ' (本地紧急缓存)',
          category: localResult.category as string,
          usage: localResult.usage as string,
          fatalWarning: localResult.fatalWarning as string
        };
      }
    } catch (e) {
      Logger.error(TAG, `本地 SQLite 查询异常: ${JSON.stringify(e)}`);
    }

    // 2. 云端 ChromaDB 向量检索 (容错降级)
    Logger.info(TAG, `【端侧未命中】尝试请求云端 RAG 向量检索: ${keyword}`);
    try {
      const baseUrl: string = AppConfig.getInstance().getBackendUrl();
      const url: string = `${baseUrl}/api/v1/medicine/search`;
      
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: JSON.stringify({ query: keyword }),
        readTimeout: 10000,
        connectTimeout: 10000
      });

      if (response.responseCode === 200 && response.result) {
        const data = JSON.parse(response.result as string) as MedicineKbEntry;
        Logger.info(TAG, `【云端命中】返回药品: ${data.name}`);
        const resEntry: MedicineKbEntry = {
          name: data.name,
          category: data.category,
          usage: data.usage,
          fatalWarning: data.fatalWarning
        };
        return resEntry;
      } else {
        Logger.warn(TAG, `云端 RAG 返回异常状态码: ${response.responseCode}`);
      }
    } catch (e) {
      Logger.error(TAG, `云端请求失败，可能是断网: ${JSON.stringify(e)}`);
    }
    
    return null;
  }

  /**
   * 将结构化对象拼接为适合 TTS 语音播报的通顺长句
   */
  public static buildTtsString(entry: MedicineKbEntry): string {
    return `【端云混合知识库】这是${entry.name}，属于${entry.category}。${entry.usage} 请极其注意：${entry.fatalWarning}`;
  }
}
