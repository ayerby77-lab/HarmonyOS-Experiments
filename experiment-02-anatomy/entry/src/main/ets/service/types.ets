// 服务层公共类型与错误分类。
//
// 与 model/Knowledge.ts 的分工：
//   - Knowledge.ts 维护领域模型（CourseDocument, KnowledgeSegment, RetrievedChunk,
//     SourceCitation, ChatMessage, QueryState, DocumentChangeEvent, CitationResolveResult）。
//   - 本文件定义服务层内部接口和流式事件（StreamEvent 不属于领域模型，
//     它是服务层 → 页面层的传输协议）以及错误分类。
//
// ArkTS 注意事项：
//   - 不使用 any / unknown（arkts-no-any-unknown）
//   - 不使用内联对象字面量做类型声明（arkts-no-obj-literals-as-types）
//   - 接口不做结构性匹配（arkts-no-structural-typing）
//   - throw 只能抛 Error 子类（arkts-limited-throw）
//   - 函数显式返回类型（arkts-no-implicit-return-types）

import { KnowledgeSegment, RetrievedChunk, SourceCitation } from '../model/Knowledge';

// --- 错误分类 ---
export enum ServiceError {
  OFFLINE = 'offline',
  TIMEOUT = 'timeout',
  AUTH_FAILURE = 'auth_failure',
  RATE_LIMIT = 'rate_limit',
  EMPTY_RESULTS = 'empty_results',
  MODEL_ERROR = 'model_error',
  INDEX_NOT_READY = 'index_not_ready',
  INVALID_ARGUMENT = 'invalid_argument',
  CANCELLED = 'cancelled',
  UNKNOWN = 'unknown'
}

export class ServiceException extends Error {
  code: ServiceError;
  cause?: Error;
  constructor(code: ServiceError, message: string, cause?: Error) {
    super(message);
    this.code = code;
    this.cause = cause;
  }
}

// --- Embedding ---
export interface EmbeddingRequest {
  text: string;
  model?: string;
  dimension?: number;
}

export interface EmbeddingResult {
  vector: number[];
  model: string;
  dimension: number;
  latencyMs: number;
}

export interface IEmbeddingService {
  embedText(req: EmbeddingRequest): Promise<EmbeddingResult>;
  embedBatch(texts: string[], model?: string): Promise<EmbeddingResult[]>;
  readonly defaultModel: string;
  readonly defaultDimension: number;
  readonly available: boolean;
}

// --- 向量存储 ---
export interface VectorRecord {
  segmentId: string;
  documentId: string;
  documentRevision: number;
  vector: number[];
}

export interface IVectorStore {
  upsert(record: VectorRecord): void;
  upsertBatch(records: VectorRecord[]): void;
  removeBySegmentId(segmentId: string): void;
  removeByDocument(documentId: string, upToRevision?: number): void;
  search(queryVector: number[], topK: number, minScore?: number): VectorRecord[];
  size(): number;
}

// --- 流式问答事件 ---
// 从 ChatService 传给 UI。用显式 interface 而不是 union + inline payload，
// 以符合 ArkTS 严格模式。
export type StreamEventKind = 'retrieving' | 'token' | 'citation' | 'done' | 'error';
export type StreamErrorKind = 'network' | 'request' | 'timeout' | 'parse';

export class StreamEventImpl {
  kind: StreamEventKind = 'token';
  text: string = '';
  citation: SourceCitation | null = null;
  errorKind: StreamErrorKind | '' = '';
  message: string = '';

  static makeToken(text: string): StreamEventImpl {
    const e = new StreamEventImpl();
    e.kind = 'token';
    e.text = text;
    return e;
  }
  static makeCitation(c: SourceCitation): StreamEventImpl {
    const e = new StreamEventImpl();
    e.kind = 'citation';
    e.citation = c;
    return e;
  }
  static makeRetrieving(): StreamEventImpl {
    const e = new StreamEventImpl();
    e.kind = 'retrieving';
    return e;
  }
  static makeDone(): StreamEventImpl {
    const e = new StreamEventImpl();
    e.kind = 'done';
    return e;
  }
  static makeError(errorKind: StreamErrorKind, message: string): StreamEventImpl {
    const e = new StreamEventImpl();
    e.kind = 'error';
    e.errorKind = errorKind;
    e.message = message;
    return e;
  }
}

// --- 检索 ---
export interface IHybridRetrievalService {
  retrieve(query: string, topK: number): Promise<RetrievedChunk[]>;
  readonly indexReady: boolean;
  readonly indexedCount: number;
  registerSegments?(
    segments: KnowledgeSegment[],
    documentTitle: string,
    source: string
  ): void;
  removeDocumentSegments?(documentId: string): void;
}

// --- 索引同步 ---
export interface IndexBuildResult {
  documentId: string;
  revision: number;
  generation: number;
  ok: boolean;
  message?: string;
}

export interface IIndexSyncManager {
  handleDocumentChanged(
    documentId: string,
    revision: number,
    segments: KnowledgeSegment[],
    onComplete: (result: IndexBuildResult) => void,
    documentTitle?: string,
    source?: string
  ): void;
  handleDocumentDeleted(documentId: string): void;
  readonly pendingCount: number;
}

// --- 流式问答 ---
export interface ChatTurn {
  question: string;
  segments: RetrievedChunk[];
  model?: string;
  cloudFunctionId?: string;
}

export interface ChatHandle {
  cancel: () => void;
}

export interface IChatService {
  ask(
    turn: ChatTurn,
    onEvent: (event: StreamEventImpl) => void,
    onComplete: () => void
  ): ChatHandle;
}
