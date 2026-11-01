import { common } from '@kit.AbilityKit';
import { HistoryItem, SelectedStructure, formatTime } from '../model/Anatomy';
import { buildLocateParams } from '../model/AnatomyRules';
import { AnatomyStore } from '../store/AnatomyStore';

const GREEN: string = '#214E45';
const BEIGE: string = '#F5F2EB';
const ORANGE: string = '#A85B31';

@Entry
@Component
struct History {
  @State private items: HistoryItem[] = [];
  @State private ready: boolean = false;
  @State private error: string = '';
  private store?: AnatomyStore;

  aboutToAppear(): void {
    this.openStore();
  }

  onPageShow(): void {
    if (this.store) this.load();
  }

  private async openStore(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = await AnatomyStore.open(ctx);
      this.ready = true;
      await this.load();
    } catch (e) {
      this.error = '本地数据初始化失败，请重试。';
    }
  }

  private async load(): Promise<void> {
    if (!this.store) return;
    this.items = await this.store.listHistory();
  }

  private async clear(): Promise<void> {
    if (!this.store) return;
    await this.store.clearHistory();
    await this.load();
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空浏览历史',
      message: '将删除全部浏览记录，收藏与学习笔记不受影响。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '清空', fontColor: ORANGE, action: (): void => { this.clear(); } }
    });
  }

  /** 返回人体浏览页并定位到该结构（导航参数约定见 model/Anatomy.ts）。 */
  private locate(item: HistoryItem): void {
    const structure: SelectedStructure = { id: item.id, name: item.name, systemId: item.systemId };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/AnatomyBrowser', params: buildLocateParams(structure)
    }).catch((): void => { this.error = '打开人体浏览页失败，请重试。'; });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('← 返回').type(ButtonType.Normal).height(36)
          .backgroundColor('#E7EBE4').fontColor(GREEN)
          .onClick((): void => this.getUIContext().getRouter().back());
        Text('浏览历史').fontSize(18).fontWeight(FontWeight.Bold).fontColor(GREEN).layoutWeight(1);
        if (this.items.length > 0) {
          Button('清空').type(ButtonType.Normal).height(32)
            .backgroundColor('#F3E3DC').fontColor(ORANGE).fontSize(13)
            .onClick((): void => this.confirmClear());
        }
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 });

      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor('#A83B31').padding({ left: 12, right: 12, bottom: 6 }).width('100%');
      }

      if (this.items.length === 0) {
        Column({ space: 12 }) {
          Text('暂无浏览记录').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#526170');
          Text('在人体浏览页点选结构后会自动记录，点击记录即可回到模型定位。').fontSize(14).fontColor('#707D76');
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (item: HistoryItem): void => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 6 }) {
                  Text(item.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
                  Text('所属系统：' + (item.systemId.length > 0 ? item.systemId : '未知'))
                    .fontSize(13).fontColor('#707D76').width('100%');
                  Text('访问于 ' + formatTime(item.visitedAt)).fontSize(12).fontColor('#9AA6A0').width('100%');
                }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                Button('定位模型').type(ButtonType.Normal).height(32).backgroundColor(GREEN)
                  .fontColor(Color.White).fontSize(13).onClick((): void => this.locate(item));
              }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(12);
            }
          }, (item: HistoryItem): string => item.id);
        }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 12 });
      }
    }.width('100%').height('100%').backgroundColor(BEIGE);
  }
}
