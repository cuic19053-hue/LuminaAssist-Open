/**
 * @file SettingsPage.ets
 * @module pages
 * @description 光语助手设置页（对齐原型图 Screen 08：语音/手势与反馈/模式 + API Key 加密存储）。
 */

import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import { KeyStoreUtil } from '../utils/KeyStoreUtil';
import { AccessibilityUtils } from '../utils/AccessibilityUtils';
import { AppConfig } from '../utils/AppConfig';
import { LLMClient } from '../services/LLMClient';
import { SpeechService } from '../services/SpeechService';
import { ASRService } from '../services/ASRService';
import { HttpClient } from '../services/HttpClient';
import { GestureService } from '../services/GestureService';
import { Logger } from '../utils/Logger';
import { AuthService } from '../services/AuthService';

const TAG: string = 'SettingsPage';
const KEY_ALIAS_LLM: string = 'llm_api_key';
const KEY_ALIAS_TTS: string = 'tts_api_key';

@Entry
@Component
struct SettingsPage {
  @State llmKey: string = '';
  @State ttsKey: string = '';
  @State backendUrl: string = '';
  @State shareKey: boolean = true;
  @State saving: boolean = false;
  @State statusText: string = '';
  @State hasSavedLlm: boolean = false;
  @State hasSavedTts: boolean = false;
  @State llmKeyHint: string = '';
  @State ttsKeyHint: string = '';

  // 华为上架与工信部合规弹窗与备案号
  @State showPrivacyModal: boolean = false;
  @State showDisclaimerModal: boolean = false;
  @State showAiNoticeModal: boolean = false;
  @State miitIcpText: string = '粤ICP备20260001号-1A';

  // 设置页三大维度开关 (对齐原型 Screen 08)
  @State playbackSpeed: number = 1.0;
  @State gestureEnabled: boolean = true;
  @State vibrationEnabled: boolean = true;
  @State pocketProtectionEnabled: boolean = true;
  @State offlineModeManual: boolean = false;

  // 登录鉴权状态
  @State isLoggedIn: boolean = false;
  @State profileDesc: string = '未登录，点击身份认证';
  
  aboutToAppear(): void {
    this.loadSavedSettings();
  }

  private async loadSavedSettings(): Promise<void> {
    try {
      const ctx: Context = this.getUIContext().getHostContext() as Context;
      await AppConfig.getInstance().ensureInit(ctx);
      await KeyStoreUtil.getInstance().ensureInit(ctx);

      this.backendUrl = AppConfig.getInstance().getBackendUrl();
      HttpClient.getInstance().setBaseUrl(this.backendUrl);
      this.miitIcpText = await AppConfig.getInstance().getMiitIcp();

      this.hasSavedLlm = await KeyStoreUtil.getInstance().hasApiKey(KEY_ALIAS_LLM);
      this.hasSavedTts = await KeyStoreUtil.getInstance().hasApiKey(KEY_ALIAS_TTS);

      if (this.hasSavedLlm) {
        const savedLlm: string = await KeyStoreUtil.getInstance().loadApiKey(KEY_ALIAS_LLM);
        this.llmKeyHint = this.maskKey(savedLlm);
        LLMClient.getInstance().updateConfig({ 'apiKey': savedLlm });
      }

      if (this.hasSavedTts) {
        const savedTts: string = await KeyStoreUtil.getInstance().loadApiKey(KEY_ALIAS_TTS);
        this.ttsKeyHint = this.maskKey(savedTts);
        SpeechService.getInstance().updateConfig({ 'apiKey': savedTts });
        ASRService.getInstance().updateConfig({ 'apiKey': savedTts });
      } else if (this.hasSavedLlm) {
        const savedLlm: string = await KeyStoreUtil.getInstance().loadApiKey(KEY_ALIAS_LLM);
        SpeechService.getInstance().updateConfig({ 'apiKey': savedLlm });
        ASRService.getInstance().updateConfig({ 'apiKey': savedLlm });
      }

      if (this.hasSavedLlm || this.hasSavedTts) {
        this.statusText = '配置已加密载入';
      }

      // 加载本地 Token 状态
      const token = AppConfig.getInstance().getAuthToken();
      if (token) {
        this.isLoggedIn = true;
        const profile = AppConfig.getInstance().getUserProfile();
        if (profile) {
          try {
            const parsed = JSON.parse(profile) as Record<string, Object>;
            const chronic = parsed['chronic_diseases'] as string[];
            if (chronic && chronic.length > 0) {
              this.profileDesc = `已登录 · ${chronic.join('/')}患者`;
            } else {
              this.profileDesc = '已登录 · 暂无特殊健康档案';
            }
          } catch (e) {
            this.profileDesc = '已登录';
          }
        } else {
          this.profileDesc = '已登录';
        }
      }
    } catch (e) {
      Logger.error(TAG, '加载已保存配置失败: ' + JSON.stringify(e));
    }
  }

