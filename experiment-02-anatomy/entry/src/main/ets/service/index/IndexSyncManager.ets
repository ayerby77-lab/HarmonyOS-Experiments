// 索引同步管理器。
//
// 职责：
//   1. 接收 Agent C（KnowledgeIndexBridge）的资料变更通知，
//      异步生成 embedding 并 upsert 到向量库 + HybridRetrievalService。
//   2. 维护 generation 计数器，防止旧任务覆盖新资料。
//      资料每次修改 → generation + 1；旧任务完成时如果发现自己的 generation
//      落后于当前最新 generation，就静默丢弃。
//   3. 暴露 pendingCount 供 UI 显示「正在索引」状态。

import { KnowledgeSegment } from '../../model/Knowledge';
import {
  IIndexSyncManager, IndexBuildResult,
  IEmbeddingService, IVectorStore, IHybridRetrievalService,
  EmbeddingResult, VectorRecord
} from '../types';

interface DocGenerationState {
  currentGeneration: number;
  currentRevision: number;
}

interface PendingTask {
  documentId: string;
  revision: number;
  generation: number;
  segments: KnowledgeSegment[];
  documentTitle: string;
  source: string;
  startedAt: number;
}

export class IndexSyncManager implements IIndexSyncManager {
  private readonly emb: IEmbeddingService;
  private readonly store: IVectorStore;
  private readonly retrieval: IHybridRetrievalService;

  private readonly docState: Map<string, DocGenerationState> = new Map();
  private readonly running: PendingTask[] = [];

  constructor(
    emb: IEmbeddingService,
    store: IVectorStore,
    retrieval: IHybridRetrievalService
  ) {
    this.emb = emb;
    this.store = store;
    this.retrieval = retrieval;
  }

  get pendingCount(): number {
    return this.running.length;
  }

  handleDocumentChanged(
    documentId: string,
    revision: number,
    segments: KnowledgeSegment[],
    onComplete: (result: IndexBuildResult) => void,
    documentTitle: string = '',
    source: string = ''
  ): void {
    const state = this.docState.get(documentId);
    const newGeneration = (state?.currentGeneration ?? 0) + 1;
    const nextState: DocGenerationState = {
      currentGeneration: newGeneration,
      currentRevision: revision,
    };
    this.docState.set(documentId, nextState);

    const task: PendingTask = {
      documentId,
      revision,
      generation: newGeneration,
      segments,
      documentTitle,
      source,
      startedAt: Date.now(),
    };

    this.running.push(task);

    void this.runTask(task).then((res: IndexBuildResult): void => {
      this.removeRunning(task);
      onComplete(res);
    }).catch((e: Error): void => {
      this.removeRunning(task);
      const failed: IndexBuildResult = {
        documentId,
        revision,
        generation: newGeneration,
        ok: false,
        message: e instanceof Error ? e.message : String(e),
      };
      onComplete(failed);
    });
  }

  handleDocumentDeleted(documentId: string): void {
    const state = this.docState.get(documentId);
    const nextState: DocGenerationState = {
      currentGeneration: (state?.currentGeneration ?? 0) + 1,
      currentRevision: -1,
    };
    this.docState.set(documentId, nextState);
    this.store.removeByDocument(documentId);
    if (this.retrieval.removeDocumentSegments) {
      this.retrieval.removeDocumentSegments(documentId);
    }
  }

  private async runTask(task: PendingTask): Promise<IndexBuildResult> {
    const before = this.docState.get(task.documentId);
    if (!before || before.currentGeneration !== task.generation) {
      const superseded: IndexBuildResult = {
        documentId: task.documentId,
        revision: task.revision,
        generation: task.generation,
        ok: false,
        message: 'superseded before start',
      };
      return superseded;
    }

    this.store.removeByDocument(task.documentId, task.revision - 1);
    if (this.retrieval.removeDocumentSegments) {
      this.retrieval.removeDocumentSegments(task.documentId);
    }

    if (task.segments.length === 0) {
      const empty: IndexBuildResult = {
        documentId: task.documentId,
        revision: task.revision,
        generation: task.generation,
        ok: true,
        message: 'no segments, cleared old vectors',
      };
      return empty;
    }

    const texts: string[] = task.segments.map((s: KnowledgeSegment): string => s.content);
    const embeddings: EmbeddingResult[] = await this.emb.embedBatch(texts);

    const after = this.docState.get(task.documentId);
    if (!after || after.currentGeneration !== task.generation || after.currentRevision !== task.revision) {
      const superseded: IndexBuildResult = {
        documentId: task.documentId,
        revision: task.revision,
        generation: task.generation,
        ok: false,
        message: 'superseded during embed (newer version arrived)',
      };
      return superseded;
    }

    const records: VectorRecord[] = embeddings.map((e: EmbeddingResult, i: number): VectorRecord => {
      const rec: VectorRecord = {
        segmentId: task.segments[i].id,
        documentId: task.documentId,
        documentRevision: task.revision,
        vector: e.vector,
      };
      return rec;
    });
    this.store.upsertBatch(records);

    if (this.retrieval.registerSegments) {
      this.retrieval.registerSegments(task.segments, task.documentTitle, task.source);
    }

    const done: IndexBuildResult = {
      documentId: task.documentId,
      revision: task.revision,
      generation: task.generation,
      ok: true,
    };
    return done;
  }

  private removeRunning(task: PendingTask): void {
    const idx = this.running.indexOf(task);
    if (idx !== -1) this.running.splice(idx, 1);
  }
}
