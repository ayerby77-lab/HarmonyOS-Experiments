import { Want } from '@kit.AbilityKit';

interface PendingMeta {
  question: string;
  autoSubmit: boolean;
  seq: string;
}

interface ConsumedResult {
  question: string;
  autoSubmit: boolean;
}

interface ParsedMeta {
  autoSubmit?: boolean;
}

/**
 * ArkAF 意图模块
 *
 * 负责：
 *   1) 从 Ability 的 Want（冷启动 onCreate / 热启动 onNewWant）里抽取 question 参数
 *   2) 通过 AppStorage 在 EntryAbility 和 KnowledgeQA 页面之间做一次性传递
 *   3) 提供"读即清空"消费语义，避免页面重复消费同一个问题
 *
 * 上游（EntryAbility 补丁）用法示意：
 *   // onCreate / onNewWant 中
 *   const q = ArkAFIntent.extractQuestionFromWant(want);
 *   if (q) { ArkAFIntent.publishQuestion(q); }
 *
 * 下游（KnowledgeQA 页面）用法示意：
 *   // aboutToAppear 中
 *   const q = ArkAFIntent.consumePendingQuestion();
 *   if (q) { this.inputText = q; this.submit(); }
 *
 * 参数约定：
 *   - Want.parameters.question  （string，实际要发起的问题）
 *   - Want.parameters.autoSubmit （boolean/string，'false' 时只回填不自动提交，省略或其它值默认自动提交）
 *   - Want.action  推荐使用 'ohos.want.action.SEND_QUESTION' 或应用自定义 action，
 *                  但本模块不强依赖 action，只要 parameters 里有 question 就认。
 */
export class ArkAFIntent {
  /** AppStorage key：一次性消费的问题。 */
  static readonly PENDING_QUESTION_KEY = 'arkaf.pendingQuestion';
  /** AppStorage key：配套的自动提交标志（JSON 字符串，含 question / autoSubmit / seq 去重）。 */
  static readonly PENDING_QUESTION_META_KEY = 'arkaf.pendingQuestionMeta';

  /** 从 Want 中抽取 question。找不到返回 undefined。 */
  static extractQuestionFromWant(want: Want | undefined | null): string | undefined {
    if (!want || !want.parameters) {
      return undefined;
    }
    const raw = want.parameters['question'];
    if (typeof raw !== 'string') {
      return undefined;
    }
    const q = raw.trim();
    return q.length > 0 ? q : undefined;
  }

  /** 从 Want 中抽取 autoSubmit，默认 true。 */
  static extractAutoSubmit(want: Want | undefined | null): boolean {
    if (!want || !want.parameters) {
      return true;
    }
    const v = want.parameters['autoSubmit'];
    if (typeof v === 'boolean') {
      return v;
    }
    if (typeof v === 'string') {
      return v !== 'false';
    }
    return true;
  }

  /** 发布问题到 AppStorage（EntryAbility 调用）。seq 仅用于调试。 */
  static publishQuestion(question: string, autoSubmit: boolean = true): void {
    const trimmed = (question ?? '').trim();
    if (!trimmed) {
      return;
    }
    const meta: PendingMeta = {
      question: trimmed,
      autoSubmit: autoSubmit,
      seq: Date.now() + '_' + Math.random().toString(36).slice(2, 8),
    };
    AppStorage.setOrCreate<string>(ArkAFIntent.PENDING_QUESTION_KEY, trimmed);
    AppStorage.setOrCreate<string>(ArkAFIntent.PENDING_QUESTION_META_KEY, JSON.stringify(meta));
  }

  /**
   * 消费一次待处理问题（读即清空），返回 question 字符串；无则返回 undefined。
   * 同时返回 autoSubmit 标志。
   * KnowledgeQA 在 aboutToAppear 中调用，保证同一条问题不会被重复处理。
   */
  static consumePendingQuestion(): ConsumedResult | undefined {
    const q = AppStorage.get<string>(ArkAFIntent.PENDING_QUESTION_KEY);
    const metaStr = AppStorage.get<string>(ArkAFIntent.PENDING_QUESTION_META_KEY);
    ArkAFIntent.clearPendingQuestion();
    if (!q) {
      return undefined;
    }
    let autoSubmit = true;
    try {
      if (metaStr) {
        const meta = JSON.parse(metaStr) as PendingMeta;
        if (typeof meta.autoSubmit === 'boolean') {
          autoSubmit = meta.autoSubmit;
        }
      }
    } catch (_e) {
      // ignore
    }
    const result: ConsumedResult = { question: q, autoSubmit: autoSubmit };
    return result;
  }

  /** 清除一次性通道。EntryAbility 或页面主动放弃时也可调用。 */
  static clearPendingQuestion(): void {
    AppStorage.setOrCreate<string>(ArkAFIntent.PENDING_QUESTION_KEY, '');
    AppStorage.setOrCreate<string>(ArkAFIntent.PENDING_QUESTION_META_KEY, '');
  }
}
