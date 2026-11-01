/**
 * 模型更新提示条：可用版本、下载进度与失败重试。无更新或未接入时不渲染。
 */
const CARD_WHITE: string = '#FFFFFF';
const TEXT_PRIMARY: string = '#1F2430';
const TEXT_SECONDARY: string = '#6B7280';
const ACCENT: string = '#2E6BE6';

@Component
export struct ModelUpdateBanner {
  /** idle/checking/available/downloading/installed/failed */
  @Prop phase: string = 'idle';
  @Prop version: string = '';
  @Prop reasonText: string = '';
  @Prop sizeText: string = '';
  /** 0..1 */
  @Prop progress: number = 0;
  @Prop message: string = '';
  onInstall: () => void = () => {
  };

  private percent(): number {
    const value: number = this.progress * 100;
    return value < 0 ? 0 : (value > 100 ? 100 : Math.round(value));
  }

  build() {
    if (this.phase === 'available' || this.phase === 'downloading' ||
      this.phase === 'installed' || this.phase === 'failed') {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('模型更新')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
          Text(this.phase === 'available' ? `v${this.version}` : '')
            .fontSize(11)
            .fontColor(ACCENT)
            .layoutWeight(1)
          if (this.phase === 'available') {
            Button('立即更新')
              .fontSize(11)
              .height(28)
              .padding({ left: 12, right: 12 })
              .backgroundColor(ACCENT)
              .fontColor('#FFFFFF')
              .onClick(() => this.onInstall())
          }
        }
        .width('100%')

        if (this.phase === 'available') {
          Text(`${this.reasonText}${this.sizeText.length > 0 ? ` · ${this.sizeText}` : ''}；` +
            '下载完成后自动重新加载，旧模型在新模型校验通过前仍可使用。')
            .fontSize(10)
            .fontColor(TEXT_SECONDARY)
            .width('100%')
            .lineHeight(15)
        }

        if (this.phase === 'downloading') {
          Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
            .color(ACCENT)
          Text(`正在下载模型 ${this.percent()}% · 完成后自动重新加载`)
            .fontSize(10)
            .fontColor(TEXT_SECONDARY)
            .width('100%')
        }

        if (this.phase === 'installed' || this.phase === 'failed') {
          Row({ space: 8 }) {
            Text(this.message)
              .fontSize(11)
              .fontColor(this.phase === 'failed' ? '#B45309' : '#1D9E6C')
              .layoutWeight(1)
              .lineHeight(16)
            if (this.phase === 'failed') {
              Button('重试')
                .fontSize(11)
                .height(28)
                .padding({ left: 10, right: 10 })
                .backgroundColor('#FFFFFF')
                .fontColor(ACCENT)
                .border({ width: 1, color: '#C7D7FA' })
                .onClick(() => this.onInstall())
            }
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .backgroundColor(CARD_WHITE)
      .alignItems(HorizontalAlign.Start)
    }
  }
}
