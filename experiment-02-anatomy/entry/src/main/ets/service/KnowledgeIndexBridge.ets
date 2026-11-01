import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeService } from './KnowledgeService';
import { IIndexSyncManager, IndexBuildResult } from './types';
import { DocumentChangeEvent } from '../model/Knowledge';

const TAG = 'KnowledgeIndexBridge';

/**
 * 资料模块（Agent C）与检索模块（Agent D）之间的索引同步桥。
 *
 * 职责：
 *   1. 订阅 KnowledgeService 的变更事件，转发给 IndexSyncManager。
 *   2. 启动时从 RDB 读取全部有效片段，全量灌入 IndexSyncManager。
 *
 * 索引更新协议（与 Agent D 约定）：
 *   - created/updated → IndexSyncManager.handleDocumentChanged(docId, revision, segments, onComplete)
 *   - deleted         → IndexSyncManager.handleDocumentDeleted(docId)
 *   - 全量重建        → 逐个调用 handleDocumentChanged
 */
export class KnowledgeIndexBridge {
  private knowledge: KnowledgeService;
  private indexManager: IIndexSyncManager;
  private unsubscribe: (() => void) | null = null;

  constructor(knowledge: KnowledgeService, indexManager: IIndexSyncManager) {
    this.knowledge = knowledge;
    this.indexManager = indexManager;
  }

  /**
   * 启动桥接：先全量同步已有资料，再订阅增量变更。
   */
  async start(): Promise<void> {
    await this.knowledge.ensureReady();

    // 全量同步：读取所有资料及其当前版本片段
    const docs = await this.knowledge.listDocuments();
    for (const doc of docs) {
      const segments = await this.knowledge.getSegments(doc.id);
      this.indexManager.handleDocumentChanged(
        doc.id,
        doc.revision,
        segments,
        (result: IndexBuildResult): void => {
          if (!result.ok) {
            hilog.warn(0x0000, TAG, 'Index build failed for %{public}s: %{public}s',
              doc.id, result.message ?? '');
          }
        }
      );
    }
    hilog.info(0x0000, TAG, 'Full sync completed for %{public}d documents.', docs.length);

    // 订阅增量变更
    this.unsubscribe = this.knowledge.subscribeChanges((event: DocumentChangeEvent): void => {
      this.handleChange(event);
    });
  }

  private handleChange(event: DocumentChangeEvent): void {
    switch (event.type) {
      case 'created':
      case 'updated':
        this.indexManager.handleDocumentChanged(
          event.documentId,
          event.revision,
          event.segments,
          (result: IndexBuildResult): void => {
            if (!result.ok) {
              hilog.warn(0x0000, TAG, 'Index %{public}s failed for %{public}s rev %{public}d: %{public}s',
                event.type, event.documentId, event.revision, result.message ?? '');
            } else {
              hilog.info(0x0000, TAG, 'Index %{public}s ok for %{public}s rev %{public}d',
                event.type, event.documentId, event.revision);
            }
          }
        );
        break;
      case 'deleted':
        this.indexManager.handleDocumentDeleted(event.documentId);
        hilog.info(0x0000, TAG, 'Index delete for %{public}s', event.documentId);
        break;
    }
  }

  stop(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }
}
