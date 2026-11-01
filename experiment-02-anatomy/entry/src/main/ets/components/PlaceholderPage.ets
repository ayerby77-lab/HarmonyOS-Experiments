@Component
export struct PlaceholderPage {
  title: string = '';
  description: string = '';

  build() {
    Column({ space: 24 }) {
      Text(this.title).fontSize(28).fontWeight(FontWeight.Bold)
      Text(this.description).fontSize(17).fontColor('#526170').lineHeight(28)
      Button('返回').onClick(() => this.getUIContext().getRouter().back())
    }.width('100%').height('100%').padding(24)
    .justifyContent(FlexAlign.Center).backgroundColor('#F5F7FA')
  }
}
