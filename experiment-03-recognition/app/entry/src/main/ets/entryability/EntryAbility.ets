import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RecordService } from '../services/storage/RecordService';
import { RecognitionService } from '../services/inference/RecognitionService';
import * as NativeBridge from '../services/inference/NativeInferenceBridge';
import { SyncManager } from '../services/sync/SyncManager';
import { ModelUpdateRegistry } from '../components/recognition/ModelUpdate';
import { CloudRecordRegistry } from '../components/recognition/CloudQuery';
import { ModelClient } from '../services/network/ModelClient';
import { RecordClient } from '../services/network/RecordClient';

const TAG: string = 'SmartItemApp';
const DOMAIN: number = 0x0000;

/**
 * benchmark 触发标记。由 `aa start ... --ps benchTrigger 1` 传入的 want 参数置位。
 *
 * 为什么不继续用 `/data/local/tmp/benchmark_trigger.txt`：应用沙箱内的
 * `fileIo.access('/data/local/tmp/...')` 实测恒为 false（R3-05），该通道不可用。
 * 而 rawfile 通道需要在源码里放测试资产，会污染生产包（BLK-13）。
 * want 参数两者都避开，是验证构建的首选触发方式。
 */
let benchTriggerFromWant: boolean = false;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const flag: Object | undefined = params['benchTrigger'];
      if (flag !== undefined && flag !== null) {
        const text: string = String(flag);
        benchTriggerFromWant = text === '1' || text === 'true';
        hilog.info(DOMAIN, TAG, 'want benchTrigger=%{public}s', benchTriggerFromWant ? 'true' : 'false');
      }
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate start');

    void RecordService.getInstance().initialize(this.context).then((result) => {
      hilog.info(DOMAIN, TAG, 'RecordService init ok=%{public}s', result.initialized ? 'true' : 'false');
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'RecordService init exception: %{public}s', e.message);
    });

    // RecognitionService.initialize() 内部：ABI 检查 → 模型沙箱拷贝+hash → NativeBridge.initNative()
    RecognitionService.getInstance().setContext(this.context);
    void RecognitionService.getInstance().initialize().then((avail) => {
      hilog.info(DOMAIN, TAG, 'RecognitionService init available=%{public}s', avail.available ? 'true' : 'false');
      if (!avail.available && avail.error) {
        hilog.warn(DOMAIN, TAG, '模型不可用: %{public}s', avail.error.message);
      }
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'RecognitionService init exception: %{public}s', e.message);
    });

    // 第三阶段同步层：初始化 SyncManager（Preferences + Network listener + 启动后 flush 遗留队列）
    void SyncManager.getInstance().initialize(this.context).then(() => {
      hilog.info(DOMAIN, TAG, 'SyncManager init ok');
      hilog.info(DOMAIN, TAG, 'CloudRecordPort available=%{public}s, ModelUpdatePort available=%{public}s',
        CloudRecordRegistry.available() ? 'true' : 'false',
        ModelUpdateRegistry.available() ? 'true' : 'false');
    }).catch((e: Error) => {
      // 同步层失败不阻塞应用主流程
      hilog.warn(DOMAIN, TAG, 'SyncManager init exception: %{public}s', e.message);
    });

    // 第三阶段端口注册：云端查询与模型更新由 UI 端口按需调用，自身负责登录与刷新。
    ModelClient.getInstance().initialize(this.context);
    CloudRecordRegistry.register(RecordClient.getInstance());
    ModelUpdateRegistry.register(ModelClient.getInstance());

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Load page failed: %{public}s', err.message);
      } else {
        hilog.info(DOMAIN, TAG, 'loadContent success');
      }
    });

    // 开发验证用：rawfile/benchmark_trigger.txt 或 /data/local/tmp/benchmark_trigger.txt 触发完整推理 benchmark
    void this.maybeRunBenchmark();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    NativeBridge.disposeNative();
    void RecordService.getInstance().dispose();
    void RecognitionService.getInstance().dispose();
    SyncManager.getInstance().dispose();
  }

  private async maybeRunBenchmark(): Promise<void> {
    try {
      let triggered = false;
      let source = '';

      // 通道 1：want 参数（推荐，不污染包内容）
      if (benchTriggerFromWant) {
        triggered = true;
        source = 'want';
      }

      // 通道 2：rawfile 标记文件（兼容既有用法，验证构建时才会放入）
      if (!triggered) {
        try {
          await this.context.resourceManager.getRawFileContent('benchmark_trigger.txt');
          triggered = true;
          source = 'rawfile';
        } catch (e) { /* no */ }
      }

      // 说明：原 `/data/local/tmp/benchmark_trigger.txt` 通道已移除。
      // 应用沙箱对该路径 `fileIo.access` 恒为 false（R3-05 实测），保留只会误导。

      if (!triggered) {
        return;
      }

      hilog.info(DOMAIN, TAG, 'benchmark triggered by %{public}s', source);
      hilog.info(DOMAIN, TAG, 'importing BenchmarkRunner...');
      const mod = await import('../services/inference/BenchmarkRunner');
      hilog.info(DOMAIN, TAG, 'import ok, running benchmark');
      await mod.runBenchmark(this.context);
      hilog.info(DOMAIN, TAG, 'benchmark done');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'benchmark crash: %{public}s', (e as Error).message);
    }
  }
}
