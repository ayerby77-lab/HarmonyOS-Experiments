/**
 * 页面专用：三阶段耗时、总耗时、执行模式与独立的 UI 响应探针指标。
 *
 * 注意：界面响应指标来自主线程事件/定时器排队，与推理总耗时分别呈现，不能混用。
 */
import { DetectionResult, InferenceExecutionMode } from '../../models/DetectionTypes';
import { formatMs } from './BoxGeometry';

@Component
export struct TimingPanel {
  @Prop result: DetectionResult | undefined = undefined;
  @Prop selectedMode: InferenceExecutionMode = InferenceExecutionMode.TASK_POOL;
  @Prop uiTapLastMs: number = 0;
  @Prop uiTapMaxMs: number = 0;
  @Prop uiTapSamples: number = 0;
  @Prop uiTimerMaxMs: number = 0;
  @Prop uiTimerSamples: number = 0;
  @Prop probeRunning: boolean = false;

  private modeLabel(mode: InferenceExecutionMode): string {
    return mode === InferenceExecutionMode.SYNC ? '同步（阻塞 UI）' : 'TaskPool 异步';
  }

  @Builder
  metricCell(label: string, value: string, highlight: boolean) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(10)
        .fontColor('#8A9099')
      Text(value)
        .fontSize(highlight ? 16 : 14)
        .fontWeight(highlight ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(highlight ? '#2E6BE6' : '#1F2430')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(8)
    .borderRadius(8)
    .backgroundColor(highlight ? '#EEF2FB' : '#F7F8FA')
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('耗时与执行模式')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1F2430')
        Text(this.selectedMode === InferenceExecutionMode.SYNC ? '当前：同步' : '当前：TaskPool')
          .fontSize(10)
          .fontColor('#2E6BE6')
          .backgroundColor('#EEF2FB')
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .layoutWeight(0)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      if (this.result !== undefined) {
        Row({ space: 8 }) {
          this.metricCell('预处理', formatMs(this.result.timing.preprocessMs), false)
          this.metricCell('模型推理', formatMs(this.result.timing.inferenceMs), false)
          this.metricCell('后处理', formatMs(this.result.timing.postprocessMs), false)
        }
        .width('100%')

        Row({ space: 8 }) {
          this.metricCell('总耗时', formatMs(this.result.timing.totalMs), true)
          this.metricCell('冷启动', this.result.timing.coldStart ? '是' : '否', false)
          this.metricCell('模型加载', this.result.timing.coldStart ?
            formatMs(this.result.timing.modelLoadMs) : '复用会话', false)
        }
        .width('100%')

        Column({ space: 2 }) {
          Text(`结果阈值 ${this.result.confidenceThreshold.toFixed(2)} · IoU ${this.result.iouThreshold.toFixed(2)}`)
            .fontSize(11)
            .fontColor('#4A4F58')
          Text(`结果模式：${this.modeLabel(this.result.executionMode)} · 原图 ` +
            `${this.result.imageWidth}×${this.result.imageHeight}`)
            .fontSize(11)
            .fontColor('#4A4F58')
          Text(`模型 ${this.result.modelId}`)
            .fontSize(10)
            .fontColor('#8A9099')
          Text(`请求 ${this.result.requestId} · 图片 ${this.result.imageId}`)
            .fontSize(9)
            .fontColor('#9AA1AC')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        if (this.result.executionMode !== this.selectedMode) {
          Text('已切换执行模式，当前结果仍来自上一次运行；重新识别后生效')
            .fontSize(10)
            .fontColor('#B45309')
            .width('100%')
        }
      } else {
        Text('完成一次识别后显示三阶段耗时与总耗时')
          .fontSize(12)
          .fontColor('#8A9099')
          .width('100%')
      }

      Divider()
        .color('#EDEFF3')

      Row({ space: 6 }) {
        Text('界面响应（独立探针）')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1F2430')
        if (this.probeRunning) {
          Text('采样中')
            .fontSize(9)
            .fontColor('#1D9E6C')
            .backgroundColor('#ECF8F2')
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }
        Text(`${this.uiTapSamples + this.uiTimerSamples} 个样本`)
          .fontSize(10)
          .fontColor('#8A9099')
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Text(`点击排队：最近 ${formatMs(this.uiTapLastMs)} · 峰值 ${formatMs(this.uiTapMaxMs)}` +
        `（${this.uiTapSamples} 次）`)
        .fontSize(11)
        .fontColor('#4A4F58')
        .width('100%')
      Text(`100 ms 定时器延迟峰值：${formatMs(this.uiTimerMaxMs)}（${this.uiTimerSamples} 次采样）`)
        .fontSize(11)
        .fontColor('#4A4F58')
        .width('100%')
      Text('点击排队 = 点击事件产生到主线程开始处理；定时器延迟反映界面是否被占用。两者都不是推理耗时。')
        .fontSize(10)
        .fontColor('#8A9099')
        .width('100%')
        .lineHeight(15)
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }
}
