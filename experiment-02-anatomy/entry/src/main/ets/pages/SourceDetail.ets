import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CourseDocument, KnowledgeSegment, CitationResolveResult } from '../model/Knowledge';
import { KnowledgeService } from '../service/KnowledgeService';

@Entry
@Component
struct SourceDetail {
  @State private document: CourseDocument | null = null;
  @State private segments: KnowledgeSegment[] = [];
  @State private highlightedSegmentId: string = '';
  @State private resolveResult: CitationResolveResult | null = null;
  @State private loading: boolean = true;
  @State private errorMsg: string = '';
  @State private showSegmentList: boolean = false;

  private service: KnowledgeService | null = null;

  aboutToAppear(): void {
    this.service = KnowledgeService.getInstance(getContext(this) as common.UIAbilityContext);
    const params = router.getParams() as Record<string, Object> | undefined;
    const documentId = params?.['documentId'] as string;
    const documentRevision = params?.['documentRevision'] as number;
    const segmentId = params?.['segmentId'] as string | undefined;
    this.loadData(documentId, documentRevision, segmentId);
  }

  private async loadData(documentId: string, documentRevision: number, segmentId?: string): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      // 若同时传入了版本号和片段 ID，先解析引用（判断是否过期）
      if (segmentId && documentRevision !== undefined) {
        this.resolveResult = await this.service!.resolveCitation(documentId, documentRevision, segmentId);
        if (this.resolveResult.segment) {
          this.highlightedSegmentId = this.resolveResult.segment.id;
        }
      }

      const doc = await this.service!.getDocument(documentId);
      if (!doc) {
        this.errorMsg = '该资料不存在或已被删除。';
        this.loading = false;
        return;
      }
      this.document = doc;
      this.segments = await this.service!.getSegments(documentId);
    } catch (e) {
      this.errorMsg = '加载失败，请返回重试。';
    } finally {
      this.loading = false;
    }
  }

  private getSegmentStyle(seg: KnowledgeSegment): string {
    if (seg.id === this.highlightedSegmentId) {
      return '#FEF3C7';
    }
    return 'transparent';
  }

  build() {
    Column() {
      Row() {
        Button('返回').onClick(() => router.back())
        Blank()
        Text('引用原文').fontSize(18).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.showSegmentList ? '原文' : '片段')
          .onClick(() => { this.showSegmentList = !this.showSegmentList; })
      }.width('100%').padding(12)

      if (this.loading) {
        Text('加载中...').fontSize(14).fontColor('#526170').margin({ top: 20 })
      } else if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontColor('#B42318').margin({ top: 20 }).padding({ left: 16, right: 16 })
      } else if (this.document) {
        Scroll() {
          Column({ space: 12 }) {
            // 过期引用提示
            if (this.resolveResult && !this.resolveResult.revisionCurrent) {
              Column({ space: 4 }) {
                Text('⚠ 引用版本提示').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#B45309')
                Text(this.resolveResult.staleReason ?? '')
                  .fontSize(13).fontColor('#92400E').lineHeight(20)
              }
              .width('100%').padding(12).backgroundColor('#FEF3C7').borderRadius(8)
            }
            if (this.resolveResult && !this.resolveResult.found) {
              Column({ space: 4 }) {
                Text('⚠ 引用片段不存在').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#B42318')
                Text(this.resolveResult.staleReason ?? '')
                  .fontSize(13).fontColor('#7F1D1D').lineHeight(20)
              }
              .width('100%').padding(12).backgroundColor('#FEE2E2').borderRadius(8)
            }

            // 资料信息
            Column({ space: 4 }) {
              Text(this.document.title).fontSize(20).fontWeight(FontWeight.Bold).width('100%')
              Text(`来源：${this.document.source}`).fontSize(13).fontColor('#526170').width('100%')
              Text(`版本：v${this.document.revision} · 片段数：${this.segments.length}`)
                .fontSize(12).fontColor('#7A8696').width('100%')
            }.width('100%').padding({ left: 16, right: 16 })

            if (this.showSegmentList) {
              // 片段列表视图
              Column({ space: 8 }) {
                ForEach(this.segments, (seg: KnowledgeSegment) => {
                  Column({ space: 4 }) {
                    Text(`片段 #${seg.seqIndex + 1}  [${seg.startOffset}-${seg.endOffset}]`)
                      .fontSize(12).fontColor('#1570EF').fontWeight(FontWeight.Medium)
                    Text(seg.content)
                      .fontSize(14).lineHeight(22)
                      .width('100%').padding(8)
                      .backgroundColor(this.getSegmentStyle(seg))
                      .borderRadius(4)
                  }.width('100%')
                }, (seg: KnowledgeSegment) => seg.id)
              }.width('100%').padding({ left: 16, right: 16 })
            } else {
              // 原文视图（高亮引用片段）
              if (this.highlightedSegmentId) {
                this.buildHighlightedContent()
              } else {
                Text(this.document.content)
                  .fontSize(15).lineHeight(26)
                  .width('100%').padding(12)
                  .backgroundColor('#FFFFFF').borderRadius(8)
              }
            }
          }.width('100%').padding({ bottom: 24 })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor('#F5F7FA')
  }

  @Builder
  buildHighlightedContent() {
    Column({ space: 0 }) {
      // 找到高亮片段，展示其前后上下文
      ForEach(this.segments, (seg: KnowledgeSegment) => {
        if (seg.id === this.highlightedSegmentId) {
          // 高亮片段
          Column({ space: 4 }) {
            Text(`▲ 引用片段 #${seg.seqIndex + 1}（v${seg.documentRevision}）`)
              .fontSize(12).fontColor('#B45309').fontWeight(FontWeight.Medium)
            Text(seg.content)
              .fontSize(15).lineHeight(26)
              .width('100%').padding(10)
              .backgroundColor('#FEF3C7').borderRadius(6)
            Text(`原文位置：字符 ${seg.startOffset} - ${seg.endOffset}`)
              .fontSize(11).fontColor('#7A8696')
          }.width('100%').padding(12)
        }
      }, (seg: KnowledgeSegment) => seg.id)
    }.width('100%')
  }
}
