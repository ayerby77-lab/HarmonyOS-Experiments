import { DocumentChangeEvent } from '../model/Knowledge';

/**
 * 资料变更事件类型。
 * 供检索模块（Agent D）订阅，实现索引的增量更新。
 */
export type KnowledgeChangeListener = (event: DocumentChangeEvent) => void;

/**
 * 资料变更事件总线。
 *
 * ## 与检索模块（Agent D）的索引更新协议
 *
 * 事件类型：
 * - `created`：新增资料，附带新版本全部片段。检索模块应将片段加入索引。
 * - `updated`：修改资料，`previousRevision` 为旧版本，`revision` 为新版本，
 *   `segments` 为新版本全部片段。检索模块应先移除旧版本片段，再加入新版本。
 * - `deleted`：删除资料，`segments` 为空数组。检索模块应移除该资料全部片段。
 *
 * 幂等性：
 * - 事件携带 `documentId` + `revision`，检索模块可据此去重。
 * - 若检索模块重启，可调用 `KnowledgeService.getAllActiveSegments()` 全量重建。
 *
 * 版本校验：
 * - 检索模块在写入向量前应校验 `documentRevision` 与资料当前版本一致，
 *   避免旧版本异步任务覆盖新版本。
 */
export class KnowledgeEventBus {
  private listeners: Set<KnowledgeChangeListener> = new Set();
  private history: DocumentChangeEvent[] = [];
  private readonly maxHistory = 100;

  subscribe(listener: KnowledgeChangeListener): () => void {
    this.listeners.add(listener);
    // 返回取消订阅函数
    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(event: DocumentChangeEvent): void {
    this.history.push(event);
    if (this.history.length > this.maxHistory) {
      this.history.shift();
    }
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (e) {
        // 单个监听器异常不影响其他监听器
        console.error(`KnowledgeEventBus listener error: ${JSON.stringify(e)}`);
      }
    }
  }

  /** 获取最近的事件历史（供检索模块启动时回放） */
  getHistory(): DocumentChangeEvent[] {
    return [...this.history];
  }

  listenerCount(): number {
    return this.listeners.size;
  }
}
