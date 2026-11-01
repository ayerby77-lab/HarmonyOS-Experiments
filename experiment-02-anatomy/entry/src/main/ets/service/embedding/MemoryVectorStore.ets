// 内存向量存储。生产环境可替换为 Pinecone / Milvus / Chroma 等外部服务，
// 接口保持不变。存储键为 segmentId，每个 segment 仅保留最高 revision 的向量。
//
// 版本保护：
//   upsert 时，如果同一 segmentId 已存在更高或相等 revision，拒绝写入——
//   这样即使旧的 embedding 任务（通过 IndexSyncManager generation 校验漏掉的）
//   仍可能调用 upsert，也不会覆盖更新版本的数据。这是第二道防线。

import { IVectorStore, VectorRecord } from '../types';

// 打分中间结果：记录 + 相似度。
interface ScoredRecord {
  rec: VectorRecord;
  score: number;
}

export class MemoryVectorStore implements IVectorStore {
  // segmentId -> VectorRecord
  private readonly vectors: Map<string, VectorRecord> = new Map();

  upsert(record: VectorRecord): void {
    const existing = this.vectors.get(record.segmentId);
    if (existing && existing.documentRevision > record.documentRevision) {
      // 更高 revision 已存在，丢弃。
      return;
    }
    this.vectors.set(record.segmentId, record);
  }

  upsertBatch(records: VectorRecord[]): void {
    for (const r of records) this.upsert(r);
  }

  removeBySegmentId(segmentId: string): void {
    this.vectors.delete(segmentId);
  }

  removeByDocument(documentId: string, upToRevision?: number): void {
    const keys: string[] = Array.from(this.vectors.keys());
    for (const sid of keys) {
      const rec = this.vectors.get(sid);
      if (!rec) continue;
      if (rec.documentId !== documentId) continue;
      if (upToRevision !== undefined && rec.documentRevision > upToRevision) continue;
      this.vectors.delete(sid);
    }
  }

  search(queryVector: number[], topK: number, minScore: number = 0): VectorRecord[] {
    const scored: ScoredRecord[] = [];
    for (const rec of this.vectors.values()) {
      const s = cosineSimilarity(queryVector, rec.vector);
      if (s >= minScore) {
        const item: ScoredRecord = { rec, score: s };
        scored.push(item);
      }
    }
    scored.sort((a: ScoredRecord, b: ScoredRecord): number => b.score - a.score);
    return scored.slice(0, topK).map((x: ScoredRecord): VectorRecord => x.rec);
  }

  size(): number {
    return this.vectors.size;
  }
}

// --- helpers ---
export function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA === 0 || normB === 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}
