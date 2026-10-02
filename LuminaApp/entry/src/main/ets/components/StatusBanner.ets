/**
 * @file StatusBanner.ets
 * @module components
 * @description 高对比浅色薄荷绿风格顶部状态条：提供四色呼吸灯指示与无障碍播报。
 */

@Component
export struct StatusBanner {
  /** 短状态文本 */
  @Prop text: string = '就绪';
  /** 状态等级：idle | listening | thinking | speaking | error */
  @Prop level: string = 'idle';
  /** 云端是否在线 */
  @Prop isOnline: boolean = true;

  private getStatusColor(): string {
    switch (this.level) {
      case 'listening':
        return '#0EA5A4'; // 聆听青
      case 'thinking':
        return '#F59E0B'; // 思考橙
      case 'speaking':
        return '#22C55E'; // 播报绿
      case 'error':
        return '#F0546C'; // 出错红
      default:
        return '#0D9488'; // 默认青碧主色
    }
  }

  private getStatusBgColor(): string {
    switch (this.level) {
      case 'listening':
        return '#E4F6F4';
      case 'thinking':
        return '#FFF6E5';
      case 'speaking':
        return '#EAFAF0';
      case 'error':
        return '#FDEEF1';
      default:
        return '#E5F5F3';
    }
  }

  private getStatusLabel(): string {
    switch (this.level) {
      case 'listening':
        return '正在聆听';
      case 'thinking':
        return '思考分析';
      case 'speaking':
        return '语音播报';
      case 'error':
        return '异常提醒';
      default:
        return '设备就绪';
    }
  }

  build() {
    Row({ space: 10 }) {
      // 状态指示灯（呼吸发光效果）
      Stack() {
        Row()
          .width(18)
          .height(18)
          .borderRadius(9)
          .backgroundColor(this.getStatusColor())
          .opacity(0.3)

        Row()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(this.getStatusColor())
      }
      .width(18)
      .height(18)
      .alignContent(Alignment.Center)

      // 状态标签
      Text(this.getStatusLabel())
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.getStatusColor())
        .backgroundColor(this.getStatusBgColor())
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(8)

      // 状态详细文案
      Text(this.text)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182925')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 云端在线/离线胶囊提示
      Row({ space: 4 }) {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.isOnline ? '#059669' : '#D97706')

        Text(this.isOnline ? '云端在线' : '离线模式')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isOnline ? '#04785C' : '#B45309')
      }
      .backgroundColor(this.isOnline ? '#E6F8F1' : '#FFF6E5')
      .border({ width: 1, color: this.isOnline ? '#BFE9D8' : '#FDE68A' })
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(12)
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E2ECE7' })
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .accessibilityText(`状态：${this.getStatusLabel()}。${this.text}。${this.isOnline ? '已连接云端' : '已进入离线模式'}`)
  }
}
