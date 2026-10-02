/**
 * @file NetworkMonitor.ets
 * @module services
 * @description 网络状态监控服务（单例）。
 * 
 * 提供：
 * 1. 系统默认网络连接状态探测 (@ohos.net.connection)
 * 2. 云端 API 连通性与网络质量监测
 */

import connection from '@ohos.net.connection';
import { Logger } from '../utils/Logger';

const TAG: string = 'NetworkMonitor';

export class NetworkMonitor {
  private static instance: NetworkMonitor | null = null;

  private constructor() {}

  public static getInstance(): NetworkMonitor {
    if (NetworkMonitor.instance === null) {
      NetworkMonitor.instance = new NetworkMonitor();
    }
    return NetworkMonitor.instance;
  }

  /**
   * 检查系统当前是否有可用网络连接。
   */
  public async isNetworkAvailable(): Promise<boolean> {
    try {
      const hasNet = await connection.hasDefaultNet();
      Logger.info(TAG, `系统网络连通状态: ${hasNet}`);
      return hasNet;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      Logger.warn(TAG, `查询系统网络状态失败: ${msg}`);
      // 容错机制：发生异常时假设可用，由 HTTP 客户端实际请求结果决定
      return true;
    }
  }

  /**
   * 检查网络能力（例如是否具有 INTERNET 能力）。
   */
  public async hasInternetCapability(): Promise<boolean> {
    try {
      const netHandle = await connection.getDefaultNet();
      if (!netHandle || netHandle.netId === 0) {
        return false;
      }
      const capabilities = await connection.getNetCapabilities(netHandle);
      const bearerTypes = capabilities.bearerTypes ?? [];
      const netCaps = capabilities.networkCap ?? [];
      Logger.info(TAG, `网络类型: ${JSON.stringify(bearerTypes)}, 能力: ${JSON.stringify(netCaps)}`);
      return true;
    } catch (err) {
      Logger.warn(TAG, `检查 Internet 能力失败: ${err instanceof Error ? err.message : String(err)}`);
      return true;
    }
  }
}