  private maskKey(key: string): string {
    if (key.length <= 8) {
      return '********';
    }
    return `${key.substring(0, 3)}****${key.substring(key.length - 4)}`;
  }

  private async saveKeys(): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    this.statusText = '保存中...';

    try {
      const ctx: Context = this.getUIContext().getHostContext() as Context;
      await AppConfig.getInstance().ensureInit(ctx);
      await KeyStoreUtil.getInstance().ensureInit(ctx);

      if (this.backendUrl.trim().length > 0) {
        await AppConfig.getInstance().setBackendUrl(this.backendUrl);
        HttpClient.getInstance().setBaseUrl(AppConfig.getInstance().getBackendUrl());
      }

      const ksu = KeyStoreUtil.getInstance();
      let llmKeyValue: string = this.llmKey.trim();
      if (llmKeyValue.length === 0 && this.hasSavedLlm) {
        llmKeyValue = await ksu.loadApiKey(KEY_ALIAS_LLM);
      }
      if (llmKeyValue.length > 0) {
        await ksu.saveApiKey(KEY_ALIAS_LLM, llmKeyValue);
        LLMClient.getInstance().updateConfig({ 'apiKey': llmKeyValue });
        this.hasSavedLlm = true;
        this.llmKeyHint = this.maskKey(llmKeyValue);
        this.llmKey = '';
      }

      let ttsKeyValue: string = this.shareKey ? llmKeyValue : this.ttsKey.trim();
      if (ttsKeyValue.length === 0 && this.hasSavedTts) {
        ttsKeyValue = await ksu.loadApiKey(KEY_ALIAS_TTS);
      }
      if (ttsKeyValue.length > 0) {
        await ksu.saveApiKey(KEY_ALIAS_TTS, ttsKeyValue);
        SpeechService.getInstance().updateConfig({ 'apiKey': ttsKeyValue });
        ASRService.getInstance().updateConfig({ 'apiKey': ttsKeyValue });
        this.hasSavedTts = true;
        this.ttsKeyHint = this.maskKey(ttsKeyValue);
        this.ttsKey = '';
      }

      // 同步应用到 GestureService
      GestureService.getInstance().setEnabled(this.gestureEnabled);
      GestureService.getInstance().setVibrationEnabled(this.vibrationEnabled);
      GestureService.getInstance().setPocketProtection(this.pocketProtectionEnabled);

      this.statusText = '保存成功';
      AccessibilityUtils.getInstance().speak('设置已保存');
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      this.statusText = '保存失败';
      AccessibilityUtils.getInstance().speak('保存失败：' + msg);
    } finally {
      this.saving = false;
    }
  }

  private async deleteKeys(): Promise<void> {
    if (this.saving) return;
    this.saving = true;
    try {
      const ksu = KeyStoreUtil.getInstance();
      await ksu.deleteApiKey(KEY_ALIAS_LLM);
      await ksu.deleteApiKey(KEY_ALIAS_TTS);
      LLMClient.getInstance().updateConfig({ 'apiKey': '' });
      SpeechService.getInstance().updateConfig({ 'apiKey': '' });
      ASRService.getInstance().updateConfig({ 'apiKey': '' });
      this.llmKey = '';
      this.ttsKey = '';
      this.llmKeyHint = '';
      this.ttsKeyHint = '';
      this.hasSavedLlm = false;
      this.hasSavedTts = false;
      this.statusText = '已删除 API Key';
      AccessibilityUtils.getInstance().speak('API Key 已删除');
    } catch (error) {
      this.statusText = '删除失败';
    } finally {
      this.saving = false;
    }
  }

  build() {
    Stack() {
      Column() {
        // 1. 顶部标题栏（薄荷绿浅色高对比）
      Row() {
        Button('返回')
          .width(76)
          .height(40)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#E6F8F1')
          .fontColor('#04785C')
          .border({ width: 1, color: '#BFE9D8' })
          .borderRadius(12)
          .onClick(() => this.getUIContext().getRouter().back())
          .accessibilityText('返回首页')

        Text('设置')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182925')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Blank().width(76)
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })

      Scroll() {
        Column({ space: 16 }) {

          // 2. 用户无障碍卡片 (原型头部)
          Row({ space: 12 }) {
            Stack() {
              Text('👤')
                .fontSize(24)
            }
            .width(52)
            .height(52)
            .borderRadius(16)
            .backgroundColor('#E6F8F1')

            Column({ space: 4 }) {
              Text(this.isLoggedIn ? '已认证用户' : '点击进行安全登录')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182925')
              Text(this.profileDesc)
                .fontSize(12)
                .fontColor('#8AA09A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(this.isLoggedIn ? '云端在线' : '离线状态')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isLoggedIn ? '#04785C' : '#8AA09A')
              .backgroundColor('#E6F8F1')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(10)
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E2ECE7' })
          .borderRadius(16)
          .onClick(async () => {
            if (!this.isLoggedIn) {
              const success = await AuthService.getInstance().authenticateBiometric();
              if (success) {
                // 简化起见用 deviceId 作为登录标识
                const loginSuccess = await AuthService.getInstance().loginWithDeviceId("device_user_001");
                if (loginSuccess) {
                  this.isLoggedIn = true;
                  this.profileDesc = "已登录 · 数据同步中";
                }
              }
            }
          })

          // 3. 语音设置组
          Column({ space: 8 }) {
            Text('语音')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8AA09A')
              .margin({ left: 4 })

            Column() {
              Row() {
                Column({ space: 2 }) {
                  Text('播报语速')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text(`当前 ${this.playbackSpeed.toFixed(1)} 倍速`)
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Row({ space: 6 }) {
                  Button('-')
                    .width(36)
                    .height(36)
                    .fontSize(16)
                    .fontColor('#0F766E')
                    .backgroundColor('#E5F5F3')
                    .borderRadius(18)
                    .onClick(() => {
                      if (this.playbackSpeed > 0.8) {
                        this.playbackSpeed -= 0.1;
                      }
                    })

                  Button('+')
                    .width(36)
                    .height(36)
                    .fontSize(16)
                    .fontColor('#0F766E')
                    .backgroundColor('#E5F5F3')
                    .borderRadius(18)
                    .onClick(() => {
                      if (this.playbackSpeed < 1.5) {
                        this.playbackSpeed += 0.1;
                      }
                    })
                }
              }
              .width('100%')
              .padding(14)
              .border({ width: { bottom: 1 }, color: '#F0F6F3' })

              Row() {
                Column({ space: 2 }) {
                  Text('播报音色')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('温和女声 · 云端合成')
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('默认音色 ›')
                  .fontSize(13)
                  .fontColor('#8AA09A')
              }
              .width('100%')
              .padding(14)
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#E2ECE7' })
            .borderRadius(16)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 4. 手势与反馈组
          Column({ space: 8 }) {
            Text('手势与反馈')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8AA09A')
              .margin({ left: 4 })

            Column() {
              Row() {
                Column({ space: 2 }) {
                  Text('手势快捷操作')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('敲击/长按快速唤起功能')
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.gestureEnabled })
                  .selectedColor('#10B981')
                  .height(28)
                  .onChange((isOn: boolean) => {
                    this.gestureEnabled = isOn;
                    GestureService.getInstance().setEnabled(isOn);
                  })
              }
              .width('100%')
              .padding(14)
              .border({ width: { bottom: 1 }, color: '#F0F6F3' })

              Row() {
                Column({ space: 2 }) {
                  Text('振动反馈')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('手势确认时轻微震动')
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.vibrationEnabled })
                  .selectedColor('#10B981')
                  .height(28)
                  .onChange((isOn: boolean) => {
                    this.vibrationEnabled = isOn;
                    GestureService.getInstance().setVibrationEnabled(isOn);
                  })
              }
              .width('100%')
              .padding(14)
              .border({ width: { bottom: 1 }, color: '#F0F6F3' })

              Row() {
                Column({ space: 2 }) {
                  Text('口袋防误触')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('距离传感器检测遮挡')
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.pocketProtectionEnabled })
                  .selectedColor('#10B981')
                  .height(28)
                  .onChange((isOn: boolean) => {
                    this.pocketProtectionEnabled = isOn;
                    GestureService.getInstance().setPocketProtection(isOn);
                  })
              }
              .width('100%')
              .padding(14)
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#E2ECE7' })
            .borderRadius(16)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 5. API Key 与网络高级设置卡片
          Column({ space: 10 }) {
            Text('云端及服务凭证')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#8AA09A')
              .margin({ left: 4 })

            Column({ space: 10 }) {
              Text('后端 BaseURL:')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182925')

              TextInput({ text: this.backendUrl, placeholder: 'http://192.168.x.x:8000' })
                .height(48)
                .fontSize(14)
                .backgroundColor('#F6FAF8')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(10)
                .onChange((v: string) => { this.backendUrl = v; })

              Text('LLM API Key:')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182925')

              TextInput({ text: this.llmKey, placeholder: this.hasSavedLlm ? `已保存 (${this.llmKeyHint})` : 'sk-xxx' })
                .height(48)
                .fontSize(14)
                .type(InputType.Password)
                .backgroundColor('#F6FAF8')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(10)
                .onChange((v: string) => { this.llmKey = v; })

              Row({ space: 12 }) {
                Button(this.saving ? '保存中...' : '保存配置')
                  .layoutWeight(1)
                  .height(44)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#10B981')
                  .borderRadius(12)
                  .onClick(() => this.saveKeys())

                Button('清除凭证')
                  .width(100)
                  .height(44)
                  .fontSize(14)
                  .fontColor('#C2334C')
                  .backgroundColor('#FDEEF1')
                  .border({ width: 1, color: '#F8CCD5' })
                  .borderRadius(12)
                  .onClick(() => this.deleteKeys())
              }
              .margin({ top: 4 })

              if (this.statusText.length > 0) {
                Text(this.statusText)
                  .fontSize(12)
                  .fontColor('#04785C')
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#E2ECE7' })
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 6. 底部合规管理与官方声明（工信部与华为应用市场规范）
          Column({ space: 8 }) {
            // 撤回隐私协议授权按钮（华为审核对个人信息控制权的硬性要求）
            Button('撤回隐私政策授权并退出')
              .fontSize(12)
              .fontColor('#DC2626')
              .backgroundColor('#FEE2E2')
              .height(32)
              .borderRadius(8)
              .onClick(async () => {
                await AppConfig.getInstance().withdrawPrivacyAgreement();
                AccessibilityUtils.getInstance().speak('已撤销隐私授权，再次启动将重新请求');
                const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                ctx.terminateSelf();
              })
              .accessibilityText('撤回隐私政策授权并退出应用')

            // 底部协议与声明链接（必须真实可点开查看）
            Row({ space: 8 }) {
              Text('光语助手 v1.0.0')
                .fontSize(12)
                .fontColor('#8AA09A')
              Text('·')
                .fontSize(12)
                .fontColor('#8AA09A')
              Text('免责声明')
                .fontSize(12)
                .fontColor('#0D9488')
                .onClick(() => {
                  this.showDisclaimerModal = true;
                })
                .accessibilityText('点击查看免责与健康声明')
              Text('·')
                .fontSize(12)
                .fontColor('#8AA09A')
              Text('隐私政策')
                .fontSize(12)
                .fontColor('#0D9488')
                .onClick(() => {
                  this.showPrivacyModal = true;
                })
                .accessibilityText('点击查看隐私保护政策')
              Text('·')
                .fontSize(12)
                .fontColor('#8AA09A')
              Text('AI合规与举报')
                .fontSize(12)
                .fontColor('#0D9488')
                .onClick(() => {
                  this.showAiNoticeModal = true;
                })
                .accessibilityText('点击查看生成式AI合规与不良信息举报')
            }
            .justifyContent(FlexAlign.Center)
            .margin({ top: 6 })

            // 工信部 APP 备案号展示（华为应用市场审核与工信部强制要求）
            Text(`工信部备案：${this.miitIcpText}`)
              .fontSize(11)
              .fontColor('#9CA3AF')
              .margin({ top: 4, bottom: 20 })
              .onClick(() => {
                AccessibilityUtils.getInstance().speak(`工信部备案号：${this.miitIcpText}`);
              })
              .accessibilityText(`工信部APP备案号 ${this.miitIcpText}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 8, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#EEF6F1')

    // 隐私政策弹窗
    if (this.showPrivacyModal) {
      Stack() {
        Rect().width('100%').height('100%').fill('rgba(0,0,0,0.7)')
        Column() {
          Text('隐私保护政策')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F2937')
            .margin({ bottom: 12 })
          Scroll() {
            Column({ space: 10 }) {
              Text('光语助手（LuminaAssist）极为重视用户的隐私安全。我们承诺：\n\n' +
                '1. 权限最小化：相机与麦克风仅在用户主动发起识别或对话时动态调用，用完即释；\n\n' +
                '2. 数据脱敏处理：本地内置脱敏模块，主动过滤身份证、银行卡等连续数字，防止敏感信息上传；\n\n' +
                '3. 图片与语音安全：拍摄的画面与语音仅用于实时 AI 分析，云端不持久化存储任何用户面部特征与私密通讯录；\n\n' +
                '4. 撤回授权权利：您可随时在设置中点击“撤回隐私政策授权”，撤回后本应用停止一切非必要本地处理并退出。')
                .fontSize(14)
                .fontColor('#374151')
                .lineHeight(20)
            }
          }
          .height(260)
          .margin({ bottom: 16 })

          Button('关闭')
            .width('100%')
            .height(48)
            .backgroundColor('#10B981')
            .fontColor('#FFFFFF')
            .fontSize(16)
            .borderRadius(12)
            .onClick(() => {
              this.showPrivacyModal = false;
            })
        }
        .width('88%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .zIndex(999)
    }

    // 免责声明弹窗
    if (this.showDisclaimerModal) {
      Stack() {
        Rect().width('100%').height('100%').fill('rgba(0,0,0,0.7)')
        Column() {
          Text('免责与健康声明')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F2937')
            .margin({ bottom: 12 })
          Scroll() {
            Column({ space: 10 }) {
              Text('1. 光语助手是一款面向视障群体及高龄长者的生活无障碍辅助工具。\n\n' +
                '2. 药品识别、说明书播报及物品描述功能均基于端云大模型与计算机视觉算法，受光照、拍摄角度、包装磨损等客观因素影响，可能存在识别偏差或错漏。\n\n' +
                '3. 本软件识别结果仅作为生活便利辅助参考，绝不构成任何医学诊断、用药指导或医疗处方。用药前请务必核对物理包装上的药品名称、批号、剂量，或由家属及专业医疗人员核验后使用。\n\n' +
                '4. 紧急求助功能仅提供预设拨号与短信能力，无法替代 110、120 等法定公共紧急救援系统。')
                .fontSize(14)
                .fontColor('#374151')
                .lineHeight(20)
            }
          }
          .height(260)
          .margin({ bottom: 16 })

          Button('我知道了')
            .width('100%')
            .height(48)
            .backgroundColor('#10B981')
            .fontColor('#FFFFFF')
            .fontSize(16)
            .borderRadius(12)
            .onClick(() => {
              this.showDisclaimerModal = false;
            })
        }
        .width('88%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .zIndex(999)
    }

    // AI 合规与举报弹窗
    if (this.showAiNoticeModal) {
      Stack() {
        Rect().width('100%').height('100%').fill('rgba(0,0,0,0.7)')
        Column() {
          Text('AI合规与不良信息举报')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F2937')
            .margin({ bottom: 12 })
          Scroll() {
            Column({ space: 10 }) {
              Text('1. 生成式 AI 服务说明：\n本应用视觉理解与多任务编排能力由多模态大语言模型提供支持，严格遵循《生成式人工智能服务管理暂行办法》。AI生成内容具有一定概率的幻觉与不确定性，请用户谨慎甄别。\n\n' +
                '2. 有害与不良信息防范：\n我们部署了多级输入输出敏感词与合规过滤机制，禁止生成涉黄、涉暴、侵权或违背公序良俗的内容。\n\n' +
                '3. 用户举报与纠错通道：\n若您在使用过程中发现任何违法、侵权、事实错误或不当内容，请随时通过以下方式向我们举报：\n\n' +
                '客服与合规监督邮箱：\nfeedback@lumina.assist\n\n' +
                '我们将在 24 小时内进行人工复核并予以处置。')
                .fontSize(14)
                .fontColor('#374151')
                .lineHeight(20)
            }
          }
          .height(260)
          .margin({ bottom: 16 })

          Button('关闭')
            .width('100%')
            .height(48)
            .backgroundColor('#10B981')
            .fontColor('#FFFFFF')
            .fontSize(16)
            .borderRadius(12)
            .onClick(() => {
              this.showAiNoticeModal = false;
            })
        }
        .width('88%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .zIndex(999)
    }
  }
}
