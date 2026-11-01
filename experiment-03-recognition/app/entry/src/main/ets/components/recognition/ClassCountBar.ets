/**
 * 页面专用：按类别统计当前（编辑后）检测结果。
 */
import { ClassCount } from './EditableDetection';

@Component
export struct ClassCountBar {
  @Prop counts: ClassCount[] = [];
  @Prop total: number = 0;

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('分类统计')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1F2430')
        Text(`共 ${this.total} 项 · ${this.counts.length} 类`)
          .fontSize(11)
          .fontColor('#7A8089')
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      if (this.counts.length === 0) {
        Text('暂无统计')
          .fontSize(12)
          .fontColor('#8A9099')
          .width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.counts, (entry: ClassCount) => {
            Row({ space: 4 }) {
              Text(entry.label)
                .fontSize(12)
                .fontColor('#26303F')
              Text(`× ${entry.count}`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#2E6BE6')
            }
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor('#EEF2FB')
          }, (entry: ClassCount) => `${entry.classId}-${entry.count}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }
}
