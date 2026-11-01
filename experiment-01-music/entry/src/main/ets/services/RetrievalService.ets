// ============================================================================
// RetrievalService - 混合检索（关键词 + 语义向量）
// ============================================================================

import { KnowledgeDatabase } from './KnowledgeDatabase';
import { LocalEmbeddingService } from './EmbeddingService';
import { ContentSegment, RetrievalResult, CourseMaterial } from '../model/KnowledgeTypes';

export class RetrievalService {
  private db: KnowledgeDatabase;
  private embed: LocalEmbeddingService;
  // 混合权重：关键词 60%，向量 40%
  private kwWeight: number = 0.6;
  private vecWeight: number = 0.4;

  constructor(db: KnowledgeDatabase) {
    this.db = db;
    this.embed = new LocalEmbeddingService();
  }

  /** 执行混合检索 */
  async search(query: string, topK: number = 5): Promise<RetrievalResult[]> {
    const queryTokens = this.extractQueryTokens(query);
    const queryVec = this.embed.encode(query);

    // 并行获取所有片段 + 关键词候选
    const allSegs = await this.db.allSegments();
    const kwCandidates = await this.db.searchSegmentsByKeyword(queryTokens);
    const kwSet = new Set<number>(kwCandidates.map(s => s.id));

    // 计算每个片段的两路得分
    const scored: Array<{ seg: ContentSegment; kw: number; vec: number; material: CourseMaterial | undefined }> = [];
    const materialCache: Map<number, CourseMaterial> = new Map();

    for (const seg of allSegs) {
      // 关键词得分
      const kwScore = kwSet.has(seg.id) ? this.computeKeywordScore(seg, queryTokens) : 0;

      // 向量得分（余弦相似度）
      let vecScore = 0;
      try {
        const storedVec = JSON.parse(seg.embeddingBlob) as number[];
        vecScore = LocalEmbeddingService.cosineSimilarity(queryVec, storedVec);
      } catch (_) {
        vecScore = 0;
      }

      if (kwScore > 0.05 || vecScore > 0.05) {
        // 懒加载 material
        let material = materialCache.get(seg.materialId);
        if (!material) {
          material = await this.db.getMaterial(seg.materialId);
          if (material) { materialCache.set(seg.materialId, material); }
        }
        scored.push({ seg, kw: kwScore, vec: vecScore, material });
      }
    }

    // 归一化 + 加权融合
    let maxKw = 0, maxVec = 0;
    for (const s of scored) {
      if (s.kw > maxKw) { maxKw = s.kw; }
      if (s.vec > maxVec) { maxVec = s.vec; }
    }

    const results: RetrievalResult[] = scored.map(s => ({
      segmentId: s.seg.id,
      materialId: s.seg.materialId,
      materialTitle: s.material?.title ?? '未知资料',
      content: s.seg.content,
      score: (maxKw > 0 ? s.kw / maxKw : 0) * this.kwWeight + (maxVec > 0 ? s.vec / maxVec : 0) * this.vecWeight,
      scoreBreakdown: {
        keywordScore: s.kw,
        vectorScore: s.vec,
      },
    }));

    // 去重（同一 material 保留最高得分片段）
    results.sort((a, b) => b.score - a.score);
    const seen = new Set<number>();
    const deduped: RetrievalResult[] = [];
    for (const r of results) {
      if (!seen.has(r.materialId)) {
        deduped.push(r);
        seen.add(r.materialId);
      }
    }

    return deduped.slice(0, topK);
  }

  private extractQueryTokens(query: string): string[] {
    const tokens: string[] = [];
    const clean = query.replace(/\s+/g, '');
    // 双字 + 单字
    for (let i = 0; i < clean.length - 1; i++) {
      tokens.push(clean.substring(i, i + 2));
    }
    for (let i = 0; i < clean.length; i++) {
      tokens.push(clean[i]);
    }
    return tokens.filter(t => t.trim().length > 0);
  }

  private computeKeywordScore(seg: ContentSegment, tokens: string[]): number {
    const haystack = seg.keywords + ' ' + seg.content;
    let hits = 0;
    for (const t of tokens) {
      if (haystack.indexOf(t) >= 0) { hits++; }
    }
    return hits / Math.max(1, tokens.length);
  }
}
