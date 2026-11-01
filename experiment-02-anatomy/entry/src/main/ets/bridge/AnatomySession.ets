// 人体浏览模块 · 会话层（对其他模块公开的集成接口）。
//
// 职责：
//   1. 持有唯一一份 3D 页面桥接会话（WebviewController、就绪状态、加载进度）。
//   2. 提供「统一的结构选中事件」：onSelection，供收藏、历史、详情模块订阅。
//   3. 提供「按结构 ID 定位」：locate(id)，模型未加载完成时自动排队，就绪后补发。
//   4. 提供系统切换、隔离、分解、复位等原生到 Web 的控制指令。
//
// 只读引用者：pages/StructureDetail、pages/Favorites、pages/History、store/AnatomyStore。
import { webview } from '@kit.ArkWeb';
import { SystemInfo } from '../model/Anatomy';
import { AnatomyBridge, AnatomyCalls } from './AnatomyBridge';

// —— 对外数据类型 ——

// 当前选中结构（Web 回传 + 本地补全系统名与颜色）。
export interface AnatomySelection {
  id: string;
  name: string;
  systemId: string;
  systemName: string;
  systemColor: string;
}

export type AnatomyLoadState = 'idle' | 'loading' | 'ready' | 'error';

export interface AnatomyLoadSnapshot {
  state: AnatomyLoadState;
  progress: number;      // 0-100
  message: string;       // 出错或提示文案
}

// 定位/搜索的调度结果。
// 返回值：queued（模型未就绪，已登记待发）| sent（指令已发出）| rejected（空参数或加载失败）
// 回调值：queued（已登记）| found（已定位）| not-found（无匹配结构）
export type LocateResult = 'queued' | 'sent' | 'found' | 'not-found' | 'rejected';

export type SelectionListener = (selection: AnatomySelection) => void;
export type LoadStateListener = (snapshot: AnatomyLoadSnapshot) => void;
export type LocateResultListener = (result: LocateResult, target: string) => void;

// —— 解剖系统预设（与 human-atlas 构建产物一致，离线可用）——
export const ANATOMY_SYSTEMS: SystemInfo[] = [
  { id: 'skeletal', name: '骨骼系统', color: '#e2d9ba' },
  { id: 'muscular', name: '肌肉系统', color: '#a85b50' },
  { id: 'cardiac', name: '心脏', color: '#b96760' },
  { id: 'sensory', name: '感觉器官', color: '#b0c8ce' },
  { id: 'arterial', name: '动脉', color: '#c05245' },
  { id: 'venous', name: '静脉', color: '#527c9f' },
  { id: 'nervous', name: '神经系统', color: '#d8b565' },
  { id: 'respiratory', name: '呼吸系统', color: '#b98991' },
  { id: 'digestive', name: '消化系统', color: '#b8916b' },
  { id: 'urinary', name: '泌尿系统', color: '#b47961' },
  { id: 'lymphatic', name: '淋巴系统', color: '#879f7c' },
  { id: 'endocrine', name: '内分泌系统', color: '#c5a09a' },
  { id: 'reproductive', name: '生殖系统', color: '#bda098' },
  { id: 'integumentary', name: '体表', color: '#ba9b7d' },
  { id: 'connective', name: '结缔组织', color: '#aec3bb' }
];

// Web 侧默认隐藏体表，与 human-atlas 初始可见集合保持一致。
export const DEFAULT_VISIBLE_SYSTEM_IDS: string[] = ANATOMY_SYSTEMS
  .filter((s: SystemInfo): boolean => s.id !== 'integumentary')
  .map((s: SystemInfo): string => s.id);

// 桥接就绪后若分块进度长时间未到 100，按此时限兜底放行排队中的定位请求。
const READY_FALLBACK_MS: number = 25000;
const PENDING_LIMIT: number = 16;

