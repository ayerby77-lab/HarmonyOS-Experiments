/**
 * 识别历史详情页（Agent 3）。
 *
 * 优先展示 editedBoxes，可切换查看 rawBoxes；编辑（改类/删除）后立即调用
 * RecordService.updateEdited 持久化。删除记录时由 RecordService 级联清理图片。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { COCO_CLASSES } from '../models/ModelConstants';
import { DetectionBox } from '../models/DetectionTypes';
import { RecordDetail } from '../models/RecordTypes';
import { RecordService } from '../services/storage/RecordService';
import { RecognitionPreview } from '../components/recognition/RecognitionPreview';
import { DetectionList } from '../components/recognition/DetectionList';
import { ClassCountBar } from '../components/recognition/ClassCountBar';
import {
  activeDetections,
  applyClassChange,
  buildEditableDetections,
  countByClass,
  countDeleted,
  countEdited,
  EditableDetection,
  setDeleted,
  toModelBoxes
} from '../components/recognition/EditableDetection';
import { describeStorageError, formatExecutionMode, formatRecordTime, formatSource } from '../components/recognition/RecordFormat';
import { loadRecordPixelMap } from '../components/recognition/RecordImage';
import { formatMs } from '../components/recognition/BoxGeometry';

const PAGE_BACKGROUND: string = '#F4F5F7';
const CARD_WHITE: string = '#FFFFFF';
const TEXT_PRIMARY: string = '#1F2430';
const TEXT_SECONDARY: string = '#6B7280';
const ACCENT: string = '#2E6BE6';
const DETAIL_IMAGE_MAX_EDGE: number = 1600;

interface RecordDetailParams {
  recordId: string;
}

@Entry
@Component
struct RecordDetailPage {
  @State detail: RecordDetail | undefined = undefined;
  @State items: EditableDetection[] = [];
  @State selectedId: number = -1;
  @State viewRaw: boolean = false;
  @State loading: boolean = true;
  @State saving: boolean = false;
  @State deleting: boolean = false;
  @State errorText: string = '';
  @State pixelMap: image.PixelMap | undefined = undefined;
  @State previewPreparing: boolean = false;
  @State previewError: string = '';

  private recordId: string = '';
  private baseEditedBoxes: DetectionBox[] = [];
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    const params: RecordDetailParams = this.getUIContext().getRouter().getParams() as RecordDetailParams;
    if (params === undefined || params.recordId === undefined || params.recordId.length === 0) {
      this.loading = false;
      this.errorText = '缺少记录标识，请返回历史列表重新进入';
      return;
    }
    this.recordId = params.recordId;
    this.loadDetail();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.releasePixelMap();
  }

  private releasePixelMap(): void {
    const pixelMap: image.PixelMap | undefined = this.pixelMap;
    this.pixelMap = undefined;
    if (pixelMap !== undefined) {
      pixelMap.release().catch(() => {
      });
    }
  }

  private async loadDetail(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      const next: RecordDetail | null = await RecordService.getInstance().getDetail(this.recordId);
      if (!this.pageActive) {
        return;
      }
      if (next === null) {
        this.errorText = '记录不存在或已删除';
        return;
      }
      this.detail = next;
      this.baseEditedBoxes = next.editedBoxes.slice();
      this.viewRaw = false;
      this.items = buildEditableDetections(next.editedBoxes);
      this.selectedId = -1;
      this.loadOriginal(next);
    } catch (err) {
      if (this.pageActive) {
        this.errorText = describeStorageError(err as Object);
      }
    } finally {
      if (this.pageActive) {
        this.loading = false;
      }
    }
  }

  private async loadOriginal(detail: RecordDetail): Promise<void> {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.previewError = '无法访问应用沙箱，原图无法显示';
      return;
    }
    this.previewPreparing = true;
    this.previewError = '';
    try {
      const next: image.PixelMap = await loadRecordPixelMap(context, detail.imagePath, DETAIL_IMAGE_MAX_EDGE);
      if (!this.pageActive || this.detail === undefined || this.detail.recordId !== detail.recordId) {
        next.release().catch(() => {
        });
        return;
      }
      const previous: image.PixelMap | undefined = this.pixelMap;
      this.pixelMap = next;
      if (previous !== undefined) {
        previous.release().catch(() => {
        });
      }
    } catch (err) {
      if (this.pageActive) {
        this.previewError = '原图加载失败，仍可查看检测框';
      }
    } finally {
      if (this.pageActive) {
        this.previewPreparing = false;
      }
    }
  }

  private switchView(raw: boolean): void {
    if (this.viewRaw === raw || this.detail === undefined) {
      return;
    }
    this.viewRaw = raw;
    this.items = buildEditableDetections(raw ? this.detail.rawBoxes : this.detail.editedBoxes);
    this.selectedId = -1;
  }

  private async persistEdits(previous: EditableDetection[]): Promise<void> {
    if (this.viewRaw || this.detail === undefined) {
      return;
    }
    this.saving = true;
    try {
      const next: RecordDetail = await RecordService.getInstance()
        .updateEdited(this.detail.recordId, toModelBoxes(this.items));
      if (!this.pageActive) {
        return;
      }
      this.detail = next;
      this.errorText = '';
      this.notify('修改已保存');
    } catch (err) {
      if (!this.pageActive) {
        return;
      }
      this.items = previous;
      this.errorText = describeStorageError(err as Object);
      this.notify(this.errorText);
    } finally {
      if (this.pageActive) {
        this.saving = false;
      }
    }
  }

  private handleEditClass(rawIndex: number): void {
    if (this.viewRaw || this.detail === undefined) {
      this.notify('原始框仅供查看，切换到“编辑后框”再修改');
      return;
    }
    if (this.saving) {
      this.notify('正在保存上一条修改，请稍候');
      return;
    }
    const item: EditableDetection | undefined =
      this.items.find((entry: EditableDetection): boolean => entry.rawIndex === rawIndex);
    if (item === undefined) {
      return;
    }
    const previous: EditableDetection[] = this.items;
    this.getUIContext().showTextPickerDialog({
      range: COCO_CLASSES,
      selected: item.classId,
      onAccept: (value: TextPickerResult) => {
        if (this.viewRaw || this.detail === undefined) {
          return;
        }
        let index: number = item.classId;
        if (typeof value.index === 'number') {
          index = value.index;
        } else if (value.index.length > 0) {
          index = value.index[0];
        }
        this.items = applyClassChange(this.items, rawIndex, index);
        this.persistEdits(previous);
      }
    });
  }

  private handleDelete(rawIndex: number): void {
    if (this.viewRaw || this.detail === undefined) {
      this.notify('原始框仅供查看，切换到“编辑后框”再修改');
      return;
    }
    if (this.saving) {
      this.notify('正在保存上一条修改，请稍候');
      return;
    }
    const previous: EditableDetection[] = this.items;
    this.items = setDeleted(this.items, rawIndex, true);
    if (this.selectedId === rawIndex) {
      this.selectedId = -1;
    }
    this.persistEdits(previous);
  }

  private handleRestore(): void {
    if (this.viewRaw || this.detail === undefined || this.saving) {
      return;
    }
    const previous: EditableDetection[] = this.items;
    this.items = buildEditableDetections(this.baseEditedBoxes);
    this.selectedId = -1;
    this.persistEdits(previous);
  }

  private confirmDeleteRecord(): void {
    if (this.deleting || this.detail === undefined) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除记录',
      message: '将删除这条记录及其原图、缩略图，且不可恢复。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#C53B32',
        action: () => {
          this.deleteRecord();
        }
      }
    });
  }

  private async deleteRecord(): Promise<void> {
    if (this.deleting || this.detail === undefined) {
      return;
    }
    this.deleting = true;
    try {
      await RecordService.getInstance().delete(this.detail.recordId);
      if (!this.pageActive) {
        return;
      }
      this.notify('记录已删除');
      this.getUIContext().getRouter().back();
    } catch (err) {
      if (this.pageActive) {
        this.errorText = describeStorageError(err as Object);
        this.notify(this.errorText);
      }
    } finally {
      if (this.pageActive) {
        this.deleting = false;
      }
    }
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Toast 失败不影响主流程。
    }
  }

  private visibleItems(): EditableDetection[] {
    return activeDetections(this.items);
  }

  private metaText(): string {
    if (this.detail === undefined) {
      return '';
    }
    return `${formatRecordTime(this.detail.createdAtMs)} · ${formatSource(this.detail.source)} · ` +
      `${formatExecutionMode(this.detail.executionMode)} · ${formatMs(this.detail.totalMs)}`;
  }

  @Builder
  viewChip(label: string, raw: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(this.viewRaw === raw ? '#FFFFFF' : '#4A4F58')
      .backgroundColor(this.viewRaw === raw ? ACCENT : CARD_WHITE)
      .borderRadius(14)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .onClick(() => this.switchView(raw))
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Button('返回')
              .fontSize(12)
              .height(32)
              .backgroundColor('#E9ECF1')
              .fontColor(TEXT_PRIMARY)
              .borderRadius(8)
              .onClick(() => {
                this.getUIContext().getRouter().back();
              })
            Column({ space: 2 }) {
              Text('识别详情')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(TEXT_PRIMARY)
              Text(this.saving ? '正在保存修改…' : '本地记录')
                .fontSize(10)
                .fontColor(this.saving ? ACCENT : TEXT_SECONDARY)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button(this.deleting ? '删除中…' : '删除')
              .fontSize(12)
              .height(32)
              .backgroundColor('#FCEDEC')
              .fontColor('#C53B32')
              .borderRadius(8)
              .enabled(!this.deleting)
              .onClick(() => {
                this.confirmDeleteRecord();
              })
          }
          .width('100%')
          .padding({ top: 6 })

          if (this.loading) {
            Column({ space: 8 }) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(ACCENT)
              Text('正在读取记录…')
                .fontSize(12)
                .fontColor(TEXT_SECONDARY)
            }
            .width('100%')
            .padding({ top: 80, bottom: 80 })
            .justifyContent(FlexAlign.Center)
          } else if (this.detail === undefined) {
            Column({ space: 8 }) {
              Text(this.errorText.length > 0 ? this.errorText : '记录无法加载')
                .fontSize(14)
                .fontColor('#B45309')
                .textAlign(TextAlign.Center)
              Button('返回历史列表')
                .fontSize(12)
                .height(34)
                .backgroundColor(ACCENT)
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.getUIContext().getRouter().back();
                })
            }
            .width('100%')
            .padding({ top: 80 })
            .justifyContent(FlexAlign.Center)
          } else {
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(11)
                .fontColor('#B45309')
                .padding(10)
                .borderRadius(10)
                .backgroundColor('#FFF7E8')
                .width('100%')
            }

            Column({ space: 5 }) {
              Text(this.metaText())
                .fontSize(11)
                .fontColor(TEXT_SECONDARY)
                .width('100%')
              Text(`模型 ${this.detail.modelId} · 冷启动${this.detail.coldStart ? '是' : '否'} · ` +
                `${this.detail.imageWidth}×${this.detail.imageHeight}`)
                .fontSize(10)
                .fontColor('#9AA1AC')
                .width('100%')
            }
            .width('100%')
            .padding(10)
            .borderRadius(10)
            .backgroundColor(CARD_WHITE)
            .alignItems(HorizontalAlign.Start)

            Row({ space: 8 }) {
              this.viewChip('编辑后框', false)
              this.viewChip('原始框', true)
              Text(this.viewRaw ? '只读查看模型原始结果' : '修改立即写入本地记录')
                .fontSize(10)
                .fontColor(this.viewRaw ? '#B45309' : '#8A9099')
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')

            RecognitionPreview({
              pixelMap: $pixelMap,
              imageWidth: this.detail.imageWidth,
              imageHeight: this.detail.imageHeight,
              items: this.visibleItems(),
              selectedId: this.selectedId,
              preparing: this.previewPreparing,
              previewError: this.previewError,
              onSelect: (rawIndex: number) => {
                this.selectedId = rawIndex;
              }
            })

            ClassCountBar({
              counts: countByClass(this.items),
              total: this.visibleItems().length
            })

            DetectionList({
              items: this.visibleItems(),
              selectedId: this.selectedId,
              originalCount: this.viewRaw ? this.detail.rawBoxes.length : this.baseEditedBoxes.length,
              editedCount: this.viewRaw ? 0 : countEdited(this.items),
              deletedCount: this.viewRaw ? 0 : countDeleted(this.items),
              readOnly: this.viewRaw,
              onSelect: (rawIndex: number) => {
                this.selectedId = rawIndex;
              },
              onEditClass: (rawIndex: number) => {
                this.handleEditClass(rawIndex);
              },
              onDelete: (rawIndex: number) => {
                this.handleDelete(rawIndex);
              },
              onRestore: () => {
                this.handleRestore();
              }
            })

            Text('原始框来自模型输出，永不修改；编辑后框用于列表与后续统计。')
              .fontSize(10)
              .fontColor('#9AA1AC')
              .width('100%')
              .lineHeight(15)
              .padding({ top: 2, bottom: 16 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BACKGROUND)
  }
}
