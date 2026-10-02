/**
 * @file DocumentReaderCard.ets
 * @module components
 * @description 文档朗读分段播报组件（对齐原型 Screen 05）。
 */

import { AccessibilityUtils } from '../utils/AccessibilityUtils';

@Component
export struct DocumentReaderCard {
  @Prop title: string = '识别文档';
  @Prop paragraphs: Array<string> = [];
  @State currentIndex: number = 0;
  @State isPlaying: boolean = false;
  @State playbackSpeed: number = 1.0;

  private speakCurrentParagraph(): void {
    if (this.paragraphs.length === 0 || this.currentIndex < 0 || this.currentIndex >= this.paragraphs.length) {
      return;
    }
    const text = this.paragraphs[this.currentIndex];
    this.isPlaying = true;
    AccessibilityUtils.getInstance().speak(text).catch(() => {});
  }

  private togglePlayPause(): void {
    this.isPlaying = !this.isPlaying;
    if (this.isPlaying) {
      this.speakCurrentParagraph();
    } else {
      AccessibilityUtils.getInstance().stopSpeak();
    }
  }

  private prevParagraph(): void {
    if (this.currentIndex > 0) {
      this.currentIndex--;
      this.speakCurrentParagraph();
    }
  }

  private nextParagraph(): void {
    if (this.currentIndex < this.paragraphs.length - 1) {
      this.currentIndex++;
      this.speakCurrentParagraph();
    }
  }

  private cycleSpeed(): void {
    if (this.playbackSpeed === 1.0) {
      this.playbackSpeed = 1.2;
    } else if (this.playbackSpeed === 1.2) {
      this.playbackSpeed = 0.8;
    } else {
      this.playbackSpeed = 1.0;
    }
    AccessibilityUtils.getInstance().speak(`语速调至 ${this.playbackSpeed} 倍`).catch(() => {});
  }

  build() {
    Column({ space: 12 }) {
      // 文档头部与语速切换
      Row() {
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182925')
          Text(`共 ${this.paragraphs.length} 段 · 智能分段朗读`)
            .fontSize(12)
            .fontColor('#8AA09A')
        }
        .alignItems(HorizontalAlign.Start)

        // 语速切换胶囊
        Button(`语速 ${this.playbackSpeed}×`)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0F766E')
          .backgroundColor('#E5F5F3')
          .border({ width: 1, color: '#C6E8E1' })
          .height(32)
          .borderRadius(16)
          .onClick(() => {
            this.cycleSpeed();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)

      // 段落纸张区域
      Column({ space: 10 }) {
        ForEach(this.paragraphs, (para: string, idx: number) => {
          Row() {
            // 当前段落左侧薄荷绿高亮条
            Row()
              .width(idx === this.currentIndex ? 4 : 0)
              .height('100%')
              .backgroundColor('#10B981')
              .margin({ right: idx === this.currentIndex ? 8 : 0 })

            Text(para)
              .fontSize(idx === this.currentIndex ? 16 : 14)
              .fontWeight(idx === this.currentIndex ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(idx === this.currentIndex ? '#182925' : '#8AA09A')
              .lineHeight(26)
              .layoutWeight(1)
          }
          .width('100%')
          .padding(idx === this.currentIndex ? 12 : 8)
          .backgroundColor(idx === this.currentIndex ? '#E6F8F1' : Color.Transparent)
          .borderRadius(10)
          .onClick(() => {
            this.currentIndex = idx;
            this.speakCurrentParagraph();
          })
        }, (para: string, idx: number) => `${idx}_${para.length}`)
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#E2ECE7' })
      .borderRadius(16)

      // 控制器与进度
      Column({ space: 8 }) {
        // 进度条
        Row() {
          Row()
            .width(`${Math.min(100, Math.round(((this.currentIndex + 1) / Math.max(1, this.paragraphs.length)) * 100))}%`)
            .height(6)
            .borderRadius(3)
            .backgroundColor('#10B981')
        }
        .width('100%')
        .height(6)
        .backgroundColor('#E2ECE7')
        .borderRadius(3)

        Row() {
          Text(`第 ${this.currentIndex + 1} / ${this.paragraphs.length} 段`)
            .fontSize(12)
            .fontColor('#8AA09A')

          Text(this.isPlaying ? '正在朗读中' : '暂停中')
            .fontSize(12)
            .fontColor('#0D9488')
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)

        // 三个超大操控按钮（58vp / 72vp）
        Row({ space: 20 }) {
          // 上一段
          Button('上一段')
            .width(64)
            .height(64)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182925')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#E2ECE7' })
            .borderRadius(32)
            .enabled(this.currentIndex > 0)
            .onClick(() => {
              this.prevParagraph();
            })

          // 播放/暂停（主按钮 72vp 青碧色）
          Button(this.isPlaying ? '暂停' : '播放')
            .width(72)
            .height(72)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#0D9488')
            .borderRadius(36)
            .onClick(() => {
              this.togglePlayPause();
            })

          // 下一段
          Button('下一段')
            .width(64)
            .height(64)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#182925')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#E2ECE7' })
            .borderRadius(32)
            .enabled(this.currentIndex < this.paragraphs.length - 1)
            .onClick(() => {
              this.nextParagraph();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8 })
      }
      .width('100%')
      .padding(12)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
