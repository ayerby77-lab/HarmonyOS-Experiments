import { http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { SourceCitation, QueryState } from './Knowledge';

const TAG = 'QAService';

/**
 * 统一服务接口：封装问答流式请求的完整生命周期。
 * 真实后端未就绪时自动回退到 Mock，保证 UI 可独立联调。
 *
 * 典型调用顺序：
 *   const s = new QAService();
 *   s.onStateChange = (state) => { ... }
 *   s.onChunk = (delta) => { ... }
 *   s.onCitation = (citation) => { ... }
 *   s.onDone = (citations) => { ... }
 *   s.onError = (err) => { ... }
 *   s.start(question)
 *   // 用户退出或重试前：s.abort(); s.destroy();
 */
export class QAService {
  /** 后端地址。置空或空字符串时自动使用 Mock。 */
  static ENDPOINT: string = 'http://10.0.2.2:8080/ai/chat';

  private request: http.HttpRequest | null = null;
  private destroyed: boolean = false;
  private aborted: boolean = false;
  private mockTimerId: number = -1;

  onStateChange?: (state: QueryState, extra?: string) => void;
  onChunk?: (delta: string) => void;
  onCitation?: (citation: SourceCitation) => void;
  onDone?: (citations: SourceCitation[]) => void;
  onError?: (message: string) => void;

  start(question: string): void {
    if (!question || question.trim().length === 0) {
      this.emitError('问题不能为空');
      return;
    }
    if (this.destroyed) {
      this.emitError('服务已销毁，无法发起新请求');
      return;
    }

    this.aborted = false;
    this.onStateChange?.('processing');

    // 先做网络探测。
    this.checkNetwork().then((online) => {
      if (this.destroyed || this.aborted) {
        return;
      }
      if (!online) {
        this.onStateChange?.('offline');
        this.emitError('当前处于离线状态，请检查网络后重试');
        return;
      }

      const endpoint = QAService.ENDPOINT;
      if (!endpoint || endpoint.trim().length === 0) {
        this.runMock(question);
      } else {
        this.runHttp(question, endpoint);
      }
    });
  }

  /** 中止当前请求（用户点击重试 / 退出页面）。 */
  abort(): void {
    this.aborted = true;
    if (this.request) {
      try {
        this.request.destroy();
      } catch (e) {
        // 忽略销毁异常
      }
      this.request = null;
    }
    if (this.mockTimerId !== -1) {
      clearInterval(this.mockTimerId);
      this.mockTimerId = -1;
    }
  }

  /** 释放所有资源。页面退出时必须调用。 */
  destroy(): void {
    this.destroyed = true;
    this.abort();
  }

  // ------------------------------------------------------------------
  // 网络探测
  // ------------------------------------------------------------------
  private checkNetwork(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        connection.getDefaultNet().then((netHandle) => {
          resolve(netHandle != null);
        }).catch(() => {
          resolve(false);
        });
      } catch (e) {
        resolve(false);
      }
    });
  }

  // ------------------------------------------------------------------
  // 真实 HTTP 流式
  // ------------------------------------------------------------------
  private runHttp(question: string, endpoint: string): void {
    try {
      const req = http.createHttp();
      this.request = req;

      const url = `${endpoint}?prompt=${encodeURIComponent(question)}`;

      let receivedHeaders = false;
      let buffer = '';
      const decoder = util.TextDecoder.create('utf-8');

      const onHeaders = () => {
        if (receivedHeaders) {
          return;
        }
        receivedHeaders = true;
        if (this.aborted || this.destroyed) {
          return;
        }
        this.onStateChange?.('loading');
      };

      const onDataReceive = (err: BusinessError | undefined, data: ArrayBuffer | undefined) => {
        if (this.aborted || this.destroyed) {
          return;
        }
        if (err) {
          hilog.error(TAG, 'dataReceive err: %{public}s', JSON.stringify(err));
          this.emitError('接收数据异常');
          return;
        }
        if (!data) {
          return;
        }
        if (!receivedHeaders) {
          receivedHeaders = true;
          this.onStateChange?.('loading');
        }
        this.onStateChange?.('streaming');
        // 追加到缓冲区，尝试按 SSE / 纯文本两种方式解析。
        buffer += decoder.decode(data, { stream: true });
        this.consumeBuffer(buffer);
        buffer = '';
      };

      const onDataEnd = () => {
        if (this.aborted || this.destroyed) {
          return;
        }
        // 残留 buffer 再消费一次。
        if (buffer.length > 0) {
          this.consumeBuffer(buffer);
          buffer = '';
        }
        this.cleanupHttp(req);
        this.onStateChange?.('complete');
      };

      req.on('headersReceive', onHeaders);
      req.on('dataReceive', onDataReceive);
      req.on('dataEnd', onDataEnd);

      req.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 120000,
        header: {
          'Accept': 'text/event-stream, text/plain, application/json',
        },
      }).then((respCode: number) => {
        if (respCode < 200 || respCode >= 300) {
          this.emitError(`服务器返回异常（${respCode}）`);
        }
      }).catch((err: BusinessError) => {
        this.cleanupHttp(req);
        hilog.error(TAG, 'requestInStream err: %{public}s', JSON.stringify(err));
        const msg = (err && err.message) ? err.message : '未知错误';
        if (msg.indexOf('timeout') >= 0) {
          this.emitError('请求超时，请检查网络或重试');
        } else {
          this.emitError('请求失败：' + msg);
        }
      });
    } catch (e) {
      hilog.error(TAG, 'runHttp exception: %{public}s', JSON.stringify(e));
      this.runMock(question);
    }
  }

  private cleanupHttp(req: http.HttpRequest): void {
    try {
      req.off('dataReceive');
      req.off('dataEnd');
      req.off('headersReceive');
    } catch (_) {
      // ignore
    }
  }

  /** 把收到的 buffer 按 SSE（data: ...）或纯文本两种模式消费。 */
  private consumeBuffer(buf: string): void {
    if (!buf) {
      return;
    }
    // 优先尝试 SSE 格式
    if (buf.indexOf('data:') !== -1) {
      const events = buf.split(/\r?\n\r?\n/);
      for (const ev of events) {
        if (!ev.trim()) {
          continue;
        }
        const lines = ev.split(/\r?\n/);
        for (const line of lines) {
          const m = line.match(/^data:\s*(.*)$/);
          if (m) {
            const payload = m[1];
            if (payload === '[DONE]') {
              continue;
            }
            this.handleSsePayload(payload);
          }
        }
      }
      return;
    }
    // 纯文本模式，直接作为一个 chunk 吐出
    this.onChunk?.(buf);
  }

  private handleSsePayload(payload: string): void {
    try {
      const obj = JSON.parse(payload);
      // 约定字段：type = 'text' | 'citation'
      if (obj && typeof obj === 'object') {
        if (obj.type === 'citation' && obj.citation) {
          const c: SourceCitation = {
            documentId: String(obj.citation.documentId ?? ''),
            documentRevision: Number(obj.citation.documentRevision ?? 0),
            segmentId: String(obj.citation.segmentId ?? ''),
            documentTitle: String(obj.citation.documentTitle ?? ''),
            excerpt: String(obj.citation.excerpt ?? ''),
          };
          this.onCitation?.(c);
          return;
        }
        if (obj.type === 'text' && typeof obj.text === 'string') {
          this.onChunk?.(obj.text);
          return;
        }
      }
    } catch (_) {
      // 非 JSON，按纯文本吐
    }
    this.onChunk?.(payload);
  }

  // ------------------------------------------------------------------
  // Mock（后端未就绪时使用，覆盖完整状态机）
  // ------------------------------------------------------------------
  private runMock(question: string): void {
    this.onStateChange?.('loading');

    const sample = this.buildMockAnswer(question);
    let idx = 0;
    const tick = () => {
      if (this.aborted || this.destroyed) {
        return;
      }
      this.onStateChange?.('streaming');
      const step = 2 + Math.floor(Math.random() * 4);
      const delta = sample.answer.slice(idx, idx + step);
      if (delta.length > 0) {
        this.onChunk?.(delta);
      }
      idx += step;
      if (idx >= sample.answer.length) {
        clearInterval(this.mockTimerId);
        this.mockTimerId = -1;
        for (const c of sample.citations) {
          this.onCitation?.(c);
        }
        this.onStateChange?.('complete');
        if (!sample.answer) {
          this.onStateChange?.('empty');
        }
      }
    };
    this.mockTimerId = setInterval(tick, 40) as unknown as number;
    tick();
  }

  private buildMockAnswer(question: string): { answer: string; citations: SourceCitation[] } {
    const q = (question ?? '').toLowerCase();
    if (q.indexOf('空') !== -1 || q.indexOf('无相关') !== -1) {
      return { answer: '', citations: [] };
    }
    const answer =
      '根据课程资料，心脏是一个位于胸腔纵隔内的肌肉性空腔器官，约拳头大小。' +
      '它由左心房、左心室、右心房、右心室四个腔室组成，' +
      '其中左心室壁最厚，负责将富氧血液泵入主动脉，右心室则将乏氧血送入肺动脉。' +
      '心脏的节律性收缩依靠窦房结、房室结和浦肯野纤维构成的传导系统。';
    const citations: SourceCitation[] = [
      {
        documentId: 'doc-heart-001',
        documentRevision: 3,
        segmentId: 'seg-heart-ch-04',
        documentTitle: '系统解剖学·循环系统',
        excerpt: '心脏是中空的肌性器官，位于胸腔的中纵隔内...',
      },
      {
        documentId: 'doc-heart-001',
        documentRevision: 3,
        segmentId: 'seg-heart-conduct',
        documentTitle: '系统解剖学·循环系统',
        excerpt: '心脏的传导系统由窦房结、房室结、房室束和浦肯野纤维组成...',
      },
    ];
    return { answer, citations };
  }

  private emitError(message: string): void {
    this.onStateChange?.('error', message);
    this.onError?.(message);
  }
}
