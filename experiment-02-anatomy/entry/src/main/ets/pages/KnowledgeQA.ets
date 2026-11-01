import { SourceCitation, QueryState } from '../model/Knowledge';
import { RetrievedChunk } from '../model/Knowledge';
import { ServiceContainer } from '../service/ServiceContainer';
import { seedDemoDocuments } from '../service/seed/DemoDocuments';
import { ServiceError, ServiceException, StreamEventImpl, ChatHandle, ChatTurn } from '../service/types';

@Entry
@Component
struct KnowledgeQA {
  @State private question: string = '';
  @State private answer: string = '';
  @State private citations: SourceCitation[] = [];
  @State private state: QueryState = 'idle';
  @State private errorMessage: string = '';
  @State private lastQuestion: string = '';
  @State private indexStatusText: string = '索引加载中...';

  private container?: ServiceContainer;
  private currentCancel?: ChatHandle;

  aboutToAppear(): void {
    this.bootstrap();
  }

  private bootstrap(): void {
    try {
      this.container = new ServiceContainer({ useCloud: false });
      seedDemoDocuments(this.container);
      const that = this;
      setTimeout(() => {
        if (that.container !== undefined && that.container.retrieval.indexReady) {
          that.indexStatusText = '索引就绪，已收录 ' + that.container.retrieval.indexedCount + ' 个片段';
        } else {
          const pending = that.container !== undefined ? that.container.indexManager.pendingCount : 0;
          that.indexStatusText = '索引仍在构建中（' + pending + ' 任务进行）';
        }
      }, 800);
    } catch (_e) {
      this.indexStatusText = '服务初始化失败';
    }
  }

  private async handleSend(): Promise<void> {
    const q = this.question.trim();
    if (q.length === 0 || this.container === undefined) return;
    this.lastQuestion = q;
    this.resetAnswer();

    this.state = 'retrieving';
    let segments: RetrievedChunk[] = [];
    try {
      segments = await this.container.retrieval.retrieve(q, 5);
      if (segments.length === 0) {
        this.state = 'empty';
        this.errorMessage = '没有检索到与问题相关的课程资料，请尝试换一种方式提问。';
        return;
      }
    } catch (e) {
      const code = (e as ServiceException).code ?? ServiceError.UNKNOWN;
      this.state = mapErrorToState(code);
      this.errorMessage = this.humanReadableError(code);
      return;
    }

    this.state = 'streaming';
    const that = this;
    this.currentCancel = this.container.chat.ask(
      { question: q, segments: segments },
      (ev: StreamEventImpl): void => { that.handleEvent(ev); },
      (): void => {
        if (that.state === 'streaming' || that.state === 'processing') {
          that.state = 'complete';
        }
      }
    );
  }

  private handleEvent(ev: StreamEventImpl): void {
    switch (ev.kind) {
      case 'retrieving':
        this.state = 'processing';
        break;
      case 'token':
        this.answer += ev.text;
        break;
      case 'citation': {
        const c = ev.citation;
        if (c !== null) {
          let dup = false;
          for (let i = 0; i < this.citations.length; i++) {
            if (this.citations[i].segmentId === c.segmentId) { dup = true; break; }
          }
          if (!dup) this.citations.push(c);
        }
        break;
      }
      case 'done':
        if (this.state === 'streaming' || this.state === 'processing') {
          this.state = 'complete';
        }
        break;
      case 'error':
        this.state = 'error';
        this.errorMessage = ev.message || this.humanReadableError(ServiceError.MODEL_ERROR);
        break;
    }
  }

  private handleCancel(): void {
    if (this.currentCancel !== undefined) {
      this.currentCancel.cancel();
    }
    this.state = 'idle';
    this.errorMessage = '已取消当前请求';
  }

  private handleRetry(): void {
    this.question = this.lastQuestion;
    void this.handleSend();
  }

  private openSource(citation: SourceCitation): void {
    const url = 'pages/SourceDetail?docId=' + citation.documentId + '&segId=' + citation.segmentId;
    void this.getUIContext().getRouter().pushUrl({ url });
  }

