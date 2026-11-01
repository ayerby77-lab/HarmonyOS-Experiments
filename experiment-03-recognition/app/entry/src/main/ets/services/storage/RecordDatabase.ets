/**
 * 识别记录数据库（第二阶段，Agent 4）。
 *
 * 依据 docs/phase-2-contract.md 第 2.2 节：
 * - 单表 records，原始/编辑检测框以 JSON 文本列保存（raw_boxes_json / edited_boxes_json），
 *   本阶段不做跨记录框级查询，不拆 boxes 表；
 * - 数据库文件 smart_item_records.db，由 getRdbStore 管理在应用 databaseDir 下；
 * - 版本管理使用 RdbStore.version（SQLite user_version），当前目标版本 1，
 *   后续版本在此追加递增迁移步骤。
 *
 * 线程与事务：RDB 内部自带锁，跨线程安全；executeSql 不接受 begin/commit/rollback
 * SQL（801），事务必须使用 beginTransaction()/commit()/rollBack() 方法。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 数据库文件名。 */
export const RECORD_DB_NAME: string = 'smart_item_records.db';
/** 当前 schema 版本；新增迁移时 +1 并在 migrate 中追加分支。 */
export const RECORD_DB_VERSION: number = 1;
/** 记录表名。 */
export const TABLE_RECORDS: string = 'records';

/** 建表 DDL（v1）。列定义与契约 2.2 一一对应。 */
const CREATE_TABLE_RECORDS: string =
  'CREATE TABLE IF NOT EXISTS records (' +
  'record_id TEXT PRIMARY KEY, ' +
  'created_at_ms INTEGER NOT NULL, ' +
  'source TEXT NOT NULL, ' +
  'model_id TEXT NOT NULL, ' +
  'model_sha256 TEXT NOT NULL, ' +
  'image_path TEXT NOT NULL, ' +
  'thumbnail_path TEXT NOT NULL, ' +
  'image_width INTEGER NOT NULL, ' +
  'image_height INTEGER NOT NULL, ' +
  'cold_start INTEGER NOT NULL, ' +
  'total_ms INTEGER NOT NULL, ' +
  'execution_mode TEXT NOT NULL, ' +
  'raw_boxes_json TEXT NOT NULL, ' +
  'edited_boxes_json TEXT NOT NULL' +
  ')';

const CREATE_INDEX_CREATED_AT: string =
  'CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at_ms DESC)';
const CREATE_INDEX_SOURCE: string =
  'CREATE INDEX IF NOT EXISTS idx_records_source ON records(source)';

export class RecordDatabase {
  /**
   * 打开数据库并迁移到 RECORD_DB_VERSION。重复调用由调用方保证只生效一次
   *（RecordService 用单例 + in-flight Promise 去重）。
   *
   * @throws 打开或迁移失败时抛原始异常，由调用方映射为 DB_INIT_FAILED。
   */
  static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: RECORD_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    await RecordDatabase.migrate(store);
    return store;
  }

  /**
   * 按版本递增迁移。version 为 SQLite user_version，新建库为 0。
   * DDL 在事务中执行，失败回滚，不推进版本号。
   */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    let current: number = store.version;
    if (current >= RECORD_DB_VERSION) {
      return;
    }
    store.beginTransaction();
    try {
      if (current < 1) {
        await store.executeSql(CREATE_TABLE_RECORDS);
        await store.executeSql(CREATE_INDEX_CREATED_AT);
        await store.executeSql(CREATE_INDEX_SOURCE);
      }
      // 后续版本：if (current < 2) { ... }
      store.commit();
    } catch (e) {
      store.rollBack();
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
    store.version = RECORD_DB_VERSION;
  }

  /**
   * 在事务中执行一组读写。fn 抛错时回滚并原样抛出。
   * 注意：事务方法为同步 API，内部只允许使用同一 store 的异步读写。
   */
  static async runInTransaction<T>(store: relationalStore.RdbStore, fn: () => Promise<T>): Promise<T> {
    store.beginTransaction();
    try {
      const result: T = await fn();
      store.commit();
      return result;
    } catch (e) {
      try {
        store.rollBack();
      } catch (_rollbackError) {
        // 回滚失败不掩盖原始错误。
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  /**
   * 生成记录主键：rec_{unix_ms}_{hex4}（契约 2.1）。
   * hex4 防同毫秒碰撞；仍有理论冲突时由 save 侧冲突重试换新 id。
   */
  static generateRecordId(nowMs: number): string {
    const random: number = Math.floor(Math.random() * 0x10000);
    const hex: string = random.toString(16).padStart(4, '0');
    return `rec_${nowMs}_${hex}`;
  }
}
