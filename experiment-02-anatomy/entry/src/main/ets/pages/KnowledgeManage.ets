import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { CourseDocument } from '../model/Knowledge';
import { KnowledgeService } from '../service/KnowledgeService';
import { KnowledgeSegment } from '../model/Knowledge';

interface DocItem {
  doc: CourseDocument;
  segmentCount: number;
}

@Entry
@Component
struct KnowledgeManage {
  @State private documents: DocItem[] = [];
  @State private loading: boolean = false;
  @State private errorMsg: string = '';
  @State private showEditor: boolean = false;
  @State private editingId: string = '';
  @State private editTitle: string = '';
  @State private editSource: string = '';
  @State private editContent: string = '';
  @State private confirmDeleteId: string = '';

  private service: KnowledgeService | null = null;

  aboutToAppear(): void {
    this.service = KnowledgeService.getInstance(getContext(this) as common.UIAbilityContext);
    this.loadDocuments();
  }

  private async loadDocuments(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      const docs = await this.service!.listDocuments();
      const items: DocItem[] = [];
      for (const doc of docs) {
        const segs = await this.service!.getSegments(doc.id);
        items.push({ doc, segmentCount: segs.length });
      }
      this.documents = items;
    } catch (e) {
      this.errorMsg = '加载资料列表失败，请重试。';
    } finally {
      this.loading = false;
    }
  }

  private openCreate(): void {
    this.editingId = '';
    this.editTitle = '';
    this.editSource = '';
    this.editContent = '';
    this.showEditor = true;
  }

  private openEdit(item: DocItem): void {
    this.editingId = item.doc.id;
    this.editTitle = item.doc.title;
    this.editSource = item.doc.source;
    this.editContent = item.doc.content;
    this.showEditor = true;
  }

  private async saveDocument(): Promise<void> {
    if (!this.editTitle.trim()) {
      promptAction.showToast({ message: '请输入资料标题' });
      return;
    }
    if (!this.editSource.trim()) {
      promptAction.showToast({ message: '请输入资料来源' });
      return;
    }
    if (!this.editContent.trim()) {
      promptAction.showToast({ message: '请输入资料正文' });
      return;
    }
    try {
      if (this.editingId) {
        await this.service!.updateDocument(this.editingId, this.editTitle.trim(), this.editSource.trim(), this.editContent.trim());
        promptAction.showToast({ message: '资料已更新，版本号已递增并通知检索模块' });
      } else {
        await this.service!.createDocument(this.editTitle.trim(), this.editSource.trim(), this.editContent.trim());
        promptAction.showToast({ message: '资料已新增并完成切分' });
      }
      this.showEditor = false;
      this.loadDocuments();
    } catch (e) {
      promptAction.showToast({ message: '保存失败，请重试' });
    }
  }

  private async confirmDelete(id: string): Promise<void> {
    this.confirmDeleteId = id;
  }

  private async doDelete(): Promise<void> {
    if (!this.confirmDeleteId) {
      return;
    }
    try {
      const ok = await this.service!.deleteDocument(this.confirmDeleteId);
      if (ok) {
        promptAction.showToast({ message: '资料已删除，已通知检索模块移除索引' });
        this.loadDocuments();
      } else {
        promptAction.showToast({ message: '删除失败：资料不存在' });
      }
    } catch (e) {
      promptAction.showToast({ message: '删除失败，请重试' });
    } finally {
      this.confirmDeleteId = '';
    }
  }

  private viewOriginal(item: DocItem): void {
    router.pushUrl({
      url: 'pages/SourceDetail',
      params: {
        documentId: item.doc.id,
        documentRevision: item.doc.revision
      }
    });
  }

  private formatDate(ts: number): string {
    const d = new Date(ts);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  build() {
    Stack() {
    Column() {
      // 顶部标题栏
      Row() {
        Text('课程资料管理').fontSize(22).fontWeight(FontWeight.Bold)
        Blank()
        Button('新增').onClick(() => this.openCreate())
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.loading) {
        Text('加载中...').fontSize(14).fontColor('#526170').margin({ top: 20 })
      } else if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontColor('#B42318').margin({ top: 20 })
        Button('重试').onClick(() => this.loadDocuments()).margin({ top: 12 })
      } else if (this.documents.length === 0) {
        Column({ space: 12 }) {
          Text('暂无资料').fontSize(16).fontColor('#526170')
          Button('新增第一篇资料').onClick(() => this.openCreate())
        }.width('100%').margin({ top: 60 })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.documents, (item: DocItem) => {
              Column({ space: 8 }) {
                Row() {
                  Text(item.doc.title).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
                  Text(`v${item.doc.revision}`).fontSize(12).fontColor('#1570EF').backgroundColor('#EFF6FF')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(4)
                }.width('100%')
                Text(item.doc.source).fontSize(13).fontColor('#526170').width('100%')
                Text(`片段数：${item.segmentCount} · 更新于 ${this.formatDate(item.doc.updatedAt)}`)
                  .fontSize(12).fontColor('#7A8696').width('100%')
                Row({ space: 8 }) {
                  Button('查看原文').fontSize(13).layoutWeight(1)
                    .onClick(() => this.viewOriginal(item))
                  Button('编辑').fontSize(13).layoutWeight(1)
                    .onClick(() => this.openEdit(item))
                  Button('删除').fontSize(13).fontColor(Color.White).backgroundColor('#B42318').layoutWeight(1)
                    .onClick(() => this.confirmDelete(item.doc.id))
                }.width('100%').margin({ top: 4 })
              }
              .width('100%').padding(14).backgroundColor('#FFFFFF')
              .borderRadius(8).shadow({ radius: 2, color: '#1A000000', offsetX: 0, offsetY: 1 })
            }, (item: DocItem) => item.doc.id)
          }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor('#F5F7FA')

    // 编辑器弹窗
    if (this.showEditor) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => { this.showEditor = false; })
        Column({ space: 12 }) {
          Text(this.editingId ? '编辑资料' : '新增资料').fontSize(18).fontWeight(FontWeight.Bold)
          TextInput({ placeholder: '资料标题', text: this.editTitle })
            .width('100%').onChange((v: string) => { this.editTitle = v; })
          TextInput({ placeholder: '资料来源（URL / 书籍 / 作者）', text: this.editSource })
            .width('100%').onChange((v: string) => { this.editSource = v; })
          TextArea({ placeholder: '资料正文（支持多段落，将自动切分）', text: this.editContent })
            .width('100%').height(240).onChange((v: string) => { this.editContent = v; })
          Row({ space: 12 }) {
            Button('取消').layoutWeight(1).backgroundColor('#E5E7EB').fontColor('#111827')
              .onClick(() => { this.showEditor = false; })
            Button('保存').layoutWeight(1).onClick(() => this.saveDocument())
          }.width('100%').margin({ top: 4 })
        }
        .width('90%').padding(20).backgroundColor('#FFFFFF').borderRadius(12)
      }.width('100%').height('100%').position({ x: 0, y: 0 })
    }

    // 删除确认弹窗
    if (this.confirmDeleteId.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => { this.confirmDeleteId = ''; })
        Column({ space: 16 }) {
          Text('确认删除该资料？').fontSize(17).fontWeight(FontWeight.Bold)
          Text('删除后该资料的全部片段将从数据库移除，检索模块也会收到删除通知。此操作不可撤销。')
            .fontSize(14).fontColor('#526170').lineHeight(22)
          Row({ space: 12 }) {
            Button('取消').layoutWeight(1).backgroundColor('#E5E7EB').fontColor('#111827')
              .onClick(() => { this.confirmDeleteId = ''; })
            Button('确认删除').layoutWeight(1).backgroundColor('#B42318').fontColor(Color.White)
              .onClick(() => this.doDelete())
          }.width('100%')
        }
        .width('85%').padding(20).backgroundColor('#FFFFFF').borderRadius(12)
      }.width('100%').height('100%').position({ x: 0, y: 0 })
    }
    }.width('100%').height('100%')
  }
}
