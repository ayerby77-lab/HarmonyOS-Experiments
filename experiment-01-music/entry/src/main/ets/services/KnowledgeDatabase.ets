// ============================================================================
// SQLite 数据访问层 - 课程知识库
// ============================================================================
// 表结构:
//   course_materials(id, title, content, source_type, created_at, updated_at)
//   segments(id, material_id, chunk_index, content, keywords, embedding_blob)
//   qa_history(id, question, answer, sources_json, created_at)
// ============================================================================

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CourseMaterial, ContentSegment, QAHistory } from '../model/KnowledgeTypes';

const DB_NAME: string = 'course_knowledge.db';
const DB_VERSION: number = 1;

export class KnowledgeDatabase {
  private store: relationalStore.RdbStore | undefined = undefined;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 打开或创建数据库 */
  async open(): Promise<void> {
    if (this.store) { return; }
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    this.store = await relationalStore.getRdbStore(this.context, DB_VERSION, config, this.onCreate.bind(this));
  }

  private onCreate(store: relationalStore.RdbStore): void {
    const sql: string[] = [
      `CREATE TABLE IF NOT EXISTS course_materials (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        source_type TEXT NOT NULL DEFAULT 'manual',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
      `CREATE TABLE IF NOT EXISTS segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_id INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        content TEXT NOT NULL,
        keywords TEXT NOT NULL DEFAULT '',
        embedding_blob TEXT NOT NULL DEFAULT '[]',
        FOREIGN KEY (material_id) REFERENCES course_materials(id) ON DELETE CASCADE
      )`,
      `CREATE TABLE IF NOT EXISTS qa_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        sources_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL
      )`,
      `CREATE INDEX IF NOT EXISTS idx_segments_material ON segments(material_id)`,
      `CREATE INDEX IF NOT EXISTS idx_segments_keywords ON segments(keywords)`,
      `CREATE INDEX IF NOT EXISTS idx_qa_history_created ON qa_history(created_at DESC)`,
    ];
    for (const s of sql) {
      store.executeSql(s);
    }
  }

  /** -------------------- 课程资料 CRUD -------------------- */

  async insertMaterial(m: Omit<CourseMaterial, 'id'>): Promise<number> {
    if (!this.store) { await this.open(); }
    const row: relationalStore.ValuesBucket = {
      title: m.title,
      content: m.content,
      source_type: m.sourceType,
      created_at: m.createdAt,
      updated_at: m.updatedAt,
    };
    return await this.store!.insert('course_materials', row);
  }

  async updateMaterial(id: number, title: string, content: string): Promise<void> {
    if (!this.store) { await this.open(); }
    const row: relationalStore.ValuesBucket = {
      title, content, updated_at: Date.now(),
    };
    const predicates = new relationalStore.RdbPredicates('course_materials');
    predicates.equalTo('id', id);
    await this.store!.update(row, predicates);
  }

  async deleteMaterial(id: number): Promise<void> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('course_materials');
    predicates.equalTo('id', id);
    await this.store!.delete(predicates);
  }

  async listMaterials(): Promise<CourseMaterial[]> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('course_materials');
    predicates.orderByDesc('updated_at');
    const cursor = await this.store!.query(predicates);
    const result: CourseMaterial[] = [];
    while (cursor.goToNextRow()) {
      result.push({
        id: cursor.getLong(0),
        title: cursor.getString(1),
        content: cursor.getString(2),
        sourceType: cursor.getString(3),
        createdAt: cursor.getLong(4),
        updatedAt: cursor.getLong(5),
      });
    }
    cursor.close();
    return result;
  }

  async getMaterial(id: number): Promise<CourseMaterial | undefined> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('course_materials');
    predicates.equalTo('id', id);
    const cursor = await this.store!.query(predicates);
    if (cursor.goToNextRow()) {
      const m: CourseMaterial = {
        id: cursor.getLong(0),
        title: cursor.getString(1),
        content: cursor.getString(2),
        sourceType: cursor.getString(3),
        createdAt: cursor.getLong(4),
        updatedAt: cursor.getLong(5),
      };
      cursor.close();
      return m;
    }
    cursor.close();
    return undefined;
  }

  /** -------------------- 片段 CRUD -------------------- */

  async clearSegmentsByMaterial(materialId: number): Promise<void> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('segments');
    predicates.equalTo('material_id', materialId);
    await this.store!.delete(predicates);
  }

  async batchInsertSegments(segs: Omit<ContentSegment, 'id'>[]): Promise<void> {
    if (!this.store) { await this.open(); }
    await this.store!.transaction(async () => {
      for (const s of segs) {
        const row: relationalStore.ValuesBucket = {
          material_id: s.materialId,
          chunk_index: s.chunkIndex,
          content: s.content,
          keywords: s.keywords,
          embedding_blob: s.embeddingBlob,
        };
        this.store!.insert('segments', row);
      }
    });
  }

  async listSegmentsByMaterial(materialId: number): Promise<ContentSegment[]> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('segments');
    predicates.equalTo('material_id', materialId);
    predicates.orderByAsc('chunk_index');
    const cursor = await this.store!.query(predicates);
    const result: ContentSegment[] = [];
    while (cursor.goToNextRow()) {
      result.push({
        id: cursor.getLong(0),
        materialId: cursor.getLong(1),
        chunkIndex: cursor.getLong(2),
        content: cursor.getString(3),
        keywords: cursor.getString(4),
        embeddingBlob: cursor.getString(5),
      });
    }
    cursor.close();
    return result;
  }

  /** 按关键词全文检索片段（简单 LIKE） */
  async searchSegmentsByKeyword(keywords: string[]): Promise<ContentSegment[]> {
    if (!this.store) { await this.open(); }
    if (keywords.length === 0) { return []; }
    const sql: string = `SELECT * FROM segments WHERE keywords LIKE ? OR content LIKE ?`;
    const args: string = keywords.map(k => `%${k}%`).join(' ');
    const cursor = await this.store!.querySql(sql, [args, args]);
    const result: ContentSegment[] = [];
    while (cursor.goToNextRow()) {
      result.push({
        id: cursor.getLong(0),
        materialId: cursor.getLong(1),
        chunkIndex: cursor.getLong(2),
        content: cursor.getString(3),
        keywords: cursor.getString(4),
        embeddingBlob: cursor.getString(5),
      });
    }
    cursor.close();
    return result;
  }

  /** 获取所有片段（用于向量匹配） */
  async allSegments(): Promise<ContentSegment[]> {
    if (!this.store) { await this.open(); }
    const predicates = new relationalStore.RdbPredicates('segments');
    predicates.orderByAsc('id');
    const cursor = await this.store!.query(predicates);
    const result: ContentSegment[] = [];
    while (cursor.goToNextRow()) {
      result.push({
        id: cursor.getLong(0),
        materialId: cursor.getLong(1),
        chunkIndex: cursor.getLong(2),
        content: cursor.getString(3),
        keywords: cursor.getString(4),
        embeddingBlob: cursor.getString(5),
      });
    }
    cursor.close();
    return result;
  }

  /** -------------------- 问答历史 -------------------- */

  async insertHistory(h: Omit<QAHistory, 'id'>): Promise<number> {
    if (!this.store) { await this.open(); }
    const row: relationalStore.ValuesBucket = {
      question: h.question,
      answer: h.answer,
      sources_json: h.sourcesJson,
      created_at: h.createdAt,
    };
    return await this.store!.insert('qa_history', row);
  }

  async listHistory(limit: number = 50): Promise<QAHistory[]> {
    if (!this.store) { await this.open(); }
    const sql: string = `SELECT * FROM qa_history ORDER BY created_at DESC LIMIT ?`;
    const cursor = await this.store!.querySql(sql, [`${limit}`]);
    const result: QAHistory[] = [];
    while (cursor.goToNextRow()) {
      result.push({
        id: cursor.getLong(0),
        question: cursor.getString(1),
        answer: cursor.getString(2),
        sourcesJson: cursor.getString(3),
        createdAt: cursor.getLong(4),
      });
    }
    cursor.close();
    return result;
  }

  async close(): Promise<void> {
    if (this.store) {
      await this.store.close();
      this.store = undefined;
    }
  }
}
