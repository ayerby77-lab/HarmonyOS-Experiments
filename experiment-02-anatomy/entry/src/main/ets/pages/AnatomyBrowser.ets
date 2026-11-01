// 人体浏览页 · ArkWeb 离线承载 Human Atlas 3D 交互 + 原生工具栏。
// 承接：本地资源导入、资源请求拦截、JSBridge 双向通信、加载状态回传、
//       搜索定位高亮、系统切换、隔离与分解、按结构 ID 定位（含未就绪排队）。
import { webview } from '@kit.ArkWeb';
import { AnatomyRouteParams, SelectedStructure, SystemInfo } from '../model/Anatomy';
import { buildLocateParams, readLocateParams } from '../model/AnatomyRules';
import { mapRawfilePath, mimeOfPath } from '../bridge/AtlasResources';
import {
  ANATOMY_SYSTEMS,
  AnatomyLoadSnapshot,
  AnatomySelection,
  AnatomySession,
  DEFAULT_VISIBLE_SYSTEM_IDS,
  LocateResult,
  LoadStateListener,
  LocateResultListener,
  SelectionListener
} from '../bridge/AnatomySession';

const GREEN: string = '#214E45';
const BEIGE: string = '#F5F2EB';
const CHIP: string = '#E7EBE4';
const ORANGE: string = '#A85B31';

// 加载超时上限，超时后给出可重试的失败状态。
const LOAD_TIMEOUT_MS: number = 30000;

// 资源路径映射（mapRawfilePath / mimeOfPath）见 bridge/AtlasResources.ts，
// 作为纯函数独立于 ArkWeb，便于单测。

@Entry
@Component
struct AnatomyBrowser {
  @State loading: boolean = true;
  @State progress: number = 0;
  @State errorMsg: string = '';
  @State query: string = '';
  @State selection: AnatomySelection | null = null;
  @State visibleIds: string[] = DEFAULT_VISIBLE_SYSTEM_IDS.slice();
  @State showSystems: boolean = false;
  @State showAbout: boolean = false;
  @State explodeLevel: number = 0;

  private controller: webview.WebviewController = new webview.WebviewController();
  private session: AnatomySession = AnatomySession.shared();
  private timeoutTimer: number = -1;
  private lastFocusId: string = '';

  private selectionCb: SelectionListener = (selection: AnatomySelection): void => {
    this.selection = selection;
  };

  private loadCb: LoadStateListener = (snap: AnatomyLoadSnapshot): void => {
    this.progress = snap.progress;
    if (snap.state === 'error') {
      this.loading = false;
      this.errorMsg = snap.message.length > 0 ? snap.message : '3D 模型加载失败';
    } else if (snap.state === 'ready') {
      this.loading = false;
      this.errorMsg = '';
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = -1;
    } else if (snap.state === 'loading') {
      this.loading = true;
    }
  };

  private locateCb: LocateResultListener = (result: LocateResult, target: string): void => {
    if (result === 'queued') {
      this.toast('模型加载中，已登记定位请求：' + target);
    } else if (result === 'found') {
      const hit: AnatomySelection | null = this.session.currentSelection();
      this.toast('已定位并高亮：' + (hit !== null ? hit.name : target));
    } else if (result === 'not-found') {
      this.toast('未找到匹配的结构：' + target);
    }
  };

  aboutToAppear(): void {
    this.session.bindController(this.controller);
    this.session.resetLoad();
    this.session.onSelection(this.selectionCb);
    this.session.onLoadState(this.loadCb);
    this.session.onLocateResult(this.locateCb);
    this.applyFocusParams();
  }

  onPageShow(): void {
    if (this.session.boundController() !== this.controller) {
      // 从收藏/历史返回时可能已有另一个浏览页实例绑定了控制器：重新接管并探测 Web 侧就绪状态。
      this.session.bindController(this.controller);
      this.session.reprobe();
    }
    this.applyFocusParams();
  }

  onPageHide(): void {
    this.lastFocusId = '';
  }

