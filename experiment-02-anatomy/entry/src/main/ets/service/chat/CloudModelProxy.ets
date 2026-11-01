// CFKit 云函数转发层：负责把问答请求转发到云端，并解析流式响应。
//
// 架构：客户端 → CloudModelProxy → CFKit 云函数 → 模型 API
// 所有密钥在云端；客户端只传 prompt 和检索片段。
//
// 流式协议（云函数返回给客户端）：
//   Content-Type: text/event-stream
//   每条事件形如：event:<type>\ndata:<json>\n\n
//   event 取值：token | citation | message_start | message_end | error
//
// 客户端把 SSE 事件翻译为 service/types.ets 定义的 StreamEventImpl。
//
// 说明：ArkTS 无全局 fetch / TextDecoder，改用 @kit.NetworkKit 的 http 流式请求
// 与 @kit.ArkTS 的 util.TextDecoder。

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SourceCitation, RetrievedChunk } from '../../model/Knowledge';
import {
  IChatService, ChatTurn, ChatHandle,
  StreamEventImpl, StreamErrorKind, ServiceError, ServiceException
} from '../types';

export interface CloudModelProxyOptions {
  functionUrl: string;
  defaultModel: string;
  timeoutMs?: number;
  throttleMs?: number;
}

// 解析后的选项（所有字段均为必填，替代原来的 Required<> 映射类型）。
interface ResolvedCloudOptions {
  functionUrl: string;
  defaultModel: string;
  timeoutMs: number;
  throttleMs: number;
}

// 取消标志（ArkTS 无对象展开，使用具名接口）。
interface CancelState {
  v: boolean;
}

export class CloudModelProxy implements IChatService {
  private readonly opts: ResolvedCloudOptions;

  constructor(opts: CloudModelProxyOptions) {
    const resolved: ResolvedCloudOptions = {
      functionUrl: opts.functionUrl,
      defaultModel: opts.defaultModel,
      timeoutMs: opts.timeoutMs ?? 30000,
      throttleMs: opts.throttleMs ?? 10,
    };
    this.opts = resolved;
  }

  ask(
    turn: ChatTurn,
    onEvent: (event: StreamEventImpl) => void,
    onComplete: () => void
  ): ChatHandle {
    const cancelState: CancelState = { v: false };
    let timerId = -1;
    let completed = false;
    const httpRequest: http.HttpRequest = http.createHttp();

    const release = (): void => {
      try { httpRequest.off('headersReceive'); } catch (e) { /* ignore */ }
      try { httpRequest.off('dataReceive'); } catch (e) { /* ignore */ }
      try { httpRequest.off('dataEnd'); } catch (e) { /* ignore */ }
    };

    const finish = (): void => {
      if (completed) return;
      completed = true;
      if (timerId !== -1) {
        clearTimeout(timerId);
        timerId = -1;
      }
      release();
      onComplete();
    };

    timerId = setTimeout((): void => {
      if (completed) return;
      cancelState.v = true;
      this.emitError(onEvent, 'timeout', 'Cloud function timeout');
      finish();
    }, this.opts.timeoutMs);

    const prompt: string = buildPrompt(turn.question, turn.segments);

    this.streamRequest(prompt, cancelState, httpRequest, onEvent).then((): void => {
      if (completed) return;
      finish();
    }).catch((e: Error): void => {
      if (completed) return;
      const err: ServiceException = toServiceException(e);
      if (!(cancelState.v && err.code === ServiceError.CANCELLED)) {
        this.emitError(onEvent, mapErrorKind(err.code), err.message);
      }
      finish();
    });

    const handle: ChatHandle = {
      cancel: (): void => { cancelState.v = true; }
    };
    return handle;
  }

  private emitError(onEvent: (ev: StreamEventImpl) => void, errorKind: StreamErrorKind, message: string): void {
    onEvent(StreamEventImpl.makeError(errorKind, message));
  }

  private emitStart(onEvent: (ev: StreamEventImpl) => void): void {
    onEvent(StreamEventImpl.makeRetrieving());
  }

  private emitEnd(onEvent: (ev: StreamEventImpl) => void): void {
    onEvent(StreamEventImpl.makeDone());
  }

