/**
 * 历史记录缩略图。按相对路径自行加载与释放 PixelMap，避免列表持有大量位图。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { loadRecordPixelMap } from './RecordImage';

@Component
export struct RecordThumb {
  @Prop relativePath: string = '';
  @Prop edge: number = 64;

  @State pixelMap: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  private active: boolean = true;

  aboutToAppear(): void {
    this.active = true;
    this.load();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.release();
  }

  private async load(): Promise<void> {
    if (this.relativePath.length === 0) {
      this.failed = true;
      return;
    }
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.failed = true;
      return;
    }
    try {
      const next: image.PixelMap = await loadRecordPixelMap(context, this.relativePath, this.edge * 2);
      if (!this.active) {
        next.release().catch(() => {
        });
        return;
      }
      const previous: image.PixelMap | undefined = this.pixelMap;
      this.pixelMap = next;
      this.failed = false;
      if (previous !== undefined) {
        previous.release().catch(() => {
        });
      }
    } catch (err) {
      if (this.active) {
        this.failed = true;
      }
    }
  }

  private release(): void {
    const pixelMap: image.PixelMap | undefined = this.pixelMap;
    this.pixelMap = undefined;
    if (pixelMap !== undefined) {
      pixelMap.release().catch(() => {
      });
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Text(this.failed ? '无图' : '…')
          .fontSize(11)
          .fontColor('#8A9099')
      }
    }
    .width(this.edge)
    .height(this.edge)
    .borderRadius(8)
    .backgroundColor('#F0F2F5')
    .clip(true)
  }
}