  aboutToDisappear(): void {
    this.session.offSelection(this.selectionCb);
    this.session.offLoadState(this.loadCb);
    this.session.offLocateResult(this.locateCb);
    clearTimeout(this.timeoutTimer);
    this.timeoutTimer = -1;
    if (this.session.boundController() === this.controller) {
      this.session.unbindController();
    }
  }

  // 读取路由参数中的待定位结构 ID（pushUrl 首次进入、back 返回均适用）。
  // 键名遵循 model/Anatomy.ts 的 AnatomyRouteParams：locateId / locateName / locateSystemId。
  private applyFocusParams(): void {
    let raw: AnatomyRouteParams | undefined = undefined;
    try {
      raw = this.getUIContext().getRouter().getParams() as AnatomyRouteParams;
    } catch (e) {
      raw = undefined;
    }
    const found: SelectedStructure | null = readLocateParams(raw);
    if (found === null || found.id === this.lastFocusId) {
      return;
    }
    this.lastFocusId = found.id;
    // 模型尚未就绪时这里返回 queued，由会话层在其后就绪后补发（约定不得重复触发）。
    this.session.locate(found.id);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
    }
  }

  // —— 原生 → Web 操作 ——

  private doSearch(): void {
    const q: string = this.query.trim();
    if (q.length === 0) {
      this.toast('请输入要查找的解剖结构名称');
      return;
    }
    const result: LocateResult = this.session.search(q);
    if (result === 'rejected') {
      this.toast('3D 模型未就绪或加载失败，无法搜索');
    }
  }

  private isolateCurrent(): void {
    if (this.selection === null) {
      this.toast('请先在 3D 画面点选一个结构，或先搜索定位');
      return;
    }
    this.session.isolate();
  }

  private stepExplode(delta: number): void {
    const next: number = Math.max(0, Math.min(1, this.explodeLevel + delta));
    this.explodeLevel = next;
    this.session.setExplode(next);
  }

  private resetAll(): void {
    this.explodeLevel = 0;
    this.selection = null;
    this.session.resetView();
    this.visibleIds = this.session.visibleSystems();
    this.toast('已复位视角与系统可见性');
  }

  private toggleSystem(item: SystemInfo, on: boolean): void {
    this.session.toggleSystem(item.id, on);
    this.visibleIds = this.session.visibleSystems();
  }

  private openDetail(): void {
    const hit: AnatomySelection | null = this.selection;
    if (hit === null) {
      this.toast('请先选择一个解剖结构');
      return;
    }
    const params: AnatomyRouteParams = buildLocateParams({
      id: hit.id, name: hit.name, systemId: hit.systemId
    });
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/StructureDetail',
      params: params
    }).catch((): void => {
      this.toast('详情页打开失败');
    });
  }

  private openPage(url: string): void {
    this.getUIContext().getRouter().pushUrl({ url: url }).catch((): void => {
      this.toast('页面打开失败');
    });
  }

  private back(): void {
    this.getUIContext().getRouter().back();
  }

  private retry(): void {
    this.errorMsg = '';
    this.loading = true;
    this.progress = 0;
    this.session.resetLoad();
    this.armTimeout();
    try {
      this.controller.refresh();
    } catch (e) {
      this.session.onWebError('刷新失败，请返回后重新打开');
    }
  }

  private armTimeout(): void {
    clearTimeout(this.timeoutTimer);
    this.timeoutTimer = setTimeout((): void => {
      this.timeoutTimer = -1;
      if (this.session.snapshot().state !== 'ready') {
        this.session.onWebError('加载超时，请检查资源后重试');
      }
    }, LOAD_TIMEOUT_MS);
  }

  // —— 资源请求拦截：把 Web 侧请求映射回本地 rawfile ——

  private intercept(event: OnInterceptRequestEvent): WebResourceResponse {
    const url: string = event.request.getRequestUrl();
    const path: string = mapRawfilePath(url);
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseEncoding('utf-8');
    if (path.length === 0) {
      response.setResponseCode(404);
      response.setReasonMessage('Not Found');
      response.setResponseMimeType('text/plain');
      response.setResponseData('');
      response.setResponseIsReady(true);
      return response;
    }
    const headers: Header[] = [
      { headerKey: 'Content-Type', headerValue: mimeOfPath(path) },
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Cache-Control', headerValue: 'no-store' }
    ];
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(mimeOfPath(path));
    response.setResponseHeader(headers);
    response.setResponseData($rawfile(path));
    response.setResponseIsReady(true);
    return response;
  }

  @Builder
  systemRow(item: SystemInfo) {
    Row({ space: 10 }) {
      Text('').width(12).height(12).backgroundColor(item.color).borderRadius(6)
      Text(item.name).fontSize(15).fontColor('#20332E').layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.visibleIds.indexOf(item.id) >= 0 })
        .onChange((isOn: boolean): void => this.toggleSystem(item, isOn))
    }.width('100%').padding({ top: 8, bottom: 8 })
  }

  build() {
    Column() {
      // —— 顶部：返回 + 原生搜索栏 ——
      Row({ space: 8 }) {
        Button('←').type(ButtonType.Normal).height(38).width(46)
          .backgroundColor(CHIP).fontColor(GREEN)
          .onClick((): void => this.back());
        TextInput({ placeholder: '搜索解剖结构（如 心脏 / femur）', text: this.query })
          .type(InputType.Normal)
          .height(38).layoutWeight(1)
          .backgroundColor(Color.White)
          .onChange((value: string): void => {
            this.query = value;
          })
          .onSubmit((): void => this.doSearch());
        Button('搜索').type(ButtonType.Normal).height(38)
          .backgroundColor(GREEN).fontColor(Color.White)
          .onClick((): void => this.doSearch());
      }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 6 });

      // —— 选中结构提示条 ——
      if (this.selection !== null) {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(this.selection.name).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(GREEN).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selection.systemName + ' · ' + this.selection.id)
              .fontSize(11).fontColor('#707D76').maxLines(1)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1);
          Button('详情').type(ButtonType.Normal).height(30).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.openDetail());
          Button('隔离').type(ButtonType.Normal).height(30).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.isolateCurrent());
          Button('×').type(ButtonType.Normal).height(30).width(34).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => {
              this.selection = null;
            });
        }.width('100%').padding({ left: 10, right: 10, bottom: 6 })
        .alignItems(VerticalAlign.Center);
      }

      // —— 3D 画面 + 加载/错误覆盖层 ——
      Stack() {
        Web({ src: $rawfile('human-atlas/index.html'), controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .cacheMode(CacheMode.None)
          .backgroundColor('#f2f3f3')
          .javaScriptProxy({
            object: this.session.getBridge(),
            name: 'NativeBridge',
            methodList: ['onWebReady', 'onBridgeReady', 'onWebError', 'onProgressChange', 'onStructureSelected'],
            controller: this.controller
          })
          .onInterceptRequest((event): WebResourceResponse => this.intercept(event))
          .onPageBegin((): void => {
            this.loading = true;
            this.progress = 0;
            this.armTimeout();
          })
          .onPageEnd((): void => {
            clearTimeout(this.timeoutTimer);
            this.timeoutTimer = -1;
          })
          .onErrorReceive((event): void => {
            if (event !== undefined && event.request.isMainFrame()) {
              clearTimeout(this.timeoutTimer);
              this.timeoutTimer = -1;
              this.session.onWebError('3D 页面加载失败，请重试');
            }
          })
          .onHttpErrorReceive((event): void => {
            if (event !== undefined && event.request.isMainFrame()) {
              clearTimeout(this.timeoutTimer);
              this.timeoutTimer = -1;
              this.session.onWebError('3D 页面响应异常，请重试');
            }
          })
          .width('100%').height('100%');

        if (this.loading && this.errorMsg.length === 0) {
          Column({ space: 10 }) {
            LoadingProgress().width(32).height(32).color(GREEN)
            Text('正在加载 3D 解剖模型… ' + this.progress + '%').fontSize(14).fontColor('#526170')
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear }).width('70%')
            Text('2,234 块结构 · 15 个解剖系统 · 完全离线').fontSize(12).fontColor('#8A968F')
          }.width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F2F3F3');
        }

        if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text('3D 模型加载失败').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ORANGE)
            Text(this.errorMsg).fontSize(14).fontColor('#526170').textAlign(TextAlign.Center)
              .padding({ left: 28, right: 28 })
            Row({ space: 12 }) {
              Button('重试').onClick((): void => this.retry());
              Button('返回').backgroundColor('#E7EBE4').fontColor(GREEN)
                .onClick((): void => this.back());
            }
          }.width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F2F3F3');
        }
      }.width('100%').layoutWeight(1);

      // —— 底部工具栏 ——
      Scroll() {
        Row({ space: 8 }) {
          Button('系统').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => {
              this.showSystems = true;
            });
          Button('隔离').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.isolateCurrent());
          Button('分解 +').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.stepExplode(0.25));
          Button('分解 −').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.stepExplode(-0.25));
          Button('复位').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.resetAll());
          Button('收藏夹').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.openPage('pages/Favorites'));
          Button('历史').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => this.openPage('pages/History'));
          Button('关于').type(ButtonType.Normal).height(38).fontSize(13)
            .backgroundColor(CHIP).fontColor(GREEN)
            .onClick((): void => {
              this.showAbout = true;
            });
        }.padding({ left: 10, right: 10 });
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%').padding({ top: 6, bottom: 8 })
      .backgroundColor('#EDE9E0');

      // —— 系统面板 ——
      if (this.showSystems) {
        Column() {
          Column() {
            Row() {
              Text('解剖系统开关').fontSize(17).fontWeight(FontWeight.Medium).fontColor(GREEN)
                .layoutWeight(1)
              Button('关闭').type(ButtonType.Normal).height(30).fontSize(13)
                .backgroundColor(CHIP).fontColor(GREEN)
                .onClick((): void => {
                  this.showSystems = false;
                });
            }.width('100%').margin({ bottom: 4 });
            Scroll() {
              Column() {
                ForEach(ANATOMY_SYSTEMS, (item: SystemInfo): void => {
                  this.systemRow(item);
                }, (item: SystemInfo): string => item.id);
              }.width('100%');
            }.layoutWeight(1).width('100%');
          }
          .width('100%').height('70%')
          .padding(16).backgroundColor(Color.White)
          .borderRadius({ topLeft: 16, topRight: 16 });
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.End)
        .backgroundColor('rgba(0,0,0,0.35)')
        .onClick((): void => {
          this.showSystems = false;
        })
        .position({ x: 0, y: 0 });
      }

      // —— 关于（署名）——
      if (this.showAbout) {
        Column() {
          Column({ space: 10 }) {
            Text('Human Atlas · 人体解剖浏览器').fontSize(17).fontWeight(FontWeight.Bold).fontColor(GREEN);
            Text('应用代码：Human Atlas（github.com/ashemag/human-atlas），MIT License。\n' +
              '解剖数据：BodyParts3D 4.0，© The Database Center for Life Science，' +
              'CC Attribution 4.0 International（CC BY 4.0）。\n' +
              '本页为课程实验移植版本，保留原项目与数据署名；模型已随应用离线打包。')
              .fontSize(13).fontColor('#444').lineHeight(21)
              .textAlign(TextAlign.Start);
            Row({ space: 12 }) {
              Button('查看完整署名').backgroundColor(CHIP).fontColor(GREEN).fontSize(13)
                .onClick((): void => this.openPage('pages/About'));
              Button('关闭').fontSize(13)
                .onClick((): void => {
                  this.showAbout = false;
                });
            }.margin({ top: 6 });
          }
          .padding(20).backgroundColor(Color.White).borderRadius(14)
          .width('88%');
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.4)')
        .position({ x: 0, y: 0 })
        .onClick((): void => {
          this.showAbout = false;
        });
      }
    }
    .width('100%').height('100%').backgroundColor(BEIGE);
  }
}
