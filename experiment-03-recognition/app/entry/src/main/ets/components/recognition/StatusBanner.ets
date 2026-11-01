/**
 * 页面专用：识别状态提示与恢复操作。
 */
import { RecognitionStatus } from '../../models/DetectionTypes';

@Component
export struct StatusBanner {
  @Prop status: RecognitionStatus = RecognitionStatus.IDLE;
  @Prop headline: string = '';
  @Prop description: string = '';
  @Prop detail: string = '';
  @Prop showInitializeAction: boolean = false;
  @Prop showPickAction: boolean = false;
  @Prop showRetryAction: boolean = false;
  @Prop actionBusy: boolean = false;
  onInitialize: () => void = () => {
  };
  onPickImage: () => void = () => {
  };
  onRetryRecognize: () => void = () => {
  };

  private accentColor(): string {
    if (this.status === RecognitionStatus.SUCCEEDED || this.status === RecognitionStatus.READY) {
      return '#1D9E6C';
    }
    if (this.status === RecognitionStatus.EMPTY) {
      return '#B87400';
    }
    if (this.status === RecognitionStatus.ERROR) {
      return '#C53B32';
    }
    if (this.status === RecognitionStatus.UNAVAILABLE) {
      return '#7A4BD0';
    }
    return '#2E6BE6';
  }

  private bannerColor(): string {
    if (this.status === RecognitionStatus.SUCCEEDED || this.status === RecognitionStatus.READY) {
      return '#ECF8F2';
    }
    if (this.status === RecognitionStatus.EMPTY) {
      return '#FFF6E5';
    }
    if (this.status === RecognitionStatus.ERROR) {
      return '#FCEDEC';
    }
    if (this.status === RecognitionStatus.UNAVAILABLE) {
      return '#F2EDFC';
    }
    return '#EDF3FE';
  }

  private isBusy(): boolean {
    return this.status === RecognitionStatus.INITIALIZING || this.status === RecognitionStatus.RUNNING;
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (this.isBusy()) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(this.accentColor())
        } else {
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.accentColor())
        }
        Text(this.headline)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentColor())
          .layoutWeight(1)
        if (this.actionBusy) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(this.accentColor())
        }
      }
      .width('100%')

      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(12)
          .fontColor('#4A4F58')
          .width('100%')
          .lineHeight(18)
      }

      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(11)
          .fontColor('#6B7280')
          .width('100%')
          .lineHeight(16)
      }

      if (this.showInitializeAction || this.showPickAction || this.showRetryAction) {
        Row({ space: 8 }) {
          if (this.showInitializeAction) {
            Button('重新加载模型')
              .fontSize(12)
              .height(30)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.accentColor())
              .fontColor('#FFFFFF')
              .enabled(!this.actionBusy)
              .onClick(() => this.onInitialize())
          }
          if (this.showPickAction) {
            Button('重新选图')
              .fontSize(12)
              .height(30)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#FFFFFF')
              .fontColor(this.accentColor())
              .border({ width: 1, color: this.accentColor() })
              .onClick(() => this.onPickImage())
          }
          if (this.showRetryAction) {
            Button('重试识别')
              .fontSize(12)
              .height(30)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.accentColor())
              .fontColor('#FFFFFF')
              .onClick(() => this.onRetryRecognize())
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(this.bannerColor())
    .alignItems(HorizontalAlign.Start)
  }
}
