/**
 * 页面专用：图片预览与检测框叠加层。
 *
 * 检测框按 contain 布局映射，容器尺寸变化时重新计算，避免长图/横图留白偏移。
 * 静态图不再旋转或镜像（方向归一化由采集层完成）。
 */
import { image } from '@kit.ImageKit';
import { EditableDetection } from './EditableDetection';
import { ContainLayout, computeContainLayout, DisplayRect, formatConfidence, mapBoxToDisplay } from './BoxGeometry';

const BOX_COLORS: string[] = [
  '#2E6BE6', '#1D9E6C', '#D2542C', '#7A4BD0',
  '#0E8FA8', '#B87400', '#C2407A', '#4A6B8A'
];

@Component
export struct RecognitionPreview {
  @Link pixelMap: image.PixelMap | undefined;
  @Prop imageWidth: number = 0;
  @Prop imageHeight: number = 0;
  @Prop items: EditableDetection[] = [];
  @Prop selectedId: number = -1;
  @Prop preparing: boolean = false;
  @Prop previewError: string = '';
  onSelect: (id: number) => void = () => {
  };

  @State viewWidth: number = 0;
  @State viewHeight: number = 0;

  private layout(): ContainLayout {
    return computeContainLayout(this.imageWidth, this.imageHeight, this.viewWidth, this.viewHeight);
  }

  private rectOf(item: EditableDetection): DisplayRect {
    return mapBoxToDisplay(item.left, item.top, item.right, item.bottom, this.layout());
  }

  private strokeColor(item: EditableDetection): string {
    if (item.classId !== item.rawClassId) {
      return '#E8850C';
    }
    return BOX_COLORS[Math.abs(item.classId) % BOX_COLORS.length];
  }

  private hasImage(): boolean {
    return this.imageWidth > 0 && this.imageHeight > 0;
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopStart }) {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else if (this.hasImage() || this.preparing) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color('#2E6BE6')
          Text(this.preparing ? '正在准备预览…' : '预览不可用')
            .fontSize(12)
            .fontColor('#6B7280')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 6 }) {
          Text('尚未选择图片')
            .fontSize(14)
            .fontColor('#6B7280')
          Text('拍照或从相册选图后在此预览')
            .fontSize(11)
            .fontColor('#9AA1AC')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.pixelMap !== undefined && this.items.length > 0 && this.layout().valid) {
        ForEach(this.items, (item: EditableDetection) => {
          Column() {
            Text(`${item.label} ${formatConfidence(item.confidence)}`)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .backgroundColor(this.strokeColor(item))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
          .width(this.rectOf(item).width)
          .height(this.rectOf(item).height)
          .position({ x: this.rectOf(item).left, y: this.rectOf(item).top })
          .border({
            width: this.selectedId === item.rawIndex ? 3 : 1.5,
            color: this.strokeColor(item),
            radius: 4
          })
          .backgroundColor(this.selectedId === item.rawIndex ? '#1A2E6BE6' : Color.Transparent)
          .clip(true)
          .onClick(() => this.onSelect(item.rawIndex))
        }, (item: EditableDetection) => `${item.rawIndex}-${item.classId}`)
      }
      }
      .width('100%')
      .height(300)
      .borderRadius(12)
      .backgroundColor('#101318')
      .clip(true)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const width: number = Number(newValue.width);
        const height: number = Number(newValue.height);
        if (width !== this.viewWidth || height !== this.viewHeight) {
          this.viewWidth = width;
          this.viewHeight = height;
        }
      })

      if (this.previewError.length > 0) {
        Text(this.previewError)
          .fontSize(11)
          .fontColor('#B45309')
          .width('100%')
      }

      if (this.hasImage()) {
        Text(`${this.imageWidth} × ${this.imageHeight} 像素 · contain 显示`)
          .fontSize(11)
          .fontColor('#8A9099')
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
