import { common } from '@kit.AbilityKit';
import { AnatomyRouteParams, Note, SelectedStructure, formatTime } from '../model/Anatomy';
import { NOTE_MAX_LENGTH, readLocateParams } from '../model/AnatomyRules';
import { AnatomyStore } from '../store/AnatomyStore';

const GREEN: string = '#214E45';
const BEIGE: string = '#F5F2EB';
const ORANGE: string = '#A85B31';

@Entry
@Component
struct StructureDetail {
  @State private structure: SelectedStructure | null = null;
  @State private notes: Note[] = [];
  @State private draft: string = '';
  @State private editingId: string = '';
  @State private isFav: boolean = false;
  @State private ready: boolean = false;
  @State private error: string = '';
  private store?: AnatomyStore;

  aboutToAppear(): void {
    this.resolveParams();
    this.openStore();
  }

  onPageShow(): void {
    if (this.store) this.reload();
  }

  private resolveParams(): void {
    let raw: AnatomyRouteParams | undefined = undefined;
    try {
      raw = this.getUIContext().getRouter().getParams() as AnatomyRouteParams;
    } catch (e) {
      raw = undefined;
    }
    const found: SelectedStructure | null = readLocateParams(raw);
    if (found !== null && found.name.length === 0) found.name = found.id;
    this.structure = found;
  }

  private async openStore(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = await AnatomyStore.open(ctx);
      this.ready = true;
      await this.reload();
    } catch (e) {
      this.error = '本地数据初始化失败，请重试。';
    }
  }

  private async reload(): Promise<void> {
    if (!this.store || !this.structure) return;
    const id: string = this.structure.id;
    this.notes = await this.store.listNotes(id);
    this.isFav = await this.store.isFavorite(id);
  }

  private async toggleFavorite(): Promise<void> {
    if (!this.store || !this.structure) return;
    this.isFav = await this.store.toggleFavorite(
      this.structure.id, this.structure.name, this.structure.systemId, this.structure.systemId);
  }

  private startEdit(note: Note): void {
    this.editingId = note.id;
    this.draft = note.content;
    this.error = '';
  }

  private cancelEdit(): void {
    this.editingId = '';
    this.draft = '';
    this.error = '';
  }

  private async saveNote(): Promise<void> {
    if (!this.store || !this.structure) return;
    const targetId: string | null = this.editingId.length > 0 ? this.editingId : null;
    try {
      await this.store.saveNote(targetId, this.structure.id, this.structure.name, this.draft);
      this.cancelEdit();
      await this.reload();
    } catch (e) {
      this.error = '笔记正文需为 1~' + NOTE_MAX_LENGTH + ' 字。';
    }
  }

  private async deleteNote(id: string): Promise<void> {
    if (!this.store) return;
    await this.store.deleteNote(id);
    if (this.editingId === id) this.cancelEdit();
    await this.reload();
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('← 返回').type(ButtonType.Normal).height(36)
          .backgroundColor('#E7EBE4').fontColor(GREEN)
          .onClick((): void => this.getUIContext().getRouter().back());
        Text('结构详情').fontSize(18).fontWeight(FontWeight.Bold).fontColor(GREEN).layoutWeight(1);
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 });

      if (this.structure === null) {
        Column({ space: 12 }) {
          Text('未选择结构').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#526170');
          Text('请从人体浏览或收藏夹中选择一个结构后查看详情。').fontSize(14).fontColor('#707D76');
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 6 }) {
              Text(this.structure.name).fontSize(24).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
              Text('所属系统：' + (this.structure.systemId.length > 0 ? this.structure.systemId : '未知'))
                .fontSize(14).fontColor('#707D76').width('100%');
              Button(this.isFav ? '❤ 已收藏' : '♡ 收藏')
                .type(ButtonType.Normal).height(34)
                .backgroundColor(this.isFav ? ORANGE : '#E7EBE4')
                .fontColor(this.isFav ? Color.White : GREEN).fontSize(13)
                .onClick((): void => { this.toggleFavorite(); });
            }.width('100%').padding(16).backgroundColor(Color.White).borderRadius(12)
              .alignItems(HorizontalAlign.Start);

            Column({ space: 8 }) {
              Text(this.editingId.length > 0 ? '编辑笔记' : '新增笔记')
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
              TextArea({ text: this.draft, placeholder: '为该结构记录学习笔记…' })
                .height(110).backgroundColor(BEIGE)
                .onChange((value: string): void => { this.draft = value; });
              if (this.error.length > 0) {
                Text(this.error).fontSize(13).fontColor('#A83B31').width('100%');
              }
              Row({ space: 10 }) {
                Button(this.editingId.length > 0 ? '保存修改' : '保存笔记')
                  .type(ButtonType.Normal).height(34).backgroundColor(GREEN).fontColor(Color.White).fontSize(13)
                  .onClick((): void => { this.saveNote(); });
                if (this.editingId.length > 0) {
                  Button('取消编辑').type(ButtonType.Normal).height(34)
                    .backgroundColor('#E7EBE4').fontColor(GREEN).fontSize(13)
                    .onClick((): void => this.cancelEdit());
                }
              }.width('100%');
            }.width('100%').padding(16).backgroundColor(Color.White).borderRadius(12)
              .alignItems(HorizontalAlign.Start);

            Text('学习笔记（' + this.notes.length + '）')
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
            if (this.notes.length === 0) {
              Text('该结构暂无笔记。').fontSize(14).fontColor('#707D76').width('100%');
            }
            ForEach(this.notes, (note: Note): void => {
              Column({ space: 6 }) {
                Text(note.content).fontSize(14).fontColor('#20332E').width('100%');
                Row({ space: 12 }) {
                  Text('更新于 ' + formatTime(note.updatedAt)).fontSize(12).fontColor('#9AA6A0').layoutWeight(1);
                  Button('编辑').type(ButtonType.Normal).height(28).backgroundColor('#E7EBE4')
                    .fontColor(GREEN).fontSize(12).onClick((): void => this.startEdit(note));
                  Button('删除').type(ButtonType.Normal).height(28).backgroundColor('#F3E3DC')
                    .fontColor(ORANGE).fontSize(12).onClick((): void => { this.deleteNote(note.id); });
                }.width('100%');
              }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(12)
                .alignItems(HorizontalAlign.Start);
            }, (note: Note): string => note.id);
          }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 16 });
        }.layoutWeight(1).width('100%');
      }
    }.width('100%').height('100%').backgroundColor(BEIGE);
  }
}
