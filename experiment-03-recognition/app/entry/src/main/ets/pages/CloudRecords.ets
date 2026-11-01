/**
 * 云端记录查询页（Agent 3，第三阶段）。
 *
 * 只通过 CloudRecordPort 查询云端历史与统计，不直接处理 HTTP；端口未注册时
 * 展示“云端服务尚未配置”并引导返回本地历史。支持时间范围、类别筛选与分页。
 */
import { COCO_CLASSES } from '../models/ModelConstants';
import { formatExecutionMode, formatRecordTime, formatSource } from '../components/recognition/RecordFormat';
import { formatMs } from '../components/recognition/BoxGeometry';
import {
  CLOUD_UNAVAILABLE_MESSAGE,
  CloudClassCount,
  CloudQueryFilter,
  CloudRecordItem,
  CloudRecordPort,
  CloudRecordRegistry,
  CloudStatistics,
  CloudStatisticsFilter,
  describeCloudError
} from '../components/recognition/CloudQuery';

const PAGE_SIZE: number = 20;
const PAGE_BACKGROUND: string = '#F4F5F7';
const CARD_WHITE: string = '#FFFFFF';
const TEXT_PRIMARY: string = '#1F2430';
const TEXT_SECONDARY: string = '#6B7280';
const ACCENT: string = '#2E6BE6';
const DAY_MS: number = 24 * 60 * 60 * 1000;

interface RangeOption {
  key: string;
  label: string;
  /** -1 表示不限；0 表示今天；其余为最近 N 天。 */
  days: number;
}

const RANGES: RangeOption[] = [
  { key: 'today', label: '今天', days: 0 },
  { key: '7d', label: '近 7 天', days: 7 },
  { key: '30d', label: '近 30 天', days: 30 },
  { key: 'all', label: '全部', days: -1 }
];

const CLASS_PICKER_RANGE: string[] = ['全部类别'].concat(COCO_CLASSES);

@Entry
@Component
struct CloudRecordsPage {
  @State items: CloudRecordItem[] = [];
  @State stats: CloudStatistics | undefined = undefined;
  @State statsError: string = '';
  @State page: number = 1;
  @State total: number = 0;
  @State hasMore: boolean = false;
  @State loading: boolean = false;
  @State errorText: string = '';
  @State errorAction: string = 'none';
  @State rangeKey: string = '7d';
  @State fromMs: number = 0;
  @State classId: number = -1;
  @State unavailable: boolean = false;
  @State authBusy: boolean = false;