  private resetAnswer(): void {
    this.answer = '';
    this.citations = [];
    this.errorMessage = '';
  }

  private humanReadableError(code: ServiceError): string {
    switch (code) {
      case ServiceError.OFFLINE: return '网络不可用，请检查后重试';
      case ServiceError.TIMEOUT: return '请求超时，可能是网络较慢或云端繁忙';
      case ServiceError.AUTH_FAILURE: return '云端鉴权失败';
      case ServiceError.RATE_LIMIT: return '请求过于频繁，请稍后再试';
      case ServiceError.INDEX_NOT_READY: return '索引尚未就绪，请稍后再试';
      case ServiceError.EMPTY_RESULTS: return '未找到相关资料';
      case ServiceError.CANCELLED: return '请求已被取消';
      default: return '请求失败，请重试';
    }
  }

  private isBusy(): boolean {
    return this.state === 'retrieving' || this.state === 'processing' || this.state === 'streaming';
  }

  build() {
    Column() {
      Row() {
        Text('课程知识问答').fontSize(22).fontWeight(FontWeight.Bold)
        Blank()
        if (this.isBusy()) {
          Button('取消').type(ButtonType.Normal).onClick(() => this.handleCancel())
        }
      }.width('100%').padding({ left: 16, right: 16, top: 16 })

      Text(this.indexStatusText)
        .fontSize(12).fontColor('#526170')
        .padding({ left: 16, top: 4 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.lastQuestion.length > 0) {
            Row() {
              Text(this.lastQuestion)
                .fontSize(15)
                .padding(12)
                .backgroundColor('#E8F3FF')
                .borderRadius(12)
            }.width('100%').justifyContent(FlexAlign.End)
          }

          if (this.answer.length > 0 || this.isBusy()) {
            Column({ space: 8 }) {
              Text(this.answer || '正在思考...')
                .fontSize(15).lineHeight(24)
                .width('100%')

              if (this.citations.length > 0) {
                Text('引用来源').fontSize(12).fontColor('#526170').margin({ top: 8 })
                ForEach(this.citations, (c: SourceCitation) => {
                  Text('• ' + c.documentTitle + ' · ' + c.excerpt)
                    .fontSize(13)
                    .fontColor('#1890FF')
                    .onClick(() => this.openSource(c))
                }, (c: SourceCitation) => c.segmentId)
              }
            }.width('100%').padding(12).backgroundColor('#FFFFFF')
             .borderRadius(12).borderWidth(1).borderColor('#E6EBF2')
          }

          if (this.errorMessage.length > 0) {
            Column({ space: 8 }) {
              Text(this.errorMessage).fontSize(14).fontColor('#B42318').width('100%')
              if (this.lastQuestion.length > 0) {
                Button('重试').type(ButtonType.Normal).onClick(() => this.handleRetry())
              }
            }.width('100%').padding(12).backgroundColor('#FFECEC').borderRadius(12)
          }
        }.padding(16)
      }.width('100%').layoutWeight(1).scrollBar(BarState.On)

      Column({ space: 8 }) {
        TextArea({ placeholder: '例如：心脏的四个腔室分别是什么？', text: this.question })
          .width('100%').height(80)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .onChange((v: string) => { this.question = v; })
        Row() {
          Button('发送')
            .enabled(!this.isBusy() && this.question.trim().length > 0)
            .onClick(() => this.handleSend())
          Button('返回').type(ButtonType.Normal)
            .onClick(() => this.getUIContext().getRouter().back())
        }.width('100%').justifyContent(FlexAlign.SpaceBetween)
      }.width('100%').padding(16).backgroundColor('#FFFFFF')
    }.width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}

function mapErrorToState(code: ServiceError): QueryState {
  switch (code) {
    case ServiceError.OFFLINE: return 'offline';
    case ServiceError.EMPTY_RESULTS: return 'empty';
    case ServiceError.INDEX_NOT_READY: return 'retrieving';
    case ServiceError.CANCELLED: return 'idle';
    default: return 'error';
  }
}
