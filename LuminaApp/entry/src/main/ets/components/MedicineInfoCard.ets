/**
 * @file MedicineInfoCard.ets
 * @module components
 * @description 药品识别结果卡片（对齐原型图 Screen 03）：包含结构化用药信息、红色高风险独立卡片、免责声明。
 */

import { MedicineInfo } from '../agent/types';

@Component
struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop tagBg: string = '#E5F5F3';
  @Prop tagColor: string = '#0F766E';

  build() {
    if (this.value.length > 0) {
      Row({ space: 12 }) {
        // 图标 / 标签位
        Text(this.label)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.tagColor)
          .backgroundColor(this.tagBg)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .flexShrink(0)

        // 详细描述
        Text(this.value)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#182925')
          .lineHeight(26)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .border({ width: { bottom: 1 }, color: '#E2ECE7', style: BorderStyle.Dashed })
      .alignItems(VerticalAlign.Top)
    }
  }
}

@Component
export struct MedicineInfoCard {
  @Prop medicineName: string = '';
  @Prop info: MedicineInfo | null = null;
  /** 追问提示回调 */
  onAskClick?: (question: string) => void;

  build() {
    Column({ space: 14 }) {
      // 1. 结果标题与置信度
      Row() {
        Row({ space: 8 }) {
          Row()
            .width(6)
            .height(18)
            .borderRadius(3)
            .backgroundColor('#10B981')
          Text('识别结果')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182925')
        }

        Row({ space: 4 }) {
          Text('置信度 96%')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#04785C')
        }
        .backgroundColor('#E6F8F1')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(12)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)

      // 2. 药品概览主卡
      Row({ space: 14 }) {
        Stack() {
          Text('药')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#059669')
        }
        .width(68)
        .height(68)
        .borderRadius(16)
        .backgroundColor('#E6F8F1')
        .border({ width: 1, color: '#BFE9D8' })

        Column({ space: 4 }) {
          Text(this.medicineName.length > 0 ? this.medicineName : '药品包装')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182925')

          if (this.info?.specification) {
            Text(this.info.specification)
              .fontSize(13)
              .fontColor('#48605A')
          }

          Row({ space: 6 }) {
            Text('正规识别')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#04785C')
              .backgroundColor('#E6F8F1')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#E2ECE7' })
      .borderRadius(16)
      .alignItems(VerticalAlign.Center)

      if (this.info !== null) {
        // 3. 结构化信息列表
        Column() {
          InfoRow({ label: '适应症', value: this.info.indications ?? '', tagBg: '#E5F5F3', tagColor: '#0F766E' })
          InfoRow({ label: '用法用量', value: this.info.dosage ?? '未读取到明确用量，请详阅说明书', tagBg: '#E6F8F1', tagColor: '#059669' })
          InfoRow({ label: '注意事项', value: this.info.contraindications ?? '', tagBg: '#FFF6E5', tagColor: '#8A6100' })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E2ECE7' })
        .borderRadius(16)

        // 4. 高风险提醒卡片（独立红色强提醒）
        if (this.info.riskHint || this.info.contraindications) {
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text('⚠️')
                .fontSize(16)
              Text('高风险提醒 · 请特别注意')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#C2334C')
            }
            .width('100%')

            Text(this.info.riskHint ? this.info.riskHint : (this.info.contraindications ?? ''))
              .fontSize(15)
              .fontColor('#8F2F42')
              .lineHeight(24)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FDEEF1')
          .border({ width: 1, color: '#F8CCD5' })
          .borderRadius(16)
          .alignItems(HorizontalAlign.Start)
        }
      }

      // 5. 免责声明
      Row({ space: 8 }) {
        Text('ℹ️')
          .fontSize(14)
        Text('识别结果仅供参考，不能替代医生诊断与药品说明书。')
          .fontSize(13)
          .fontColor('#0F766E')
          .lineHeight(20)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#E5F5F3')
      .border({ width: 1, color: '#C9ECE8' })
      .borderRadius(12)
      .alignItems(VerticalAlign.Center)

      // 6. 快捷追问 Chip
      Row({ space: 8 }) {
        Text('快捷提问：')
          .fontSize(12)
          .fontColor('#48605A')
          .flexShrink(0)

        Scroll() {
          Row({ space: 8 }) {
            Button('饭前还是饭后吃？')
              .fontSize(12)
              .fontColor('#0F766E')
              .backgroundColor('#E5F5F3')
              .height(30)
              .borderRadius(15)
              .onClick(() => {
                if (this.onAskClick) {
                  this.onAskClick('这个药是饭前吃还是饭后吃？');
                }
              })

            Button('漏服了一次怎么办？')
              .fontSize(12)
              .fontColor('#0F766E')
              .backgroundColor('#E5F5F3')
              .height(30)
              .borderRadius(15)
              .onClick(() => {
                if (this.onAskClick) {
                  this.onAskClick('如果漏服了一次怎么办？');
                }
              })
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