  private port: CloudRecordPort | undefined = undefined;
  private querySeq: number = 0;
  private statsSeq: number = 0;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    this.port = CloudRecordRegistry.resolve();
    if (this.port === undefined) {
      this.unavailable = true;
      return;
    }
    this.fromMs = this.rangeFromMs('7d');
    this.loadPage(1);
    this.loadStatistics();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.querySeq += 1;
    this.statsSeq += 1;
  }

  private rangeFromMs(key: string): number {
    if (key === 'all') {
      return 0;
    }
    if (key === 'today') {
      const start: Date = new Date();
      start.setHours(0, 0, 0, 0);
      return start.getTime();
    }
    for (let i = 0; i < RANGES.length; i++) {
      if (RANGES[i].key === key) {
        return Date.now() - RANGES[i].days * DAY_MS;
      }
    }
    return 0;
  }

  private async loadPage(page: number): Promise<void> {
    const port: CloudRecordPort | undefined = this.port;
    if (port === undefined) {
      return;
    }
    this.querySeq += 1;
    const seq: number = this.querySeq;
    this.loading = true;
    this.errorText = '';
    this.errorAction = 'none';
    const filter: CloudQueryFilter = {
      fromMs: this.fromMs > 0 ? this.fromMs : undefined,
      classId: this.classId >= 0 ? this.classId : undefined,
      page: page,
      pageSize: PAGE_SIZE
    };
    try {
      const result = await port.list(filter);
      if (!this.pageActive || seq !== this.querySeq) {
        return;
      }
      this.items = result.items;
      this.page = result.page;
      this.total = result.total;
      this.hasMore = result.hasMore;
    } catch (err) {
      if (!this.pageActive || seq !== this.querySeq) {
        return;
      }
      const hint = describeCloudError(err as Object);
      this.errorText = hint.message;
      this.errorAction = hint.action;
      if (page === 1) {
        this.items = [];
        this.total = 0;
        this.hasMore = false;
      }
    } finally {
      if (seq === this.querySeq) {
        this.loading = false;
      }
    }
  }

  private async loadStatistics(): Promise<void> {
    const port: CloudRecordPort | undefined = this.port;
    if (port === undefined) {
      return;
    }
    this.statsSeq += 1;
    const seq: number = this.statsSeq;
    this.statsError = '';
    const filter: CloudStatisticsFilter = { fromMs: this.fromMs > 0 ? this.fromMs : undefined };
    try {
      const next: CloudStatistics = await port.statistics(filter);
      if (!this.pageActive || seq !== this.statsSeq) {
        return;
      }
      this.stats = next;
    } catch (err) {
      if (!this.pageActive || seq !== this.statsSeq) {
        return;
      }
      this.stats = undefined;
      this.statsError = describeCloudError(err as Object).message;
    }
  }

  private applyRange(option: RangeOption): void {
    if (this.rangeKey === option.key) {
      return;
    }
    this.rangeKey = option.key;
    this.fromMs = this.rangeFromMs(option.key);
    this.page = 1;
    this.items = [];
    this.loadPage(1);
    this.loadStatistics();
  }

  private applyClass(classId: number): void {
    if (this.classId === classId) {
      return;
    }
    this.classId = classId;
    this.page = 1;
    this.loadPage(1);
  }

  private openClassPicker(): void {
    this.getUIContext().showTextPickerDialog({
      range: CLASS_PICKER_RANGE,
      selected: this.classId + 1,
      onAccept: (value: TextPickerResult) => {
        let index: number = 0;
        if (typeof value.index === 'number') {
          index = value.index;
        } else if (value.index.length > 0) {
          index = value.index[0];
        }
        this.applyClass(index - 1);
      }
    });
  }

  private goPage(delta: number): void {
    if (this.loading) {
      return;
    }
    const next: number = this.page + delta;
    if (next < 1 || (delta > 0 && !this.hasMore)) {
      return;
    }
    this.loadPage(next);
  }

  private async relogin(): Promise<void> {
    const port: CloudRecordPort | undefined = this.port;
    if (port === undefined || this.authBusy) {
      return;
    }
    this.authBusy = true;
    try {
      await port.reauthenticate();
      if (!this.pageActive) {
        return;
      }
      this.notify('已重新登录，正在刷新云端记录');
      this.loadPage(1);
      this.loadStatistics();
    } catch (err) {
      if (this.pageActive) {
        this.notify(`重新登录失败：${describeCloudError(err as Object).message}`);
      }
    } finally {
      if (this.pageActive) {
        this.authBusy = false;
      }
    }
  }

  private retry(): void {
    this.loadPage(this.page);
    this.loadStatistics();
  }

  private classLabel(): string {
    if (this.classId < 0 || this.classId >= COCO_CLASSES.length) {
      return '全部类别';
    }
    return COCO_CLASSES[this.classId];
  }

  private notify(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // Toast 失败不影响主流程。
    }
  }

  @Builder
  rangeChip(option: RangeOption) {
    Text(option.label)
      .fontSize(12)
      .fontColor(this.rangeKey === option.key ? '#FFFFFF' : '#4A4F58')
      .backgroundColor(this.rangeKey === option.key ? ACCENT : CARD_WHITE)
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .onClick(() => this.applyRange(option))
  }

  @Builder
  classChip(entry: CloudClassCount) {
    Text(`${entry.label} ×${entry.count}`)
      .fontSize(11)
      .fontColor(this.classId === entry.classId ? '#FFFFFF' : '#4A4F58')
      .backgroundColor(this.classId === entry.classId ? ACCENT : '#EEF2FB')
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .onClick(() => this.applyClass(entry.classId))
  }

  @Builder
  recordRow(item: CloudRecordItem) {
    Column({ space: 6 }) {
      Row() {
        Text(formatRecordTime(item.recognizedAtMs))
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

      Row({ space: 8 }) {
        Text(item.boxCount > 0 ? `${item.topClassLabel} 等 ${item.boxCount} 项` : '未检测到物品')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatExecutionMode(item.executionMode))
          .fontSize(10)
          .fontColor('#8A9099')
        Text(formatMs(item.totalMs))
          .fontSize(10)
          .fontColor('#8A9099')
        Text(`${item.imageWidth}×${item.imageHeight}`)
          .fontSize(10)
          .fontColor('#A0A6AF')
      }
      .width('100%')

      if (item.counts.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(item.counts.slice(0, 6), (entry: CloudClassCount) => {
            Text(`${entry.label} ×${entry.count}`)
              .fontSize(10)
              .fontColor('#2E6BE6')
              .backgroundColor('#EEF2FB')
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ right: 5, top: 2 })
          }, (entry: CloudClassCount) => `${item.recordId}-${entry.classId}`)
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
          Text('云端记录')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_PRIMARY)
          Text(this.unavailable ? '云端服务未配置' : '时间/类别筛选 · 分页 · 服务端统计')
            .fontSize(10)
            .fontColor(TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (!this.unavailable) {
          Button('刷新')
            .fontSize(11)
            .height(30)
            .padding({ left: 10, right: 10 })
            .backgroundColor(CARD_WHITE)
            .fontColor(ACCENT)
            .border({ width: 1, color: '#C7D7FA' })
            .enabled(!this.loading)
            .onClick(() => {
              this.retry();
            })
        }
      }
      .width('100%')
      .padding({ top: 6 })

      if (this.unavailable) {
        Column({ space: 10 }) {
          Text(CLOUD_UNAVAILABLE_MESSAGE)
            .fontSize(14)
            .fontColor(TEXT_PRIMARY)
            .textAlign(TextAlign.Center)
          Text('本地保存的记录仍可在“识别历史”中查看；云端接入后可在此按时间与类别查询已上传的记录。')
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .lineHeight(17)
          Button('返回本地历史')
            .fontSize(12)
            .height(36)
            .backgroundColor(ACCENT)
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .padding(24)
        .justifyContent(FlexAlign.Center)
      } else {
        Row({ space: 8 }) {
          ForEach(RANGES, (option: RangeOption) => {
            this.rangeChip(option)
          }, (option: RangeOption) => option.key)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('类别')
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
          Text(this.classLabel())
            .fontSize(11)
            .fontColor(this.classId >= 0 ? '#FFFFFF' : '#4A4F58')
            .backgroundColor(this.classId >= 0 ? ACCENT : CARD_WHITE)
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .onClick(() => this.applyClass(-1))
          Button(this.classId >= 0 ? '更换' : '选择类别')
            .fontSize(11)
            .height(28)
            .padding({ left: 10, right: 10 })
            .backgroundColor('#FFFFFF')
            .fontColor(ACCENT)
            .border({ width: 1, color: '#C7D7FA' })
            .onClick(() => this.openClassPicker())
          Text(`${this.total} 条`)
            .fontSize(11)
            .fontColor(TEXT_SECONDARY)
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
        .width('100%')

        if (this.stats !== undefined) {
          Column({ space: 6 }) {
            Row() {
              Text('云端统计')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(TEXT_PRIMARY)
                .layoutWeight(1)
              Text(`共 ${this.stats.totalRecords} 条记录 · ${this.stats.totalDetections} 个检测项`)
                .fontSize(10)
                .fontColor(TEXT_SECONDARY)
            }
            .width('100%')

            if (this.stats.counts.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.stats.counts.slice(0, 10), (entry: CloudClassCount) => {
                  this.classChip(entry)
                }, (entry: CloudClassCount) => `stat-${entry.classId}`)
              }
              .width('100%')
            } else {
              Text('该时间范围暂无统计')
                .fontSize(11)
                .fontColor('#8A9099')
                .width('100%')
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(12)
          .backgroundColor(CARD_WHITE)
          .alignItems(HorizontalAlign.Start)
        } else if (this.statsError.length > 0) {
          Text(`统计不可用：${this.statsError}`)
            .fontSize(10)
            .fontColor('#B45309')
            .width('100%')
            .padding(8)
            .borderRadius(8)
            .backgroundColor('#FFF7E8')
        }

        if (this.errorText.length > 0) {
          Column({ space: 8 }) {
            Text(this.errorText)
              .fontSize(11)
              .fontColor('#B45309')
              .width('100%')
              .lineHeight(16)
            Row({ space: 8 }) {
              if (this.errorAction === 'retry') {
                Button('重试')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor('#FFFFFF')
                  .fontColor(ACCENT)
                  .border({ width: 1, color: '#C7D7FA' })
                  .onClick(() => {
                    this.retry();
                  })
              }
              if (this.errorAction === 'relogin') {
                Button(this.authBusy ? '登录中…' : '重新登录')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor(ACCENT)
                  .fontColor('#FFFFFF')
                  .enabled(!this.authBusy)
                  .onClick(() => {
                    this.relogin();
                  })
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor('#FFF7E8')
          .alignItems(HorizontalAlign.Start)
        }

        if (this.loading && this.items.length === 0) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(ACCENT)
            Text('正在查询云端记录…')
              .fontSize(12)
              .fontColor(TEXT_SECONDARY)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0 && this.errorText.length === 0) {
          Column({ space: 8 }) {
            Text('该范围暂无云端记录')
              .fontSize(15)
              .fontColor(TEXT_PRIMARY)
            Text('本地保存的记录会在网络恢复后自动上传，可稍后刷新查看。')
              .fontSize(11)
              .fontColor(TEXT_SECONDARY)
              .textAlign(TextAlign.Center)
              .lineHeight(16)
          }
          .width('100%')
          .layoutWeight(1)
          .padding(24)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length > 0) {
          List({ space: 10 }) {
            ForEach(this.items, (item: CloudRecordItem) => {
              ListItem() {
                this.recordRow(item)
              }
            }, (item: CloudRecordItem) => item.recordId)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)

          Row({ space: 10 }) {
            Button('上一页')
              .fontSize(11)
              .height(32)
              .layoutWeight(1)
              .backgroundColor(CARD_WHITE)
              .fontColor(ACCENT)
              .border({ width: 1, color: '#C7D7FA' })
              .enabled(!this.loading && this.page > 1)
              .onClick(() => {
                this.goPage(-1);
              })
            Text(this.loading ? '加载中…' : `第 ${this.page} 页 · 共 ${this.total} 条`)
              .fontSize(11)
              .fontColor(TEXT_SECONDARY)
            Button('下一页')
              .fontSize(11)
              .height(32)
              .layoutWeight(1)
              .backgroundColor(CARD_WHITE)
              .fontColor(ACCENT)
              .border({ width: 1, color: '#C7D7FA' })
              .enabled(!this.loading && this.hasMore)
              .onClick(() => {
                this.goPage(1);
              })
          }
          .width('100%')
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
