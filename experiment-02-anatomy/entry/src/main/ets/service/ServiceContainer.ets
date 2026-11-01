// 服务装配入口：统一创建所有服务实例。
// 默认使用测试替身；生产环境只需在构造参数中开启 useCloud。

import { IEmbeddingService, IVectorStore, IHybridRetrievalService, IIndexSyncManager, IChatService } from './types';
import { KnowledgeSegment } from '../model/Knowledge';
import { TestEmbeddingService } from './embedding/TestEmbeddingService';
import { MemoryVectorStore } from './embedding/MemoryVectorStore';
import { HybridRetrievalService } from './retrieval/HybridRetrievalService';
import { IndexSyncManager } from './index/IndexSyncManager';
import { CloudModelProxy } from './chat/CloudModelProxy';
import { TestCloudModelService } from './chat/TestCloudModelService';
import { KnowledgeIndexBridge } from './KnowledgeIndexBridge';
import { KnowledgeService } from './KnowledgeService';

export interface ServiceContainerOptions {
  useCloud?: boolean;
  cloudFunctionUrl?: string;
  model?: string;
  embedding?: IEmbeddingService;
  vectorStore?: IVectorStore;
  retrieval?: IHybridRetrievalService;
}

export class ServiceContainer {
  readonly emb: IEmbeddingService;
  readonly store: IVectorStore;
  readonly retrieval: IHybridRetrievalService;
  readonly indexManager: IIndexSyncManager;
  readonly chat: IChatService;

  constructor(opts?: ServiceContainerOptions) {
    this.emb = opts?.embedding ?? new TestEmbeddingService();
    this.store = opts?.vectorStore ?? new MemoryVectorStore();
    this.retrieval = opts?.retrieval ?? new HybridRetrievalService(this.emb, this.store);
    this.indexManager = new IndexSyncManager(this.emb, this.store, this.retrieval);

    if (opts?.useCloud) {
      if (!opts.cloudFunctionUrl) {
        throw new Error('cloudFunctionUrl is required when useCloud=true');
      }
      this.chat = new CloudModelProxy({
        functionUrl: opts.cloudFunctionUrl,
        defaultModel: opts.model ?? 'doubao-pro',
      });
    } else {
      this.chat = new TestCloudModelService();
    }
  }

  // 把资料服务（Agent C）接入检索模块（Agent D）：全量同步 + 订阅增量变更。
  async connectKnowledgeService(knowledgeService: KnowledgeService): Promise<KnowledgeIndexBridge> {
    const bridge = new KnowledgeIndexBridge(knowledgeService, this.indexManager);
    await bridge.start();
    return bridge;
  }

  // 向检索模块注册 demo 片段（种子数据）。
  // segments 必须是 KnowledgeSegment 数组（由 SegmentService.split 产生），
  // 已包含正确的 content / seqIndex / documentRevision 等字段。
  seedDocument(
    documentId: string,
    revision: number,
    documentTitle: string,
    source: string,
    segments: KnowledgeSegment[]
  ): void {
    this.indexManager.handleDocumentChanged(
      documentId, revision, segments, (): void => { /* ignore */ },
      documentTitle, source
    );
  }
}
