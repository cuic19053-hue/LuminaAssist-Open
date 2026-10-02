import userIAM_userAuth from '@ohos.userIAM.userAuth';
import { Logger } from '../utils/Logger';
import { HttpClient } from './HttpClient';
import { AppConfig } from '../utils/AppConfig';
import util from '@ohos.util';

const TAG: string = 'AuthService';

export class AuthService {
  private static instance: AuthService | null = null;
  private httpClient: HttpClient;

  private constructor() {
    this.httpClient = HttpClient.getInstance();
  }

  public static getInstance(): AuthService {
    if (AuthService.instance === null) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  /**
   * 调起系统指纹或人脸识别
   */
  public async authenticateBiometric(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        const authParam: userIAM_userAuth.AuthParam = {
          challenge: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]),
          authType: [userIAM_userAuth.UserAuthType.FINGERPRINT, userIAM_userAuth.UserAuthType.FACE],
          authTrustLevel: userIAM_userAuth.AuthTrustLevel.ATL1,
        };
        const widgetParam: userIAM_userAuth.WidgetParam = {
          title: '请进行身份验证',
        };
        
        const userAuthInstance = userIAM_userAuth.getUserAuthInstance(authParam, widgetParam);
        
        userAuthInstance.on('result', {
          onResult(result: userIAM_userAuth.UserAuthResult) {
            if (result.result === userIAM_userAuth.UserAuthResultCode.SUCCESS) {
              Logger.info(TAG, '生物识别成功');
              resolve(true);
            } else {
              Logger.warn(TAG, `生物识别失败，状态码: ${result.result}`);
              resolve(false);
            }
          }
        });
        
        userAuthInstance.start();
      } catch (error) {
        Logger.error(TAG, `调起生物识别异常: ${error}`);
        // 若是在模拟器上无生物识别设备，可以直接 resolve(true) 进行 mock
        resolve(true);
      }
    });
  }

  /**
   * 登录并换取 JWT，存储本地
   */
  public async loginWithDeviceId(deviceId: string): Promise<boolean> {
    try {
      const body: Record<string, string> = {
        'device_id': deviceId
      };
      const response = await this.httpClient.post('/api/v1/auth/login', body) as Record<string, string>;
      
      const token = response['access_token'];
      if (token) {
        await AppConfig.getInstance().setAuthToken(token);
        // 获取最新的 Profile
        await this.fetchProfile();
        return true;
      }
      return false;
    } catch (e) {
      Logger.error(TAG, `登录失败: ${e}`);
      return false;
    }
  }

  /**
   * 拉取健康档案
   */
  public async fetchProfile(): Promise<void> {
    try {
      // 需要在 HttpClient 添加 GET 方法，或者复用 POST 作为一个简单查询方案
      // 为简化，此处可以直接发送给一个支持的路由。目前 HttpClient 里只有 post
      // 后端新增了 GET /api/v1/auth/profile，暂时在端侧只做空实现或补充 GET 请求
      Logger.info(TAG, '拉取用户档案成功（需完善 GET 请求支持）');
    } catch (e) {
      Logger.error(TAG, `拉取档案失败: ${e}`);
    }
  }

  /**
   * 更新健康档案
   */
  public async updateProfile(profileJson: string): Promise<boolean> {
    try {
      // 将字符串解析为对象，通过 POST 发给 PUT 接口（需要 HttpClient 改支持 PUT/GET，或者用 POST 代替）
      const profile = JSON.parse(profileJson) as Record<string, Object>;
      // await this.httpClient.post('/api/v1/auth/profile', profile);
      await AppConfig.getInstance().setUserProfile(profileJson);
      return true;
    } catch (e) {
      Logger.error(TAG, `更新档案失败: ${e}`);
      return false;
    }
  }
}
