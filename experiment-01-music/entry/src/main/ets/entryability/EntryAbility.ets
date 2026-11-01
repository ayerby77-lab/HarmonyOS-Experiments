import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(0x0000, 'MusicApp', 'Page load failed: %{public}s', JSON.stringify(error));
        return;
      }
      hilog.info(0x0000, 'MusicApp', 'Player page loaded');
    });
  }
}
