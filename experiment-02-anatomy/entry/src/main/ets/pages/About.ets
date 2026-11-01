// 关于页 · Human Atlas 与 BodyParts3D 的授权与来源署名（角色 A 独占文件）。
// 署名要求：保留原项目（MIT）与解剖数据（CC BY 4.0）的授权信息，不得删除。

const GREEN: string = '#214E45';
const BEIGE: string = '#F5F2EB';
const CHIP: string = '#E7EBE4';

interface CreditItem {
  name: string;
  detail: string;
  license: string;
  url: string;
}

const APP_URL: string = 'https://github.com/ashemag/human-atlas';
const DATA_URL: string = 'https://lifesciencedb.jp/bp3d/';

const CREDITS: CreditItem[] = [
  {
    name: 'Human Atlas（应用与交互代码）',
    detail: '提供 3D 人体交互浏览、结构检索与系统切换的实现。本应用为其课程实验移植版本。',
    license: 'MIT License',
    url: APP_URL
  },
  {
    name: 'BodyParts3D 4.0（解剖模型数据）',
    detail: '© The Database Center for Life Science (DBCLS)。模型按 CC BY 4.0 授权，',
    license: 'CC Attribution 4.0 International (CC BY 4.0)',
    url: DATA_URL
  }
];

@Entry
@Component
struct About {
  build() {
    Column() {
      Row({ space: 8 }) {
        Button('← 返回').type(ButtonType.Normal).height(36)
          .backgroundColor(CHIP).fontColor(GREEN)
          .onClick((): void => this.getUIContext().getRouter().back());
        Text('关于').fontSize(18).fontWeight(FontWeight.Bold).fontColor(GREEN).layoutWeight(1);
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 });

      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 6 }) {
            Text('人体解剖学习').fontSize(22).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
            Text('离线 3D 人体解剖浏览器 · 课程项目').fontSize(14).fontColor('#707D76').width('100%');
          }.width('100%').padding(16).backgroundColor(Color.White).borderRadius(12)
            .alignItems(HorizontalAlign.Start);

          Text('授权与数据来源').fontSize(15).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');

          ForEach(CREDITS, (item: CreditItem): void => {
            Column({ space: 6 }) {
              Text(item.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#20332E').width('100%');
              Text(item.detail).fontSize(13).fontColor('#526170').lineHeight(20).width('100%');
              Text('授权：' + item.license).fontSize(13).fontColor(GREEN).width('100%');
              Row({ space: 6 }) {
                Text('来源：').fontSize(12).fontColor('#9AA6A0');
                Text(item.url).fontSize(12).fontColor('#A85B31').layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
              }.width('100%');
            }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(12)
              .alignItems(HorizontalAlign.Start);
          }, (item: CreditItem): string => item.name);

          Text('说明').fontSize(15).fontWeight(FontWeight.Bold).fontColor(GREEN).width('100%');
          Column({ space: 6 }) {
            Text('· 3D 模型与数据已随应用离线打包，断网状态下仍可旋转、缩放、点选与检索。')
              .fontSize(13).fontColor('#526170').lineHeight(21).width('100%');
            Text('· 本应用仅用于教学演示，未对原始模型与数据做再授权；使用时请遵循上述许可证。')
              .fontSize(13).fontColor('#526170').lineHeight(21).width('100%');
            Text('· 项目地址（供核对署名）：').fontSize(13).fontColor('#707D76').width('100%');
            Text(APP_URL).fontSize(12).fontColor('#A85B31').width('100%')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }.width('100%').padding(14).backgroundColor(Color.White).borderRadius(12)
            .alignItems(HorizontalAlign.Start);
        }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 16 });
      }.layoutWeight(1).width('100%');
    }.width('100%').height('100%').backgroundColor(BEIGE);
  }
}
