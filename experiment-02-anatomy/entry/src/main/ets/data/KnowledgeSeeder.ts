import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeService } from '../service/KnowledgeService';
import { SEED_DOCUMENTS } from './SeedDocuments';

const TAG = 'KnowledgeSeeder';
const PREFS_FILE = 'knowledge_seeder';
const PREFS_KEY = 'seeded_v1';

/**
 * 资料种子服务。
 * 首次启动时将至少 10 篇课程资料写入数据库，供检索和问答使用。
 * 已执行过则跳过（幂等）。
 */
export class KnowledgeSeeder {
  private service: KnowledgeService;
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
    this.service = KnowledgeService.getInstance(context);
  }

  /**
   * 执行种子数据导入。
   * @returns 本次导入的资料数量（已导入过返回 0）
   */
  async seedIfNeeded(): Promise<number> {
    const prefs = await preferences.getPreferences(this.context, PREFS_FILE);
    const alreadySeeded = prefs.getSync(PREFS_KEY, false) as boolean;
    if (alreadySeeded) {
      hilog.info(0x0000, TAG, 'Seed already applied, skipping.');
      return 0;
    }

    await this.service.ensureReady();
    const existing = await this.service.listDocuments();
    if (existing.length > 0) {
      hilog.info(0x0000, TAG, 'Documents already exist (%{public}d), skipping seed.', existing.length);
      await prefs.putSync(PREFS_KEY, true);
      await prefs.flushSync();
      return 0;
    }

    let count = 0;
    for (const doc of SEED_DOCUMENTS) {
      try {
        await this.service.createDocument(doc.title, doc.source, doc.content);
        count++;
      } catch (e) {
        hilog.error(0x0000, TAG, 'Failed to seed document: %{public}s', doc.title);
      }
    }
    await prefs.putSync(PREFS_KEY, true);
    await prefs.flushSync();
    hilog.info(0x0000, TAG, 'Seeded %{public}d documents.', count);
    return count;
  }
}
