/**
 * @file NetworkFallbackDialog.ets
 * @module components
 * @description 网络异常/网络较差时的无障碍抉择弹窗组件。
 *
 * 特性：
 * - 专门针对视障/高龄用户的无障碍设计（大字体、高对比度、双大热区按钮）；
 * - 结合语音播报与点击交互，提示用户在网络差时抉择“切换离线”或“重试云端”；
 */

@Component
export struct NetworkFallbackDialog {
  @Prop isVisible: boolean = false;
  @Prop reason: string = '当前网络较差，云端响应超时';
  onSelectOffline: () => void = () => {};
  onSelectRetryCloud: () => void = () => {};

  build() {
    if (this.isVisible) {
      Stack() {
        // 半透明遮罩层
        Rect()
          .width('100%')
          .height('100%')
          .fill('rgba(0, 0, 0, 0.75)')

        // 弹窗主卡片
        Column() {
          Text('网络服务提示')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .margin({ bottom: 12 })

          Text(this.reason + '。请选择处理方式：')
            .fontSize(16)
            .fontColor('#CCCCCC')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 24 })

          // 选项一：使用离线模型
          Button('使用端侧离线模型继续')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0A0A0C')
            .backgroundColor('#E5A93C')
            .width('100%')
            .height(64)
            .borderRadius(16)
            .margin({ bottom: 16 })
            .onClick(() => {
              this.onSelectOffline();
            })
            .accessibilityText('使用端侧离线模型继续')

          // 选项二：重试云端服务
          Button('重试云端服务')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#2C2C35')
            .width('100%')
            .height(56)
            .borderRadius(16)
            .onClick(() => {
              this.onSelectRetryCloud();
            })
            .accessibilityText('重试云端服务')
        }
        .width('85%')
        .padding(24)
        .backgroundColor('#16161A')
        .borderRadius(24)
        .border({ width: 1, color: '#33333F' })
      }
      .width('100%')
      .height('100%')
      .zIndex(999)
    }
  }
}
