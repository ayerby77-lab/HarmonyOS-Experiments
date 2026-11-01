/**
 * 页面专用：检测结果清单，支持选中、修正类别和删除误检项。
 * 传入的 items 已是未删除项；删除项作为墓碑保留在页面状态中，由原始数量区分。
 */
import { EditableDetection } from './EditableDetection';
import { formatConfidence } from './BoxGeometry';

@Component
export struct DetectionList {
  @Prop items: EditableDetection[] = [];
  @Prop selectedId: number = -1;
  @Prop originalCount: number = 0;
  @Prop editedCount: number = 0;
  @Prop deletedCount: number = 0;
  /** 原始结果只读查看时隐藏编辑入口。 */
  @Prop readOnly: boolean = false;
  onSelect: (rawIndex: number) => void = () => {
  };
  onEditClass: (rawIndex: number) => void = () => {
  };
  onDelete: (rawIndex: number) => void = () => {
  };
  onRestore: () => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('检测明细')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1F2430')
        Text(`原始 ${this.originalCount} · 修正 ${this.editedCount} · 删除 ${this.deletedCount}`)
          .fontSize(11)
          .fontColor('#7A8089')
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      if (!this.readOnly && (this.editedCount > 0 || this.deletedCount > 0) && this.originalCount > 0) {
        Row() {
          Text('编辑只作用于页面副本；删除项保留墓碑，可恢复')
            .fontSize(10)
            .fontColor('#8A9099')
            .layoutWeight(1)
          Button('恢复原始结果')
            .fontSize(11)
            .height(26)
            .padding({ left: 8, right: 8 })
            .backgroundColor('#FFFFFF')
            .fontColor('#2E6BE6')
            .border({ width: 1, color: '#C7D7FA' })
            .onClick(() => this.onRestore())
        }
        .width('100%')
      }

      if (this.items.length === 0) {
        Text(this.originalCount === 0 ? '没有可编辑的检测项' :
          '当前所有检测项均已删除，可恢复原始结果')
          .fontSize(12)
          .fontColor('#8A9099')
          .width('100%')
          .padding({ top: 4, bottom: 4 })
      }

      ForEach(this.items, (item: EditableDetection) => {
        Row({ space: 8 }) {
          Text(`${item.rawIndex + 1}`)
            .fontSize(11)
            .fontColor(this.selectedId === item.rawIndex ? '#2E6BE6' : '#9AA1AC')
            .width(20)
            .textAlign(TextAlign.Center)

          Column({ space: 2 }) {
            Row({ space: 6 }) {
              Text(item.label)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1F2430')
              if (item.classId !== item.rawClassId) {
                Text(`原 ${item.rawLabel}`)
                  .fontSize(9)
                  .fontColor('#B45309')
                  .backgroundColor('#FFF1DC')
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              }
            }

            Text(`${formatConfidence(item.confidence)} · 置信度对应原始类别 · 框 ` +
              `${Math.round(item.left)},${Math.round(item.top)},` +
              `${Math.round(item.right)},${Math.round(item.bottom)}`)
              .fontSize(10)
              .fontColor('#8A9099')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .onClick(() => this.onSelect(item.rawIndex))

          if (!this.readOnly) {
            Button('改类')
              .fontSize(11)
              .height(28)
              .padding({ left: 8, right: 8 })
              .backgroundColor('#EEF2FB')
              .fontColor('#2E6BE6')
              .onClick(() => this.onEditClass(item.rawIndex))

            Button('删除')
              .fontSize(11)
              .height(28)
              .padding({ left: 8, right: 8 })
              .backgroundColor('#FCEDEC')
              .fontColor('#C53B32')
              .onClick(() => this.onDelete(item.rawIndex))
          }
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor(this.selectedId === item.rawIndex ? '#EAF0FE' : '#FFFFFF')
        .border({
          width: 1,
          color: this.selectedId === item.rawIndex ? '#B9CCF7' : '#EDEFF3'
        })
      }, (item: EditableDetection) => `${item.rawIndex}-${item.classId}`)
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }
}
