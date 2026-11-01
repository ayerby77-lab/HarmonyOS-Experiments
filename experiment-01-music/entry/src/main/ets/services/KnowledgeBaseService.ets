// ============================================================================
// KnowledgeBaseService - 课程知识库管理（资料 CRUD + 切分 + 向量化）
// ============================================================================

import { KnowledgeDatabase } from './KnowledgeDatabase';
import { LocalEmbeddingService, extractKeywords } from './EmbeddingService';
import { CourseMaterial, ContentSegment } from '../model/KnowledgeTypes';

/** 切分配置 */
const CHUNK_SIZE: number = 150;       // 每段最大字符数
const CHUNK_OVERLAP: number = 20;      // 相邻段重叠字符
const MAX_SEGMENTS_PER_MATERIAL: number = 200;

export class KnowledgeBaseService {
  private db: KnowledgeDatabase;
  private embed: LocalEmbeddingService;

  constructor(db: KnowledgeDatabase) {
    this.db = db;
    this.embed = new LocalEmbeddingService();
  }

  /** -------------------- 资料管理 -------------------- */

  async addMaterial(title: string, content: string, sourceType: string = 'manual'): Promise<CourseMaterial> {
    const now = Date.now();
    const id = await this.db.insertMaterial({
      title, content, sourceType, createdAt: now, updatedAt: now,
    });
    const material: CourseMaterial = { id, title, content, sourceType, createdAt: now, updatedAt: now };
    await this.indexMaterial(material);
    return material;
  }

  async updateMaterial(id: number, title: string, content: string): Promise<void> {
    await this.db.updateMaterial(id, title, content);
    const existing = await this.db.getMaterial(id);
    if (existing) {
      existing.title = title;
      existing.content = content;
      await this.indexMaterial(existing);
    }
  }

  async deleteMaterial(id: number): Promise<void> {
    // SQLite CASCADE 会删除 segments，但也显式清理一次保证顺序
    await this.db.clearSegmentsByMaterial(id);
    await this.db.deleteMaterial(id);
  }

  async listMaterials(): Promise<CourseMaterial[]> {
    return await this.db.listMaterials();
  }

  async getMaterial(id: number): Promise<CourseMaterial | undefined> {
    return await this.db.getMaterial(id);
  }

  /** 重建全部索引（导入新资料时用） */
  async rebuildAllIndex(): Promise<number> {
    const all = await this.db.listMaterials();
    let success = 0;
    for (const m of all) {
      try {
        await this.indexMaterial(m);
        success++;
      } catch (_) { /* skip */ }
    }
    return success;
  }

  /** -------------------- 切分 + 向量化 -------------------- */

  /** 对某资料执行切分 + embedding + 写库 */
  private async indexMaterial(m: CourseMaterial): Promise<void> {
    // 先清理旧片段
    await this.db.clearSegmentsByMaterial(m.id);
    // 切分
    const chunks = this.chunkText(m.content);
    // 限制数量
    const limited = chunks.slice(0, MAX_SEGMENTS_PER_MATERIAL);
    // 构造 segments
    const segs: Omit<ContentSegment, 'id'>[] = limited.map((content, idx) => {
      const keywords = extractKeywords(content, 6);
      const vec = this.embed.encode(content);
      return {
        materialId: m.id,
        chunkIndex: idx,
        content,
        keywords,
        embeddingBlob: JSON.stringify(vec),
      };
    });
    await this.db.batchInsertSegments(segs);
  }

  /** 简单中文切分：按句号/换行切后合并为 CHUNK_SIZE 大小的块 */
  private chunkText(text: string): string[] {
    const result: string[] = [];
    // 先按自然句号/换行切
    const sentences: string[] = text
      .replace(/\r\n/g, '\n')
      .split(/(?<=[。！？；\n])/)
      .map(s => s.trim())
      .filter(s => s.length > 0);

    let buffer = '';
    for (const sent of sentences) {
      if (buffer.length + sent.length <= CHUNK_SIZE) {
        buffer += sent;
      } else {
        if (buffer.length > 0) { result.push(buffer); }
        // 如果单句超长，强制切
        if (sent.length > CHUNK_SIZE) {
          for (let i = 0; i < sent.length; i += CHUNK_SIZE - CHUNK_OVERLAP) {
            result.push(sent.substring(i, i + CHUNK_SIZE));
          }
          buffer = '';
        } else {
          buffer = sent;
        }
      }
    }
    if (buffer.length > 0) { result.push(buffer); }

    // 去掉空段
    return result.filter(s => s.trim().length > 0);
  }
}
