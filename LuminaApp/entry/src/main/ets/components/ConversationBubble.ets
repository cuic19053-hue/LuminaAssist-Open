/**
 * @file ConversationBubble.ets
 * @module components
 * @description 对话气泡：用户消息简洁展示，助手回复结构化排版，适老适障友好。
 */

import { StructuredReplyCard } from './StructuredReplyCard';

@Component
export struct ConversationBubble {
  /** 角色：user / assistant */
  @Prop role: 'user' | 'assistant' = 'assistant';
  /** 文本内容（完整展示，不截断） */
  @Prop text: string = '';
  /** 可选：视觉识别预览图 base64（不含 data URL 前缀） */
  @Prop imageBase64: string = '';

  build() {
    Row() {
      if (this.role === 'assistant') {
        Column({ space: 10 }) {
          if (this.imageBase64.length > 0) {
            Image('data:image/jpeg;base64,' + this.imageBase64)
              .width('100%')
              .height(160)
              .objectFit(ImageFit.Contain)
              .borderRadius(12)
              .backgroundColor('#0A0A0C')
              .accessibilityText('识别对象预览图')
          }

          StructuredReplyCard({
            text: this.text,
            showAssistantBadge: false
          })
        }
        .padding(16)
        .backgroundColor('#1A1A1E')
        .border({ width: 1, color: '#2C2C35' })
        .borderRadius({
          topLeft: 16,
          topRight: 16,
          bottomLeft: 4,
          bottomRight: 16
        })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Blank()
          .width('8%')
      } else {
        Blank()
          .width('8%')

        Column({ space: 4 }) {
          Text('您的问题')
            .fontSize(12)
            .fontColor('#8E8E93')
            .width('100%')
            .textAlign(TextAlign.End)
          Text(this.text)
            .fontSize(18)
            .fontColor('#0A0A0C')
            .fontWeight(FontWeight.Medium)
            .lineHeight(28)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor('#E5A93C')
        .borderRadius({
          topLeft: 16,
          topRight: 16,
          bottomLeft: 16,
          bottomRight: 4
        })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }
}
