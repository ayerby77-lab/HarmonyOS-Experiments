import { common } from '@kit.AbilityKit';
import { Favorite, SelectedStructure, formatTime } from '../model/Anatomy';
import { buildLocateParams } from '../model/AnatomyRules';
import { AnatomyStore } from '../store/AnatomyStore';

const GREEN: string = '#214E45';
const BEIGE: string = '#F5F2EB';
const ORANGE: string = '#A85B31';

@Entry
@Component
struct Favorites {
  @State private items: Favorite[] = [];
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
    this.items = await this.store.listFavorites();
  }

  private async remove(id: string): Promise<void> {
    if (!this.store) return;
    await this.store.removeFavorite(id);
    await this.load();
  }

  /** 返回人体浏览页并定位到该结构（导航参数约定见 model/Anatomy.ts）。 */
  private locate(item: Favorite): void {
    const structure: SelectedStructure = { id: item.id, name: item.name, systemId: item.systemId };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/AnatomyBrowser', params: buildLocateParams(structure)
    }).catch((): void => { this.error = '打开人体浏览页失败，请重试。'; });
  }

  private openDetail(item: Favorite): void {
    const structure: SelectedStructure = { id: item.id, name: item.name, systemId: item.systemId };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/StructureDetail', params: buildLocateParams(structure)
    }).catch((): void => { this.error = '打开结构详情失败，请重试。'; });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('← 返回').type(ButtonType.Normal).height(36)
          .backgroundColor('#E7EBE4').fontColor(GREEN)
          .onClick((): void => this.getUIContext().getRouter().back());
        Text('收藏夹').fontSize(18).fontWeight(FontWeight.Bold).fontColor(GREEN).layoutWeight(1);
        Text(this.items.length + ' 项').fontSize(13).fontColor('#707D76');
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 });

      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor('#A83B31').padding({ left: 12, right: 12, bottom: 6 }).width('100%');
      }

      if (this.items.length === 0) {
        Column({ space: 12 }) {
          Text('暂无收藏').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#526170');
          Text('在人体浏览页点选结构后点击「收藏」，即可在这里快速定位。').fontSize(14).fontColor('#707D76');
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center);
      } else {
        List({ space: 10 }) {
          ForEach(this.items, (item: Favorite): void => {
            ListItem() {
              Column({ space: 8 }) {
                Text(item.name).fontSize(17).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
                Text('所属系统：' + (item.systemName.length > 0 ? item.systemName : item.systemId))
                  .fontSize(13).fontColor('#707D76').width('100%');
                Text('收藏于 ' + formatTime(item.createdAt)).fontSize(12).fontColor('#9AA6A0').width('100%');
                Row({ space: 10 }) {
                  Button('定位模型').type(ButtonType.Normal).height(32).backgroundColor(GREEN)
                    .fontColor(Color.White).fontSize(13).onClick((): void => this.locate(item));
                  Button('笔记').type(ButtonType.Normal).height(32).backgroundColor('#E7EBE4')
                    .fontColor(GREEN).fontSize(13).onClick((): void => this.openDetail(item));
                  Button('取消收藏').type(ButtonType.Normal).height(32).backgroundColor('#F3E3DC')
                    .fontColor(ORANGE).fontSize(13).onClick((): void => { this.remove(item.id); });
                }.width('100%');
              }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(12)
                .alignItems(HorizontalAlign.Start);
            }
          }, (item: Favorite): string => item.id);
        }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 12 });
      }
    }.width('100%').height('100%').backgroundColor(BEIGE);
  }
}
