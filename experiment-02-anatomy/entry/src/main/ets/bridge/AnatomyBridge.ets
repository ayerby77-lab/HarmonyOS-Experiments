// 人体浏览模块 · Web → 原生 桥接层（契约：doc/接口约定.md §6.6）。
//
// AnatomyBridge 实例经 ArkWeb 的 javaScriptProxy 以 window.NativeBridge 暴露给 Web 页面；
// methodList 固定为 5 项，Web 侧调用它们上报事件，原生侧用 setOnXxx 注册回调。
// 桥接对象不直接依赖会话单例：回调默认空实现，close() 后回到空实现，
// 避免页面销毁后 Web 侧回调仍触达已释放的状态。

type ReadyCallback = () => void;
type ProgressCallback = (progress: number) => void;
type SelectCallback = (id: string, name: string, systemId: string) => void;
type ErrorCallback = (message: string) => void;

function noop(): void {
}

export class AnatomyBridge {
  private readyCb: ReadyCallback = noop;
  private bridgeReadyCb: ReadyCallback = noop;
  private progressCb: ProgressCallback = (progress: number): void => {
  };
  private selectCb: SelectCallback = (id: string, name: string, systemId: string): void => {
  };
  private errorCb: ErrorCallback = (message: string): void => {
  };

  // —— javaScriptProxy methodList（固定 5 项）——

  onWebReady(): void {
    this.readyCb();
  }

  onBridgeReady(): void {
    this.bridgeReadyCb();
  }

  onWebError(message: string): void {
    this.errorCb(String(message === undefined || message === null ? '' : message));
  }

  onProgressChange(progress: number): void {
    const value: number = Number(progress);
    this.progressCb(Number.isFinite(value) ? value : 0);
  }

  onStructureSelected(id: string, name: string, systemId: string): void {
    this.selectCb(
      String(id === undefined || id === null ? '' : id),
      String(name === undefined || name === null ? '' : name),
      String(systemId === undefined || systemId === null ? '' : systemId)
    );
  }

  // —— 原生侧注册回调 ——

  setOnReady(cb: ReadyCallback): void {
    this.readyCb = cb;
  }

  setOnBridgeReady(cb: ReadyCallback): void {
    this.bridgeReadyCb = cb;
  }

  setOnProgress(cb: ProgressCallback): void {
    this.progressCb = cb;
  }

  setOnSelect(cb: SelectCallback): void {
    this.selectCb = cb;
  }

  setOnError(cb: ErrorCallback): void {
    this.errorCb = cb;
  }

  // 断开全部回调：页面销毁或会话失效时调用。
  close(): void {
    this.readyCb = noop;
    this.bridgeReadyCb = noop;
    this.progressCb = (progress: number): void => {
    };
    this.selectCb = (id: string, name: string, systemId: string): void => {
    };
    this.errorCb = (message: string): void => {
    };
  }
}

function atlasArgs(args: Object[]): string {
  const parts: string[] = [];
  for (let i: number = 0; i < args.length; i++) {
    parts.push(JSON.stringify(args[i]));
  }
  return parts.join(',');
}

// 原生 → Web：runJavaScript 表达式，结果包成布尔（search / selectPart / isolate 等）。
// 全部带 __atlasBridge 存在性判断：桥接未注册时返回 false 而不是抛错。
export function atlasCall(fnName: string, ...args: Object[]): string {
  return 'JSON.stringify(!!(window.__atlasBridge && window.__atlasBridge.' + fnName +
    '(' + atlasArgs(args) + ')))';
}

// 原生 → Web：runJavaScript 表达式，结果保留结构化值（listSystems / getAtlasInfo 等）。
export function atlasJSON(fnName: string, ...args: Object[]): string {
  return 'JSON.stringify((window.__atlasBridge && window.__atlasBridge.' + fnName +
    '(' + atlasArgs(args) + ')) || null)';
}

// 类型化的调用构造器：会话层使用，避免各处硬编码 __atlasBridge 表达式。
export class AnatomyCalls {
  static search(query: string): string {
    return atlasCall('search', query);
  }

  static selectPart(id: string): string {
    return atlasCall('selectPart', id);
  }

  static isolate(): string {
    return atlasCall('isolate');
  }

  static setExplode(value: number): string {
    return atlasCall('setExplode', value);
  }

  static toggleSystem(systemId: string, visible: boolean): string {
    return atlasCall('toggleSystem', systemId, visible);
  }

  static reset(): string {
    return atlasCall('reset');
  }
}