// 常用中文名 → Human Atlas（BodyParts3D）英文名关键词，让中文输入也能命中搜索。
const ALIAS_CN: string[] = [
  '心脏', '肝', '肺', '肾', '胃', '脾', '胰', '膀胱', '气管', '大脑', '小脑', '脊髓',
  '股骨', '颅骨', '肋骨', '椎骨', '肩胛骨', '肱骨', '桡骨', '尺骨', '甲状腺', '子宫',
  '主动脉', '静脉', '神经', '肌肉'
];
const ALIAS_EN: string[] = [
  'heart', 'liver', 'lung', 'kidney', 'stomach', 'spleen', 'pancrea', 'bladder', 'trachea',
  'brain', 'cerebellum', 'spinal cord', 'femur', 'skull', 'rib', 'vertebra', 'scapula',
  'humerus', 'radius', 'ulna', 'thyroid', 'uterus', 'aorta', 'vein', 'nerve', 'muscle'
];

interface PendingCommand {
  kind: string;      // 'id' 按结构 ID 定位 / 'search' 按名称搜索定位
  target: string;    // 原始参数（结构 ID 或查询词）
  expr: string;      // 待执行的 runJavaScript 表达式
}

export class AnatomySession {
  private static instance: AnatomySession | null = null;

  static shared(): AnatomySession {
    if (AnatomySession.instance === null) {
      AnatomySession.instance = new AnatomySession();
    }
    return AnatomySession.instance;
  }

  private bridgeProxy: AnatomyBridge;

  private controller: webview.WebviewController | null = null;
  private webReady: boolean = false;
  private bridgeReady: boolean = false;
  private modelSettled: boolean = false;
  private progress: number = 0;
  private state: AnatomyLoadState = 'idle';
  private message: string = '';
  private current: AnatomySelection | null = null;
  private visibleSystemIds: string[] = DEFAULT_VISIBLE_SYSTEM_IDS.slice();
  private pending: PendingCommand[] = [];
  private selectionListeners: SelectionListener[] = [];
  private loadListeners: LoadStateListener[] = [];
  private locateListeners: LocateResultListener[] = [];
  private fallbackTimer: number = -1;

  private constructor() {
    this.bridgeProxy = new AnatomyBridge();
    // 桥接回调全部转到会话自身的方法：桥接对象只做事件转发，不持有业务状态。
    this.bridgeProxy.setOnReady((): void => this.onWebReady());
    this.bridgeProxy.setOnBridgeReady((): void => this.onBridgeReady());
    this.bridgeProxy.setOnProgress((progress: number): void => this.onProgressChange(progress));
    this.bridgeProxy.setOnSelect((id: string, name: string, systemId: string): void =>
      this.onStructureSelected(id, name, systemId));
    this.bridgeProxy.setOnError((message: string): void => this.onWebError(message));
  }

  // —— 页面挂载 ——

  getBridge(): AnatomyBridge {
    return this.bridgeProxy;
  }

  bindController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  unbindController(): void {
    this.controller = null;
    clearTimeout(this.fallbackTimer);
    this.fallbackTimer = -1;
    this.webReady = false;
    this.bridgeReady = false;
    this.modelSettled = false;
    this.progress = 0;
    this.state = 'idle';
    this.message = '';
    this.current = null;
  }

  // 当前绑定控制器的页面；页面返回时用它判断是否需要重新接管。
  boundController(): webview.WebviewController | null {
    return this.controller;
  }

  // 页面从隐藏状态重新可见时探测 Web 侧桥接是否仍然可用。
  // Web 页面没有重新加载就不会再次触发 onBridgeReady，只能靠脚本确认。
  reprobe(): void {
    if (this.controller === null || this.state === 'error') {
      return;
    }
    this.run('(window.__atlasBridge ? "1" : "0")').then((raw: string): void => {
      if (raw === '1') {
        this.webReady = true;
        this.bridgeReady = true;
        this.progress = 100;
        this.modelSettled = true;
        this.trimState();
      }
    }).catch((): void => {
    });
  }

  // 页面开始加载时调用：复位就绪状态，但保留排队中的定位请求。
  resetLoad(): void {
    clearTimeout(this.fallbackTimer);
    this.fallbackTimer = -1;
    this.webReady = false;
    this.bridgeReady = false;
    this.modelSettled = false;
    this.progress = 0;
    this.state = this.controller !== null ? 'loading' : 'idle';
    this.message = '';
    this.current = null;
    this.notifyLoad();
  }

  // —— 状态查询（供其他模块展示）——

  snapshot(): AnatomyLoadSnapshot {
    return { state: this.state, progress: this.progress, message: this.message };
  }

  isReady(): boolean {
    return this.controller !== null && this.state !== 'error' && this.bridgeReady &&
      (this.progress >= 100 || this.modelSettled);
  }

