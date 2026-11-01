/**
 * 识别历史列表页（Agent 3）。
 *
 * 数据来自 RecordService.list(page, pageSize, sourceFilter?)；缩略图按相对路径
 * 从应用沙箱加载。点击记录进入详情页。
 */
import { ImageOrigin } from '../models/ImageTypes';
import { RecordPage, RecordSummary } from '../models/RecordTypes';
import { RecordService } from '../services/storage/RecordService';
import { formatExecutionMode, formatRecordTime, formatSource, describeStorageError } from '../components/recognition/RecordFormat';
import { RecordThumb } from '../components/recognition/RecordThumb';
import { formatMs } from '../components/recognition/BoxGeometry';

const PAGE_SIZE: number = 20;
const PAGE_BACKGROUND: string = '#F4F5F7';
const CARD_WHITE: string = '#FFFFFF';
const TEXT_PRIMARY: string = '#1F2430';
const TEXT_SECONDARY: string = '#6B7280';
const ACCENT: string = '#2E6BE6';

interface FilterOption {
  label: string;
  value: ImageOrigin | undefined;
}

const FILTERS: FilterOption[] = [
  { label: '全部', value: undefined },
  { label: '相机', value: ImageOrigin.CAMERA },
  { label: '相册', value: ImageOrigin.GALLERY }
];

@Entry
@Component
struct RecordList {
  @State items: RecordSummary[] = [];
  @State page: number = 1;
  @State hasMore: boolean = false;
  @State loading: boolean = false;
  @State errorText: string = '';
  @State sourceFilter: ImageOrigin | undefined = undefined;

  private querySeq: number = 0;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    // 作废未完成的查询，避免返回时写回旧结果。
    this.querySeq += 1;
  }

  onPageShow(): void {
    this.pageActive = true;
    this.reload();
  }

  private async reload(): Promise<void> {
    this.querySeq += 1;
    const seq: number = this.querySeq;
    this.loading = true;
    this.errorText = '';
    try {
      const page: RecordPage = await RecordService.getInstance().list(1, PAGE_SIZE, this.sourceFilter);
      if (!this.pageActive || seq !== this.querySeq) {
        return;
      }
      this.items = page.items;
      this.page = page.page;
      this.hasMore = page.hasMore;
    } catch (err) {
      if (!this.pageActive || seq !== this.querySeq) {
        return;
      }
      this.items = [];
      this.hasMore = false;
      this.errorText = describeStorageError(err as Object);
    } finally {
      if (seq === this.querySeq) {
        this.loading = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || !this.hasMore) {
      return;
    }
    this.querySeq += 1;
    const seq: number = this.querySeq;
    this.loading = true;
    try {
      const next: RecordPage = await RecordService.getInstance().list(this.page + 1, PAGE_SIZE, this.sourceFilter);
      if (!this.pageActive || seq !== this.querySeq) {
        return;
      }
      this.items = this.items.concat(next.items);
      this.page = next.page;
      this.hasMore = next.hasMore;
    } catch (err) {
      if (this.pageActive && seq === this.querySeq) {
        this.errorText = describeStorageError(err as Object);
      }
    } finally {
      if (seq === this.querySeq) {
        this.loading = false;
      }
    }
  }

  private applyFilter(value: ImageOrigin | undefined): void {
    if (this.sourceFilter === value) {
      return;
    }
    this.sourceFilter = value;
    this.reload();
  }

  private openDetail(item: RecordSummary): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/RecordDetail',
      params: { recordId: item.recordId }
    }).catch(() => {
      this.notify('无法打开记录详情');
    });
  }

  private openCloudRecords(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/CloudRecords' }).catch(() => {
      this.notify('无法打开云端记录');
    });
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Toast 失败不影响主流程。
    }
  }

  @Builder
  filterChip(option: FilterOption) {
    Text(option.label)
      .fontSize(12)
      .fontColor(this.sourceFilter === option.value ? '#FFFFFF' : '#4A4F58')
      .backgroundColor(this.sourceFilter === option.value ? ACCENT : CARD_WHITE)
      .borderRadius(14)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .onClick(() => this.applyFilter(option.value))
  }

  @Builder
  recordRow(item: RecordSummary) {
    Row({ space: 12 }) {
      RecordThumb({ relativePath: item.thumbnailPath, edge: 64 })

      Column({ space: 5 }) {
        Row() {
          Text(formatRecordTime(item.createdAtMs))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
          Text(formatSource(item.source))
            .fontSize(10)
            .fontColor('#4A6B8A')
            .backgroundColor('#EAF1FB')
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
        .width('100%')

        Text(item.editedBoxCount > 0 ?
          `${item.editedTopClassLabel} 等 ${item.editedBoxCount} 项` : '未检测到物品')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 8 }) {
          Text(formatExecutionMode(item.executionMode))
            .fontSize(10)
            .fontColor('#6B7280')
          Text(formatMs(item.totalMs))
            .fontSize(10)
            .fontColor('#8A9099')
          Text(`${item.imageWidth}×${item.imageHeight}`)
            .fontSize(10)
            .fontColor('#A0A6AF')
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(20)
        .fontColor('#B0B6BE')
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(CARD_WHITE)
    .onClick(() => this.openDetail(item))
  }

  build() {
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
          Text('识别历史')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_PRIMARY)
          Text(this.items.length > 0 ? `本地记录 · ${this.items.length} 条 · 按时间倒序` : '本地记录 · 按时间倒序')
            .fontSize(10)
            .fontColor(TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('云端记录')
          .fontSize(11)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor(CARD_WHITE)
          .fontColor(ACCENT)
          .border({ width: 1, color: '#C7D7FA' })
          .onClick(() => {
            this.openCloudRecords();
          })
      }
      .width('100%')
      .padding({ top: 6 })

      Row({ space: 8 }) {
        ForEach(FILTERS, (option: FilterOption) => {
          this.filterChip(option)
        }, (option: FilterOption) => option.label)
      }
      .width('100%')

      if (this.errorText.length > 0) {
        Row({ space: 8 }) {
          Text(this.errorText)
            .fontSize(11)
            .fontColor('#B45309')
            .layoutWeight(1)
          Button('重试')
            .fontSize(11)
            .height(28)
            .backgroundColor('#FFFFFF')
            .fontColor(ACCENT)
            .border({ width: 1, color: '#C7D7FA' })
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor('#FFF7E8')
      }

      if (this.loading && this.items.length === 0) {
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
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 8 }) {
          Text('暂无历史记录')
            .fontSize(15)
            .fontColor(TEXT_PRIMARY)
          Text('在首页完成识别后点击“保存识别结果”，记录会出现在这里。')
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .lineHeight(16)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(24)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (item: RecordSummary) => {
            ListItem() {
              this.recordRow(item)
            }
          }, (item: RecordSummary) => item.recordId)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        if (this.hasMore) {
          Button(this.loading ? '加载中…' : '加载更多')
            .fontSize(12)
            .height(36)
            .width('100%')
            .backgroundColor(CARD_WHITE)
            .fontColor(ACCENT)
            .border({ width: 1, color: '#C7D7FA' })
            .enabled(!this.loading)
            .onClick(() => {
              this.loadMore();
            })
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor(PAGE_BACKGROUND)
    .alignItems(HorizontalAlign.Start)
  }
}
