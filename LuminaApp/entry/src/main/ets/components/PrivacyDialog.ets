/**
 * @file PrivacyDialog.ets
 * @module components
 * @description 首次启动《用户服务协议》与《隐私保护政策》合规授权弹窗。
 *
 * 依据工信部与华为应用市场（AppGallery）审核规范设计：
 * 1. 首次打开必须弹窗提示，用户未同意前严禁申请敏感权限与搜集个人信息；
 * 2. 具备无障碍读屏与高对比度设计，保障视障与银发群体可用；
 * 3. 明确提示麦克风/相机仅在主动触发时按需申请；
 * 4. 明确包含生成式 AI 辅助识别免责声明；
 * 5. 支持展开查看完整协议内容，并提供“同意并继续”与“不同意并退出”选项。
 */

@Component
export struct PrivacyDialog {
  @Prop isVisible: boolean = false;
  @State showFullText: boolean = false;
  onAgree: () => void = () => {};
  onDisagree: () => void = () => {};

  build() {
    if (this.isVisible) {
      Stack() {
        // 半透明深色遮罩
        Rect()
          .width('100%')
          .height('100%')
          .fill('rgba(0, 0, 0, 0.75)')

        // 居中授权卡片
        Column() {
          // 标题
          Text('欢迎使用光语助手')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1F2937')
            .margin({ top: 8, bottom: 12 })
            .accessibilityText('欢迎使用光语助手，请阅读用户协议与隐私保护指引')

          // 核心说明滚动区域
          Scroll() {
            Column({ space: 10 }) {
              if (!this.showFullText) {
                Text('光语助手（LuminaAssist）致力于为视障人士与长者提供全语音、无障碍的智能生活辅助服务。在您开始使用前，请仔细阅读以下重点条款：')
                  .fontSize(14)
                  .fontColor('#4B5563')
                  .lineHeight(20)

                Text('1. 权限最小化与按需申请\n我们严格遵循国家合规标准。麦克风权限仅在您按下语音指令时按需申请；相机权限仅在您发起药品、物品识别时按需申请。绝不在后台隐蔽调用或收集您的个人信息。')
                  .fontSize(13)
                  .fontColor('#374151')
                  .lineHeight(19)

                Text('2. 数据保护与安全传输\n您拍摄的照片与语音指令仅用于实时 AI 分析与语音播报，本地严格执行身份证、银行卡等敏感数据脱敏过滤，保障您的个人隐私安全。')
                  .fontSize(13)
                  .fontColor('#374151')
                  .lineHeight(19)

                Text('3. AI内容生成与健康免责声明\n本应用的文字描述与药品识别由多模态大模型算法生成，仅作为日常辅助参考，不能替代执业医师或药师指导。用药前请务必确认实体药品外包装或在家人陪同下服用。')
                  .fontSize(13)
                  .fontColor('#D97706')
                  .lineHeight(19)

                // 查看完整协议按钮
                Row() {
                  Text('查看《用户协议与隐私政策全文》 >')
                    .fontSize(13)
                    .fontColor('#0D9488')
                    .fontWeight(FontWeight.Medium)
                    .onClick(() => {
                      this.showFullText = true;
                    })
                    .accessibilityText('点击查看用户协议与隐私政策全文')
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .margin({ top: 6 })
              } else {
                Text('【光语助手隐私保护与服务条款全文】')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#111827')

                Text('第一条 个人信息收集与使用\n1. 麦克风录音：用于离线/云端 ASR 语音识别与意图理解，用户释放语音按键后立即停止录音。\n2. 摄像头：用于实时拍照、文档朗读与药品 OCR，照片处理完毕后即时销毁，不存储人脸或生物特征。\n3. 本地存储：用于保存您的语音语速偏好及离线模式设置。\n\n第二条 第三方服务与大模型说明\n本应用视觉与问答引擎采用符合国家《生成式人工智能服务管理暂行办法》的大模型服务，所有传输均通过 HTTPS 安全加密。\n\n第三条 撤回授权与权利保障\n您可随时在“设置”页中撤回隐私协议授权或清除本地缓存配置。')
                  .fontSize(12)
                  .fontColor('#4B5563')
                  .lineHeight(18)

                Row() {
                  Text('< 返回简要条款')
                    .fontSize(13)
                    .fontColor('#0D9488')
                    .fontWeight(FontWeight.Medium)
                    .onClick(() => {
                      this.showFullText = false;
                    })
                    .accessibilityText('返回简要条款')
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .margin({ top: 6 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .height(240)
          .margin({ bottom: 16 })

          // 同意按钮（大热区，符合无障碍标准）
          Button('同意并继续使用')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#10B981')
            .width('100%')
            .height(52)
            .borderRadius(14)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.onAgree();
            })
            .accessibilityText('同意并继续使用光语助手')

          // 拒绝按钮
          Button('不同意并退出')
            .fontSize(15)
            .fontColor('#6B7280')
            .backgroundColor('#F3F4F6')
            .width('100%')
            .height(44)
            .borderRadius(12)
            .onClick(() => {
              this.onDisagree();
            })
            .accessibilityText('不同意并退出应用')
        }
        .width('88%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(20)
        .shadow({ radius: 24, color: 'rgba(0,0,0,0.25)', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .zIndex(9999)
    }
  }
}