  currentSelection(): AnatomySelection | null {
    return this.current;
  }

  systems(): SystemInfo[] {
    return ANATOMY_SYSTEMS;
  }

  visibleSystems(): string[] {
    return this.visibleSystemIds.slice();
  }

  systemNameOf(systemId: string): string {
    const hit: SystemInfo | undefined = ANATOMY_SYSTEMS
      .find((s: SystemInfo): boolean => s.id === systemId);
    if (hit !== undefined) {
      return hit.name;
    }
    if (systemId === 'concept' || systemId === '') {
      return '解剖概念';
    }
    return systemId;
  }

  systemColorOf(systemId: string): string {
    const hit: SystemInfo | undefined = ANATOMY_SYSTEMS
      .find((s: SystemInfo): boolean => s.id === systemId);
    return hit !== undefined ? hit.color : '#aec3bb';
  }

  // —— 监听注册 ——

  onSelection(listener: SelectionListener): void {
    if (this.selectionListeners.indexOf(listener) < 0) {
      this.selectionListeners.push(listener);
    }
  }

  offSelection(listener: SelectionListener): void {
    const i: number = this.selectionListeners.indexOf(listener);
    if (i >= 0) {
      this.selectionListeners.splice(i, 1);
    }
  }

  onLoadState(listener: LoadStateListener): void {
    if (this.loadListeners.indexOf(listener) < 0) {
      this.loadListeners.push(listener);
    }
  }

  offLoadState(listener: LoadStateListener): void {
    const i: number = this.loadListeners.indexOf(listener);
    if (i >= 0) {
      this.loadListeners.splice(i, 1);
    }
  }

  onLocateResult(listener: LocateResultListener): void {
    if (this.locateListeners.indexOf(listener) < 0) {
      this.locateListeners.push(listener);
    }
  }

  offLocateResult(listener: LocateResultListener): void {
    const i: number = this.locateListeners.indexOf(listener);
    if (i >= 0) {
      this.locateListeners.splice(i, 1);
    }
  }

  // —— 对外动作 ——

  // 按结构 ID 定位并高亮（收藏、历史、详情模块调用）。
  locate(structureId: string): LocateResult {
    const id: string = (structureId === undefined || structureId === null ? '' : structureId).trim();
    if (id.length === 0) {
      return 'rejected';
    }
    if (this.state === 'error') {
      return 'rejected';
    }
    return this.dispatch({ kind: 'id', target: id, expr: AnatomyCalls.selectPart(id) });
  }

  // 顶部搜索栏：按名称搜索并定位高亮。
  search(query: string): LocateResult {
    const raw: string = (query === undefined || query === null ? '' : query).trim();
    if (raw.length === 0) {
      return 'rejected';
    }
    if (this.state === 'error') {
      return 'rejected';
    }
    const q: string = AnatomySession.normalizeQuery(raw);
    return this.dispatch({ kind: 'search', target: raw, expr: AnatomyCalls.search(q) });
  }

  // 中文输入换成 Human Atlas 的英文名关键词；英文查询原样保留。
  private static normalizeQuery(raw: string): string {
    for (let i = 0; i < ALIAS_CN.length; i++) {
      if (raw.indexOf(ALIAS_CN[i]) >= 0) {
        return ALIAS_EN[i];
      }
    }
    return raw;
  }

  // 隔离：只保留当前选中结构。
  isolate(): void {
    this.run(AnatomyCalls.isolate());
  }

  // 分解视图：0 复位，1 最大间距。
  setExplode(value: number): void {
    const v: number = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
    this.run(AnatomyCalls.setExplode(v));
  }

  toggleSystem(systemId: string, visible: boolean): void {
    const id: string = systemId === undefined || systemId === null ? '' : systemId;
    if (id.length === 0) {
      return;
    }
    const next: string[] = [];
    for (let i = 0; i < this.visibleSystemIds.length; i++) {
      if (this.visibleSystemIds[i] !== id) {
        next.push(this.visibleSystemIds[i]);
      }
    }
    if (visible) {
      next.push(id);
    }
    this.visibleSystemIds = next;
    this.run(AnatomyCalls.toggleSystem(id, visible));
  }

