import { common } from '@kit.AbilityKit';
import { CourseDocument, KnowledgeSegment, DocumentChangeEvent, CitationResolveResult } from '../model/Knowledge';
import { KnowledgeStore } from '../store/KnowledgeStore';
import { SegmentService } from './SegmentService';
import { KnowledgeEventBus, KnowledgeChangeListener } from './KnowledgeEventBus';

/** 生成唯一 ID */
function genId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * 资料服务：整合存储、切分和事件通知。
 * 页面和检索模块均通过此服务操作资料。
 */
export class KnowledgeService {
  private store: KnowledgeStore;
  private segmentService: SegmentService;
  private eventBus: KnowledgeEventBus;
  private static instance: KnowledgeService | null = null;

  constructor(context: common.Context) {
    this.store = new KnowledgeStore(context);
    this.segmentService = new SegmentService();
    this.eventBus = new KnowledgeEventBus();
  }

  static getInstance(context: common.Context): KnowledgeService {
    if (!KnowledgeService.instance) {
      KnowledgeService.instance = new KnowledgeService(context);
    }
    return KnowledgeService.instance;
  }

  async ensureReady(): Promise<void> {
    await this.store.ensureReady();
  }

  // ===== 事件订阅（供检索模块） =====

  subscribeChanges(listener: KnowledgeChangeListener): () => void {
    return this.eventBus.subscribe(listener);
  }

  getChangeHistory(): DocumentChangeEvent[] {
    return this.eventBus.getHistory();
  }

  // ===== 资料 CRUD =====

  async listDocuments(): Promise<CourseDocument[]> {
    await this.ensureReady();
    return this.store.listDocuments();
  }

  async getDocument(id: string): Promise<CourseDocument | null> {
    await this.ensureReady();
    return this.store.getDocument(id);
  }

  /**
   * 新增资料。
   * 会自动切分正文、保存片段，并发出 created 事件。
   */
  async createDocument(title: string, source: string, content: string): Promise<CourseDocument> {
    await this.ensureReady();
    const now = Date.now();
    const doc: CourseDocument = {
      id: genId('doc'),
      title,
      source,
      content,
      revision: 1,
      createdAt: now,
      updatedAt: now
    };
    await this.store.insertDocument(doc);

    const segments = this.segmentService.split(doc.id, doc.revision, doc.content);
    await this.store.replaceSegments(doc.id, doc.revision, segments);

    this.eventBus.emit({
      type: 'created',
      documentId: doc.id,
      revision: doc.revision,
      segments,
      timestamp: now
    });

    return doc;
  }

  /**
   * 修改资料。
   * 版本号自增，重新切分，发出 updated 事件。
   */
  async updateDocument(id: string, title: string, source: string, content: string): Promise<CourseDocument | null> {
    await this.ensureReady();
    const existing = await this.store.getDocument(id);
    if (!existing) {
      return null;
    }
    const previousRevision = existing.revision;
    const now = Date.now();
    const updated: CourseDocument = {
      ...existing,
      title,
      source,
      content,
      revision: existing.revision + 1,
      updatedAt: now
    };
    await this.store.updateDocument(updated);

    const segments = this.segmentService.split(updated.id, updated.revision, updated.content);
    await this.store.replaceSegments(updated.id, updated.revision, segments);

    this.eventBus.emit({
      type: 'updated',
      documentId: updated.id,
      revision: updated.revision,
      previousRevision,
      segments,
      timestamp: now
    });

    return updated;
  }

  /**
   * 删除资料及其全部片段，发出 deleted 事件。
   */
  async deleteDocument(id: string): Promise<boolean> {
    await this.ensureReady();
    const existing = await this.store.getDocument(id);
    if (!existing) {
      return false;
    }
    await this.store.deleteDocument(id);
    this.eventBus.emit({
      type: 'deleted',
      documentId: id,
      revision: existing.revision,
      segments: [],
      timestamp: Date.now()
    });
    return true;
  }

  // ===== 片段查询（供检索模块和引用跳转） =====

  /** 获取资料当前版本的全部片段 */
  async getSegments(documentId: string): Promise<KnowledgeSegment[]> {
    await this.ensureReady();
    const doc = await this.store.getDocument(documentId);
    if (!doc) {
      return [];
    }
    return this.store.getSegments(documentId, doc.revision);
  }

  /** 获取指定片段 */
  async getSegment(segmentId: string): Promise<KnowledgeSegment | null> {
    await this.ensureReady();
    return this.store.getSegment(segmentId);
  }

  /**
   * 获取当前所有有效片段（供检索模块全量建索引）。
   * 只返回与资料当前版本一致的片段。
   */
  async getAllActiveSegments(): Promise<KnowledgeSegment[]> {
    await this.ensureReady();
    return this.store.getAllActiveSegments();
  }

  /**
   * 解析引用，判断引用是否过期。
   * 旧引用遇到资料变化时给出明确提示。
   */
  async resolveCitation(documentId: string, documentRevision: number, segmentId: string): Promise<CitationResolveResult> {
    await this.ensureReady();
    const doc = await this.store.getDocument(documentId);
    if (!doc) {
      return {
        found: false,
        revisionCurrent: false,
        staleReason: '该资料已被删除，引用无法查看原文。'
      };
    }
    if (doc.revision !== documentRevision) {
      // 版本不一致，尝试查找片段但标记为过期
      const seg = await this.store.getSegment(segmentId);
      if (seg) {
        return {
          found: true,
          revisionCurrent: false,
          segment: seg,
          document: doc,
          staleReason: `该资料已更新（当前版本 ${doc.revision}，引用版本 ${documentRevision}），以下内容可能已变更。`
        };
      }
      return {
        found: false,
        revisionCurrent: false,
        document: doc,
        staleReason: `该资料已更新（当前版本 ${doc.revision}，引用版本 ${documentRevision}），原引用片段已不存在。`
      };
    }
    const seg = await this.store.getSegment(segmentId);
    if (!seg) {
      return {
        found: false,
        revisionCurrent: true,
        document: doc,
        staleReason: '引用片段不存在。'
      };
    }
    return {
      found: true,
      revisionCurrent: true,
      segment: seg,
      document: doc
    };
  }

  /** 获取片段在原文中的上下文 */
  getSegmentContext(doc: CourseDocument, segment: KnowledgeSegment, extend: number = 50): string {
    return this.segmentService.getContext(doc.content, segment, extend);
  }
}
