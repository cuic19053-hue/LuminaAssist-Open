/**
 * @file StructuredReplyCard.ets
 * @module components
 * @description 结构化 AI 回复卡片：分区标题、重点警告、大字号，适老适障友好。
 */

import { MessageBlock, MessageContentParser } from '../utils/MessageContentParser';

/** 单行信息字段 */
@Component
struct InfoFieldRow {
  @Prop label: string = '';
  @Prop content: string = '';
  @Prop isWarning: boolean = false;

  build() {
    if (this.content.length > 0) {
      Column({ space: 6 }) {
        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isWarning ? '#FF6B6B' : '#E5A93C')
            .width('100%')
        }
        Text(this.content)
          .fontSize(18)
          .fontColor('#F5F5F7')
          .lineHeight(30)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding(this.isWarning ? 12 : 0)
      .backgroundColor(this.isWarning ? '#33FF6B6B' : Color.Transparent)
      .borderRadius(this.isWarning ? 10 : 0)
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 单个结构化块 */
@Component
struct MessageBlockView {
  @Prop block: MessageBlock = { type: 'paragraph', title: '', content: '' };

  build() {
    if (this.block.content.length > 0) {
      if (this.block.type === 'heading') {
        Column({ space: 4 }) {
          Text(this.block.title.length > 0 ? this.block.title : '回复摘要')
            .fontSize(14)
            .fontColor('#8E8E93')
          Text(this.block.content)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E5A93C')
            .lineHeight(32)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      } else if (this.block.type === 'warning') {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text('!')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor('#E85D5D')
              .borderRadius(11)
            Text(this.block.title.length > 0 ? this.block.title : '请注意')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FF8A8A')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.block.content)
            .fontSize(18)
            .fontColor('#FFECEC')
            .lineHeight(30)
            .width('100%')
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#2A1518')
        .border({ width: 1.5, color: '#E85D5D' })
        .borderRadius(12)
        .alignItems(HorizontalAlign.Start)
      } else if (this.block.type === 'tip') {
        Column({ space: 6 }) {
          Text(this.block.title.length > 0 ? this.block.title : '提示')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#7EB8FF')
          Text(this.block.content)
            .fontSize(17)
            .fontColor('#D6E8FF')
            .lineHeight(28)
            .width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#152030')
        .border({ width: 1, color: '#3A5F8A' })
        .borderRadius(12)
        .alignItems(HorizontalAlign.Start)
      } else if (this.block.type === 'section') {
        InfoFieldRow({
          label: this.block.title,
          content: this.block.content,
          isWarning: false
        })
      } else {
        Text(this.block.content)
          .fontSize(18)
          .fontColor('#F5F5F7')
          .lineHeight(30)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
  }
}

@Component
export struct StructuredReplyCard {
  @Prop text: string = '';
  @Prop showAssistantBadge: boolean = true;

  private getBlocks(): Array<MessageBlock> {
    return MessageContentParser.parse(this.text);
  }

  build() {
    Column({ space: 14 }) {
      if (this.showAssistantBadge) {
        Row({ space: 6 }) {
          Row()
            .width(4)
            .height(14)
            .borderRadius(2)
            .backgroundColor('#E5A93C')
          Text('助手回复')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#8E8E93')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      ForEach(this.getBlocks(), (block: MessageBlock, index: number) => {
        MessageBlockView({ block: block })
      }, (block: MessageBlock, index: number) =>
        `${index}_${block.type}_${block.title}_${block.content.length}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
