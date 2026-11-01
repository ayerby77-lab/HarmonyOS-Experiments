import { ArkAFIntent } from '../model/ArkAFIntent';

@Entry
@Component
struct Index {
  @State private navigationError: string = '';

  private async openPage(page: string): Promise<void> {
    try {
      await this.getUIContext().getRouter().pushUrl({ url: `pages/${page}` });
      this.navigationError = '';
    } catch (error) {
      this.navigationError = '页面打开失败，请再次点击重试。';
    }
  }

  /**
   * 带问题进入问答页。question 写进一次性 AppStorage 通道，KnowledgeQA
   * aboutToAppear 会读取并自动提交；未传 question 时走普通入口。
   */
  private openKnowledgeQA(question?: string): void {
    if (question && question.trim().length > 0) {
      ArkAFIntent.publishQuestion(question.trim(), true);
    }
    this.openPage('KnowledgeQA');
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('人体解剖学习').fontSize(30).fontWeight(FontWeight.Bold)
        Text('课程项目 · 基础框架').fontSize(16).fontColor('#526170')
        Button('人体浏览').width('100%').onClick(() => this.openPage('AnatomyBrowser'))
        Button('结构详情').width('100%').onClick(() => this.openPage('StructureDetail'))
        Button('收藏夹').width('100%').onClick(() => this.openPage('Favorites'))
        Button('浏览历史').width('100%').onClick(() => this.openPage('History'))
        Button('课程知识问答').width('100%').onClick(() => this.openKnowledgeQA())
        Button('课程资料管理').width('100%').onClick(() => this.openPage('KnowledgeManage'))
        Button('关于').width('100%').onClick(() => this.openPage('About'))
        if (this.navigationError.length > 0) {
          Text(this.navigationError).fontColor('#B42318')
        }
        Text('各业务页面已预留入口，核心功能将在后续任务中实现。')
          .fontSize(14).fontColor('#526170')
      }.width('100%').padding(24)
    }.width('100%').height('100%').backgroundColor('#F5F7FA')
  }
}