  private streamRequest(
    prompt: string,
    cancelState: CancelState,
    httpRequest: http.HttpRequest,
    onEvent: (event: StreamEventImpl) => void
  ): Promise<void> {
    return new Promise<void>((resolve, reject): void => {
      const decoder = util.TextDecoder.create('utf-8');
      let buffer = '';
      let headersSeen = false;

      const processBuffer = (): void => {
        let sepIdx = buffer.indexOf('\n\n');
        while (sepIdx !== -1) {
          const raw = buffer.substring(0, sepIdx);
          buffer = buffer.substring(sepIdx + 2);
          this.dispatchSseEvent(raw, onEvent);
          sepIdx = buffer.indexOf('\n\n');
        }
      };

      httpRequest.on('headersReceive', (): void => {
        if (cancelState.v) return;
        headersSeen = true;
        this.emitStart(onEvent);
      });

      httpRequest.on('dataReceive', (data: ArrayBuffer): void => {
        if (cancelState.v) return;
        if (!headersSeen) {
          headersSeen = true;
          this.emitStart(onEvent);
        }
        buffer += decoder.decodeWithStream(new Uint8Array(data), { stream: true });
        processBuffer();
      });

      httpRequest.on('dataEnd', (): void => {
        if (cancelState.v) {
          reject(new ServiceException(ServiceError.CANCELLED, 'request cancelled'));
          return;
        }
        if (buffer.length > 0) {
          processBuffer();
          if (buffer.length > 0) {
            this.dispatchSseEvent(buffer, onEvent);
            buffer = '';
          }
        }
        this.emitEnd(onEvent);
        resolve();
      });

      httpRequest.requestInStream(this.opts.functionUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
        extraData: JSON.stringify({
          model: this.opts.defaultModel,
          prompt,
          stream: true,
        }),
        connectTimeout: 15000,
        readTimeout: this.opts.timeoutMs,
      }).then((respCode: number): void => {
        if (respCode < 200 || respCode >= 300) {
          reject(mapHttpError(respCode));
        }
      }).catch((err: BusinessError): void => {
        reject(toServiceException(err as Error));
      });
    });
  }

  private dispatchSseEvent(raw: string, onEvent: (ev: StreamEventImpl) => void): void {
    const lines = raw.split('\n');
    let eventType = 'token';
    let data = '';
    for (const line of lines) {
      if (line.startsWith('event:')) eventType = line.substring(6).trim();
      else if (line.startsWith('data:')) data += line.substring(5).trim();
    }
    switch (eventType) {
      case 'token':
        onEvent(StreamEventImpl.makeToken(data));
        break;
      case 'citation': {
        try {
          const c: SourceCitation = JSON.parse(data) as SourceCitation;
          onEvent(StreamEventImpl.makeCitation(c));
        } catch (e) { /* ignore malformed citation */ }
        break;
      }
      case 'error':
        onEvent(StreamEventImpl.makeError('request', data));
        break;
      case 'message_start':
        this.emitStart(onEvent);
        break;
      case 'message_end':
        this.emitEnd(onEvent);
        break;
    }
  }
}

function buildPrompt(question: string, segments: RetrievedChunk[]): string {
  const citations = segments.map((s: RetrievedChunk, i: number): string => {
    return `[${i + 1}] ${s.documentTitle}\n${s.text}`;
  }).join('\n\n');
  return `你是一位解剖学课程答疑助手。请严格基于以下参考片段回答，
每个事实后标注 [1][2] 等引用编号。片段不足时请说"现有资料不足以回答"。

--- 参考片段 ---
${citations}
---

用户问题：${question}

回答：`;
}

function mapHttpError(status: number): ServiceException {
  switch (status) {
    case 400: return new ServiceException(ServiceError.INVALID_ARGUMENT, 'bad request');
    case 401: case 403: return new ServiceException(ServiceError.AUTH_FAILURE, 'auth failed');
    case 429: return new ServiceException(ServiceError.RATE_LIMIT, 'rate limited');
    case 503: return new ServiceException(ServiceError.OFFLINE, 'cloud function unavailable');
    default: return new ServiceException(ServiceError.MODEL_ERROR, `HTTP ${status}`);
  }
}

function toServiceException(e: Error): ServiceException {
  if (e instanceof ServiceException) return e;
  const msg: string = e instanceof Error ? e.message : String(e);
  if (/timeout|ETIMEDOUT/i.test(msg)) return new ServiceException(ServiceError.TIMEOUT, msg);
  if (/network|fetch|ECONNREFUSED|ENOTFOUND/i.test(msg)) return new ServiceException(ServiceError.OFFLINE, msg);
  return new ServiceException(ServiceError.UNKNOWN, msg);
}

function mapErrorKind(code: ServiceError): StreamErrorKind {
  switch (code) {
    case ServiceError.OFFLINE: return 'network';
    case ServiceError.TIMEOUT: return 'timeout';
    case ServiceError.MODEL_ERROR: return 'parse';
    default: return 'request';
  }
}
