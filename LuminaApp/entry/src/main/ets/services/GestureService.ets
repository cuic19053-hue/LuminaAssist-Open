/**
 * @file GestureService.ets
 * @module services
 * @description 屏幕手势识别与防误触管理服务。
 * 
 * 核心功能：
 * 1. 支持全屏手势触摸解析：
 *    - 敲击 3 下：触发药品识别
 *    - 敲击 2 下：触发物品识别
 *    - 长按 1000ms：触发语音助手
 * 2. 距离传感器（Proximity Sensor）防误触拦截；
 * 3. 触发振动与语音双重确认；
 * 4. 可在设置中开启/关闭手势响应。
 */

import vibrator from '@ohos.vibrator';
import sensor from '@ohos.sensor';
import { Logger } from '../utils/Logger';
import { AccessibilityUtils } from '../utils/AccessibilityUtils';

const TAG: string = 'GestureService';

export interface GestureCallbacks {
  onTripleTap?: () => void;
  onDoubleTap?: () => void;
  onLongPress?: () => void;
  onLongPressEnd?: () => void;
}

export class GestureService {
  private static instance: GestureService | null = null;
  private enabled: boolean = true;
  private pocketProtectionEnabled: boolean = true;
  private vibrationEnabled: boolean = true;

  // 手势判定状态
  private tapCount: number = 0;
  private lastTapTime: number = 0;
  private tapTimer: number = -1;
  private longPressTimer: number = -1;
  private isLongPressTriggered: boolean = false;
  private isNearObject: boolean = false; // 距离传感器检测是否在口袋/贴近

  private callbacks: GestureCallbacks | null = null;

  public static getInstance(): GestureService {
    if (GestureService.instance === null) {
      GestureService.instance = new GestureService();
    }
    return GestureService.instance;
  }

  private constructor() {
    this.initSensorListener();
  }

  /**
   * 初始化距离传感器（口袋防误触检测）
   */
  private initSensorListener(): void {
    try {
      sensor.on(sensor.SensorId.PROXIMITY, (data: sensor.ProximityResponse) => {
        // data.distance 为 0 或很近时代表被遮挡（如放在口袋中）
        this.isNearObject = data.distance < 1.0;
        Logger.info(TAG, `距离传感器状态改变: distance=${data.distance}, isNear=${this.isNearObject}`);
      });
    } catch (error) {
      Logger.warn(TAG, `初始化距离传感器失败或不支持: ${JSON.stringify(error)}`);
    }
  }

  public setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  public isEnabled(): boolean {
    return this.enabled;
  }

  public setPocketProtection(enabled: boolean): void {
    this.pocketProtectionEnabled = enabled;
  }

  public setVibrationEnabled(enabled: boolean): void {
    this.vibrationEnabled = enabled;
  }

  public registerCallbacks(callbacks: GestureCallbacks): void {
    this.callbacks = callbacks;
  }

  /**
   * 处理 TouchEvent 触摸事件
   */
  public handleTouchEvent(event: TouchEvent): void {
    if (!this.enabled) {
      return;
    }

    // 若开启了防误触且距离传感器检测到被遮挡，拦截所有手势
    if (this.pocketProtectionEnabled && this.isNearObject) {
      Logger.info(TAG, '处于口袋/遮挡状态，已拦截手势');
      return;
    }

    const now = Date.now();

    if (event.type === TouchType.Down) {
      this.isLongPressTriggered = false;

      // 启动长按定时器（1000ms）
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
      }
      this.longPressTimer = setTimeout(() => {
        this.isLongPressTriggered = true;
        this.onTriggerLongPress();
      }, 1000);

    } else if (event.type === TouchType.Up) {
      // 取消长按定时器
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }

      // 如果长按已触发，松手时结束长按录音
      if (this.isLongPressTriggered) {
        this.isLongPressTriggered = false;
        this.tapCount = 0;
        if (this.callbacks?.onLongPressEnd) {
          this.callbacks.onLongPressEnd();
        }
        return;
      }

      // 敲击次数计算（间隔 350ms 内视为连续敲击）
      if (now - this.lastTapTime < 350) {
        this.tapCount++;
      } else {
        this.tapCount = 1;
      }
      this.lastTapTime = now;

      // 清除之前的敲击延时
      if (this.tapTimer !== -1) {
        clearTimeout(this.tapTimer);
      }

      // 如果已达 3 次敲击，立即触发
      if (this.tapCount >= 3) {
        this.tapCount = 0;
        this.onTriggerTripleTap();
        return;
      }

      // 延迟 350ms 判定是否为双击
      this.tapTimer = setTimeout(() => {
        if (this.tapCount === 2) {
          this.onTriggerDoubleTap();
        }
        this.tapCount = 0;
      }, 350);

    } else if (event.type === TouchType.Cancel) {
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      if (this.isLongPressTriggered) {
        this.isLongPressTriggered = false;
        if (this.callbacks?.onLongPressEnd) {
          this.callbacks.onLongPressEnd();
        }
      }
      this.tapCount = 0;
    }
  }

  private async triggerFeedback(text: string): Promise<void> {
    if (this.vibrationEnabled) {
      try {
        vibrator.startVibration({ type: 'time', duration: 150 }, { id: 0, usage: 'touch' });
      } catch (err) {
        Logger.warn(TAG, `振动反馈失败: ${JSON.stringify(err)}`);
      }
    }
    AccessibilityUtils.getInstance().speak(text).catch(() => {});
  }

  private onTriggerTripleTap(): void {
    Logger.info(TAG, '触发手势：敲击 3 下 -> 药品识别');
    this.triggerFeedback('手势识别：开启药品识别');
    if (this.callbacks?.onTripleTap) {
      this.callbacks.onTripleTap();
    }
  }

  private onTriggerDoubleTap(): void {
    Logger.info(TAG, '触发手势：敲击 2 下 -> 物品识别');
    this.triggerFeedback('手势识别：开启物品识别');
    if (this.callbacks?.onDoubleTap) {
      this.callbacks.onDoubleTap();
    }
  }

  private onTriggerLongPress(): void {
    Logger.info(TAG, '触发手势：长按 1 秒 -> 唤醒语音助手');
    // 仅振动提示，避免外放 TTS 语音被麦克风录入造成杂音
    if (this.vibrationEnabled) {
      try {
        vibrator.startVibration({ type: 'time', duration: 150 }, { id: 0, usage: 'touch' });
      } catch (err) {
        Logger.warn(TAG, `振动反馈失败: ${JSON.stringify(err)}`);
      }
    }
    if (this.callbacks?.onLongPress) {
      this.callbacks.onLongPress();
    }
  }
}
