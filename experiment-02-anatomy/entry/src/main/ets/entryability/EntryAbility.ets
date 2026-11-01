import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeSeeder } from '../data/KnowledgeSeeder';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0x0000, 'AnatomyLearning', 'Page load failed: %{public}s', error.message);
      }
    });
  }

  async onCreate(): Promise<void> {
    // 应用启动时导入课程资料种子数据（幂等）
    try {
      const seeder = new KnowledgeSeeder(this.context);
      const count = await seeder.seedIfNeeded();
      if (count > 0) {
        hilog.info(0x0000, 'AnatomyLearning', 'Seeded %{public}d knowledge documents.', count);
      }
    } catch (e) {
      hilog.error(0x0000, 'AnatomyLearning', 'Seed failed: %{public}s', JSON.stringify(e));
    }
  }
}