  resetView(): void {
    this.current = null;
    this.visibleSystemIds = DEFAULT_VISIBLE_SYSTEM_IDS.slice();
    this.run(AnatomyCalls.reset());
  }

  // —— AnatomyBridgeHandler：Web → 原生回调 ——

  onWebReady(): void {
    this.webReady = true;
    this.armFallbackTimer();
    this.trimState();
  }

  onBridgeReady(): void {
    this.bridgeReady = true;
    this.armFallbackTimer();
    this.trimState();
  }

  onWebError(message: string): void {
    this.message = message.length > 0 ? message : '3D 模型目录加载失败';
    this.state = 'error';
    this.failPending();
    this.notifyLoad();
  }

  onProgressChange(progress: number): void {
    this.progress = Math.max(0, Math.min(100, Math.round(progress)));
    if (this.progress >= 100) {
      this.modelSettled = true;
      clearTimeout(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
    this.trimState();
  }

  onStructureSelected(id: string, name: string, systemId: string): void {
    if (id.length === 0) {
      return;
    }
    const selection: AnatomySelection = {
      id: id,
      name: name.length > 0 ? name : id,
      systemId: systemId,
      systemName: this.systemNameOf(systemId),
      systemColor: this.systemColorOf(systemId)
    };
    this.current = selection;
    for (let i = 0; i < this.selectionListeners.length; i++) {
      this.selectionListeners[i](selection);
    }
  }

  // —— 内部实现 ——

  private trimState(): void {
    if (this.state === 'error') {
      return;
    }
    if (this.isReady()) {
      this.state = 'ready';
      this.message = '';
      this.notifyLoad();
      this.flushPending();
      return;
    }
    this.state = this.controller !== null ? 'loading' : 'idle';
    this.notifyLoad();
  }

  private armFallbackTimer(): void {
    if (this.fallbackTimer !== -1 || this.modelSettled) {
      return;
    }
    this.fallbackTimer = setTimeout((): void => {
      this.fallbackTimer = -1;
      if (this.progress < 100) {
        // 分块进度长时间未满：仍视为可用，避免定位请求被永久阻塞。
        this.modelSettled = true;
        this.trimState();
      }
    }, READY_FALLBACK_MS);
  }

  private dispatch(command: PendingCommand): LocateResult {
    if (!this.isReady()) {
      this.enqueue(command);
      this.notifyLocate('queued', command.target);
      return 'queued';
    }
    this.execute(command);
    return 'sent';
  }

  private execute(command: PendingCommand): void {
    this.run(command.expr).then((raw: string): void => {
      const matched: boolean = raw === 'true';
      this.notifyLocate(matched ? 'found' : 'not-found', command.target);
    }).catch((): void => {
      this.notifyLocate('not-found', command.target);
    });
  }

  private enqueue(command: PendingCommand): void {
    for (let i = 0; i < this.pending.length; i++) {
      if (this.pending[i].kind === command.kind && this.pending[i].target === command.target) {
        return;
      }
    }
    this.pending.push(command);
    while (this.pending.length > PENDING_LIMIT) {
      this.pending.shift();
    }
  }

  private flushPending(): void {
    if (!this.isReady() || this.pending.length === 0) {
      return;
    }
    const queue: PendingCommand[] = this.pending;
    this.pending = [];
    for (let i = 0; i < queue.length; i++) {
      this.execute(queue[i]);
    }
  }

  private failPending(): void {
    const queue: PendingCommand[] = this.pending;
    this.pending = [];
    for (let i = 0; i < queue.length; i++) {
      this.notifyLocate('not-found', queue[i].target);
    }
  }

  private notifyLoad(): void {
    const snap: AnatomyLoadSnapshot = { state: this.state, progress: this.progress, message: this.message };
    for (let i = 0; i < this.loadListeners.length; i++) {
      this.loadListeners[i](snap);
    }
  }

  private notifyLocate(result: LocateResult, target: string): void {
    for (let i = 0; i < this.locateListeners.length; i++) {
      this.locateListeners[i](result, target);
    }
  }

  private run(expr: string): Promise<string> {
    const controller: webview.WebviewController | null = this.controller;
    if (controller === null) {
      return Promise.resolve('');
    }
    try {
      return controller.runJavaScript(expr);
    } catch (e) {
      return Promise.resolve('');
    }
  }
}
