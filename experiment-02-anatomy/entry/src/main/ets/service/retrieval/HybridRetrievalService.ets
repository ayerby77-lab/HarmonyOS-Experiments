// 混合检索：关键词（BM25 简化版）+ 语义向量，合并去重排序。
// 返回 Knowledge.ts 定义的 RetrievedChunk。
//
// 调用方：KnowledgeQA 页面通过 IChatService → ChatTurn.segments
// 或者直接调用 IHybridRetrievalService.retrieve()。

import { KnowledgeSegment, RetrievedChunk } from '../../model/Knowledge';
import {
  IHybridRetrievalService,
  IEmbeddingService, IVectorStore,
  EmbeddingRequest, EmbeddingResult, VectorRecord,
  ServiceException, ServiceError
} from '../types';
import { cosineSimilarity } from '../embedding/MemoryVectorStore';

export interface HybridRetrievalOptions {
  semanticWeight?: number;
  rrfK?: number;
  channelRecallMultiplier?: number;
}

// 解析后的选项（所有字段均为必填，替代原来的 Required<> 映射类型）。
interface ResolvedHybridOptions {
  semanticWeight: number;
  rrfK: number;
  channelRecallMultiplier: number;
}

// 内部：缓存片段 + 对应文档元信息（KnowledgeSegment 不含 title/source）
interface SegmentWithMeta {
  segment: KnowledgeSegment;
  documentTitle: string;
  source: string;
}

// 单条召回结果：片段 + 通道打分。
interface ScoredEntry {
  entry: SegmentWithMeta;
  score: number;
}

export class HybridRetrievalService implements IHybridRetrievalService {
  private readonly emb: IEmbeddingService;
  private readonly store: IVectorStore;
  private readonly segments: Map<string, SegmentWithMeta> = new Map();
  private readonly options: ResolvedHybridOptions;

  constructor(emb: IEmbeddingService, store: IVectorStore, opts?: HybridRetrievalOptions) {
    this.emb = emb;
    this.store = store;
    const resolved: ResolvedHybridOptions = {
      semanticWeight: opts?.semanticWeight ?? 0.6,
      rrfK: opts?.rrfK ?? 60,
      channelRecallMultiplier: opts?.channelRecallMultiplier ?? 3,
    };
    this.options = resolved;
  }

  // --- 索引侧方法（供 IndexSyncManager 调用）---
  // 注册片段时必须附带文档元信息（title / source），因为 KnowledgeSegment 不含这些字段。
  registerSegments(segments: KnowledgeSegment[], documentTitle: string = '', source: string = ''): void {
    for (const s of segments) {
      const meta: SegmentWithMeta = {
        segment: s,
        documentTitle,
        source,
      };
      this.segments.set(s.id, meta);
    }
  }

  removeDocumentSegments(documentId: string): void {
    const keys: string[] = Array.from(this.segments.keys());
    for (const sid of keys) {
      const entry = this.segments.get(sid);
      if (entry && entry.segment.documentId === documentId) this.segments.delete(sid);
    }
  }

  // --- 查询侧 ---
  get indexReady(): boolean {
    return this.segments.size > 0 && this.store.size() > 0;
  }
  get indexedCount(): number {
    return this.segments.size;
  }

  async retrieve(query: string, topK: number): Promise<RetrievedChunk[]> {
    if (!this.indexReady) {
      throw new ServiceException(
        ServiceError.INDEX_NOT_READY,
        `索引未就绪：segments=${this.segments.size}, vectors=${this.store.size()}`
      );
    }
    const q = query.trim();
    if (q.length === 0) {
      throw new ServiceException(ServiceError.INVALID_ARGUMENT, 'query is empty');
    }

    const channelTop = topK * this.options.channelRecallMultiplier;
    const semanticList: ScoredEntry[] = await this.semanticSearch(q, channelTop);
    const keywordList: ScoredEntry[] = this.keywordSearch(q, channelTop);

    const merged: RetrievedChunk[] = this.rrfMerge(semanticList, keywordList);
    return merged.slice(0, topK);
  }

  private keywordSearch(query: string, limit: number): ScoredEntry[] {
    const terms: string[] = tokenize(query);
    const scored: ScoredEntry[] = [];
    const lower = query.toLowerCase();
    for (const entry of this.segments.values()) {
      const segText = entry.segment.content.toLowerCase();
      let score = 0;
      if (segText.includes(lower)) score += 3;
      for (const term of terms) {
        if (term.length === 0) continue;
        const t = term.toLowerCase();
        let count = 0;
        let pos = 0;
        while ((pos = segText.indexOf(t, pos)) !== -1) { count++; pos += t.length; }
        if (count > 0) score += Math.log(count + 1) + 1;
      }
      if (score > 0) {
        const item: ScoredEntry = { entry, score };
        scored.push(item);
      }
    }
    scored.sort((a: ScoredEntry, b: ScoredEntry): number => b.score - a.score);
    return scored.slice(0, limit);
  }

  private async semanticSearch(query: string, limit: number): Promise<ScoredEntry[]> {
    const rq: EmbeddingRequest = { text: query };
    const emb: EmbeddingResult = await this.emb.embedText(rq);
    const results: VectorRecord[] = this.store.search(emb.vector, limit, 0.15);
    const out: ScoredEntry[] = [];
    for (const r of results) {
      const entry = this.segments.get(r.segmentId);
      if (!entry) continue;
      const item: ScoredEntry = {
        entry,
        score: cosineSimilarity(emb.vector, r.vector),
      };
      out.push(item);
    }
    return out;
  }

  private rrfMerge(
    semantic: ScoredEntry[],
    keyword: ScoredEntry[]
  ): RetrievedChunk[] {
    const map = new Map<string, RetrievedChunk>();
    const k = this.options.rrfK;
    const kwWeight = 1 - this.options.semanticWeight;

    const addList = (list: ScoredEntry[], weight: number, isSemantic: boolean): void => {
      list.forEach((item: ScoredEntry, idx: number): void => {
        const seg = item.entry.segment;
        let existing: RetrievedChunk | undefined = map.get(seg.id);
        if (!existing) {
          existing = {
            documentId: seg.documentId,
            documentTitle: item.entry.documentTitle,
            source: item.entry.source,
            segmentId: seg.id,
            segmentIndex: seg.seqIndex,
            text: seg.content,
            score: 0,
            keywordScore: 0,
            vectorScore: 0,
          };
          map.set(seg.id, existing);
        }
        const rankScore = 1 / (k + idx + 1);
        existing.score += rankScore * weight + item.score * 0.5 * weight;
        if (isSemantic) {
          existing.vectorScore = Math.max(existing.vectorScore, item.score);
        } else {
          existing.keywordScore = Math.max(existing.keywordScore, item.score);
        }
      });
    };

    addList(semantic, this.options.semanticWeight, true);
    addList(keyword, kwWeight, false);

    const all: RetrievedChunk[] = Array.from(map.values());
    all.sort((a: RetrievedChunk, b: RetrievedChunk): number => b.score - a.score);
    return all;
  }
}

function tokenize(text: string): string[] {
  const raw = text.toLowerCase().split(/[\s,，。！？、；：""''（）\(\)\[\]\{\}《》·\-—\/\\]+/);
  const tokens: string[] = [];
  for (const t of raw) {
    if (!t) continue;
    if (/^[\u4e00-\u9fa5]+$/.test(t) && t.length >= 2) {
      tokens.push(t);
      for (let i = 0; i < t.length; i++) tokens.push(t[i]);
    } else {
      tokens.push(t);
    }
  }
  return tokens;
}
