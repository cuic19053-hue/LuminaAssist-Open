/**
 * @file BigButton.ets
 * @module components
 * @description 极简风格大热区按钮组件：采用高级暗黑系配色，高对比度，无障碍友好。
 *
 * 设计目标：
 * - 触控热区 >= 96vp x 96vp（视障/高龄用户友好）；
 * - 高对比度（金底黑字，命中 WCAG AAA）；
 * - 点击有视觉+触觉反馈。
 *
 * 注意：属性名不可为 enabled，会与 CustomComponent 基类的 enabled() 方法冲突，
 * 因此使用 isEnabled 替代。
 */

@Component
export struct BigButton {
  /** 按钮文本 */
  @Prop text: string = '点击说话';
  /** 是否可用 */
  @Prop isEnabled: boolean = true;
  /** 点击回调 */
  onTap: () => void = () => {};

  build() {
    Button(this.text)
      .fontSize(24)
      .fontColor(this.isEnabled ? '#0A0A0C' : '#66666C')
      .fontWeight(FontWeight.Bold)
      .backgroundColor(this.isEnabled ? '#E5A93C' : '#1A1A1E')
      .border({
        width: this.isEnabled ? 0 : 1,
        color: '#2C2C35'
      })
      .width('80%')
      .height(96)
      .borderRadius(24)
      .enabled(this.isEnabled)
      .onClick(() => {
        this.onTap();
      })
      .accessibilityText(this.text)
      .accessibilityLevel('yes')
  }
}
