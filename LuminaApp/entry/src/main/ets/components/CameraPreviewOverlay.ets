/**
 * @file CameraPreviewOverlay.ets
 * @module components
 * @description 相机实时预览浮层：拍摄时同步显示画面，支持手动拍摄与取消。
 * 预览 Surface 按相机流宽高比 Contain 适配，避免拉伸，并与拍照画幅一致。
 */

@Component
export struct CameraPreviewOverlay {
  /** 提示文案 */
  @Prop hintText: string = '请将药盒对准画面中央';
  /** 是否显示“立即拍摄”按钮（预热完成后由父组件控制） */
  @Prop showCaptureButton: boolean = false;
  /**
   * 相机预览流宽高比（传感器坐标系 width/height，通常 > 1）。
   * 为 0 时暂按全屏铺满，拿到真实比例后再校正。
   */
  @Prop @Watch('onPreviewAspectChanged') previewAspectRatio: number = 0;
  /** Surface 就绪回调 */
  onSurfaceReady: (surfaceId: string) => void = (_surfaceId: string): void => {};
  /** 用户点击立即拍摄 */
  onCaptureTap: () => void = (): void => {};
  /** 用户取消拍摄 */
  onCancel: () => void = (): void => {};

  @State xComponentWidth: number | string = '100%';
  @State xComponentHeight: number | string = '100%';
  private xComponentController: XComponentController = new XComponentController();
  private surfaceReported: boolean = false;
  private containerWidthPx: number = 0;
  private containerHeightPx: number = 0;

  aboutToAppear(): void {
    this.surfaceReported = false;
  }

  private onPreviewAspectChanged(): void {
    this.applySurfaceRect();
  }

  /**
   * Contain 适配：完整显示预览流且不拉伸，黑边 letterbox。
   * 保证取景所见与拍照画幅一致（所见即所拍）。
   * onAreaChange 给出的是 vp，SurfaceRect 需要 px。
   */
  private applySurfaceRect(): void {
    if (this.containerWidthPx <= 0 || this.containerHeightPx <= 0) {
      return;
    }
    if (this.previewAspectRatio <= 0) {
      this.xComponentWidth = '100%';
      this.xComponentHeight = '100%';
      this.setSurfaceRect(this.containerWidthPx, this.containerHeightPx);
      return;
    }

    // 竖屏所见宽高比 = 短边/长边 = 1 / (传感器 width/height)
    const displayAspect: number = 1 / this.previewAspectRatio;
    const containerAspect: number = this.containerWidthPx / this.containerHeightPx;
    let drawWidth: number = this.containerWidthPx;
    let drawHeight: number = this.containerHeightPx;

    if (displayAspect >= containerAspect) {
      // 画面相对更宽：按宽度适配
      drawWidth = this.containerWidthPx;
      drawHeight = drawWidth / displayAspect;
    } else {
      // 画面相对更高：按高度适配
      drawHeight = this.containerHeightPx;
      drawWidth = drawHeight * displayAspect;
    }

    // 直接改变 XComponent 的组件尺寸，以避免在某些设备上 setSurfaceRect 拉伸
    this.xComponentWidth = this.getUIContext().px2vp(drawWidth);
    this.xComponentHeight = this.getUIContext().px2vp(drawHeight);
    
    // 依然设置 SurfaceRect 保证 buffer 大小与组件一致
    this.setSurfaceRect(drawWidth, drawHeight, 0, 0);
  }

  /** 取景框宽高比：竖屏构图参考，限制在合理范围以免撑破布局。 */
  private guideAspectRatio(): number {
    let ratio: number = 3 / 4;
    if (this.previewAspectRatio > 0) {
      ratio = 1 / this.previewAspectRatio;
    }
    if (ratio < 0.55) {
      return 0.55;
    }
    if (ratio > 0.85) {
      return 0.85;
    }
    return ratio;
  }

  private setSurfaceRect(width: number, height: number, offsetX: number = 0, offsetY: number = 0): void {
    const rect: SurfaceRect = {
      surfaceWidth: width,
      surfaceHeight: height,
      offsetX: offsetX,
      offsetY: offsetY
    };
    this.xComponentController.setXComponentSurfaceRect(rect);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 实时相机画面容器
      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'luminaCameraPreview',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .width(this.xComponentWidth)
          .height(this.xComponentHeight)
          .onLoad((): void => {
            if (this.surfaceReported) {
              return;
            }
            const surfaceId: string = this.xComponentController.getXComponentSurfaceId();
            if (surfaceId.length > 0) {
              this.surfaceReported = true;
              this.applySurfaceRect();
              this.onSurfaceReady(surfaceId);
            }
          })
          .accessibilityText('相机实时预览')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .onAreaChange((_oldVal: Area, newVal: Area): void => {
        // Area 为 vp，SurfaceRect 需要 px
        const w: number = this.getUIContext().vp2px(Number(newVal.width));
        const h: number = this.getUIContext().vp2px(Number(newVal.height));
        if (w > 0 && h > 0 &&
          (Math.abs(w - this.containerWidthPx) > 0.5 || Math.abs(h - this.containerHeightPx) > 0.5)) {
          this.containerWidthPx = w;
          this.containerHeightPx = h;
          this.applySurfaceRect();
        }
      })

      // 取景辅助框（比例与预览一致，仅作构图参考）
      Column() {
        Blank()
          .layoutWeight(1)
        Row() {
          Blank()
            .layoutWeight(1)
          Column()
            .width('72%')
            .aspectRatio(this.guideAspectRatio())
            .border({ width: 2, color: '#E5A93C' })
            .borderRadius(16)
            .backgroundColor('#00000000')
          Blank()
            .layoutWeight(1)
        }
        .width('100%')
        Blank()
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // 顶部取消
      Row() {
        Button('取消')
          .height(40)
          .fontSize(15)
          .fontColor('#F5F5F7')
          .backgroundColor('#66000000')
          .border({ width: 1, color: '#44FFFFFF' })
          .borderRadius(20)
          .padding({ left: 18, right: 18 })
          .onClick((): void => {
            this.onCancel();
          })
          .accessibilityText('取消拍摄')
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 48 })

      // 底部提示与拍摄按钮
      Column({ space: 12 }) {
        Text(this.hintText)
          .fontSize(16)
          .fontColor('#F5F5F7')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 24, right: 24 })

        if (this.showCaptureButton) {
          Button('立即拍摄')
            .width('70%')
            .height(52)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0A0A0C')
            .backgroundColor('#E5A93C')
            .borderRadius(26)
            .onClick((): void => {
              this.onCaptureTap();
            })
            .accessibilityText('立即拍摄')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 36 })
      .backgroundColor('#99000000')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
