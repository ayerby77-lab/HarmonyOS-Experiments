// 课程资料与问答域公共模型。由主工程师独占维护，其他 Agent 只读引用；
// 需要新增/修改字段时向主工程师提交变更请求，不要直接改本文件。

// 资料处理状态：处理中 / 就绪 / 失败。
export type DocumentStatus = 'processing' | 'ready' | 'error';

// 课程资料。revision 为资料版本，正文每次保存 +1，用于片段/索引版本同步。
export interface CourseDocument {
  id: string;
  title: string;
  source: string;         // 来源（课程讲义·运动系统 等）
  content: string;        // 正文原文
  revision: number;       // 版本号，从 1 开始，每次编辑 +1
  createdAt: number;
  updatedAt: number;
}

// 新增/编辑资料的草稿（未落库）。
export interface CourseDocumentDraft {
  id: string;             // 空串表示新增
  title: string;
  source: string;
  content: string;
}

// 知识片段：正文切分结果，携带资料版本与原文位置，便于引用定位。
// 说明：语义向量不存放在片段上，由向量库（IVectorStore）以 segmentId 为键单独维护，
// 片段本身只保留可持久化的正文字段。
export interface KnowledgeSegment {
  id: string;
  documentId: string;
  documentRevision: number; // 生成该片段时的资料版本
  content: string;          // 片段正文
  startOffset: number;      // 原文起始偏移（含）
  endOffset: number;        // 原文结束偏移（不含）
  seqIndex: number;         // 段内序号，从 0 开始
}

// 检索命中的片段（附带来源与打分），服务层与页面层共用。
export interface RetrievedChunk {
  documentId: string;
  documentTitle: string;
  source: string;
  segmentId: string;
  segmentIndex: number;
  text: string;
  score: number;         // 融合排序分
  keywordScore: number;  // BM25 分
  vectorScore: number;   // 余弦相似度
}

// 回答中的引用标识，指向某资料某版本的具体片段。
export interface SourceCitation {
  documentId: string;
  documentRevision: number;
  segmentId: string;
  documentTitle: string;
  source: string;       // 资料来源
  excerpt: string;       // 引用原文摘录
}

// 聊天消息（用户或助手）。
export interface ChatMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  citations: SourceCitation[];
  status: 'streaming' | 'done' | 'error';
  error: string;
  retryQuestion: string; // 重试时复用的原始问题
  createdAt: number;
}

// 问答页整体状态机。
export type QueryState = 'idle' | 'loading' | 'retrieving' | 'processing' | 'streaming' |
  'offline' | 'empty' | 'error' | 'complete';

// 说明：流式问答事件（StreamEvent）属于服务层契约，定义在 service/types.ets，
// 以避免与来源错误分类（ServiceException）产生跨层循环依赖。

// —— 资料变更事件（Agent C → Agent D）——
// 资料增删改后由 KnowledgeEventBus 发出，供检索模块订阅。
export type DocumentChangeEventType = 'created' | 'updated' | 'deleted';
export interface DocumentChangeEvent {
  type: DocumentChangeEventType;
  documentId: string;
  revision: number;
  /** 仅 updated 事件有：更新前的版本号 */
  previousRevision?: number;
  /** 新增 / 更新时为新版本全部片段；删除时为空数组 */
  segments: KnowledgeSegment[];
  timestamp: number;
}

// —— 引用解析结果（供 SourceDetail 展示过期引用提示）——
export interface CitationResolveResult {
  found: boolean;
  revisionCurrent: boolean;
  staleReason?: string;
  segment?: KnowledgeSegment;
  document?: CourseDocument;
}

// —— 页面路由参数 ——
// SourceDetail 路由参数；documentRevision 展示时以库中当前版本为准，避免过期引用。
export interface SourceParams {
  documentId: string;
  segmentId: string;
}

export function emptyDraft(): CourseDocumentDraft {
  return { id: '', title: '', source: '', content: '' };
}

// 草稿校验：返回空串表示通过，否则返回提示文案。
export function validateDraft(draft: CourseDocumentDraft): string {
  const title: string = draft.title.trim();
  const content: string = draft.content.trim();
  if (title.length === 0) {
    return '资料标题不能为空';
  }
  if (title.length > 80) {
    return '标题最多 80 个字符';
  }
  if (draft.source.trim().length > 120) {
    return '来源最多 120 个字符';
  }
  if (content.length < 20) {
    return '正文至少 20 个字符，请补充内容后保存';
  }
  if (content.length > 20000) {
    return '正文最多 20000 个字符';
  }
  return '';
}

export function parseStatus(s: string): DocumentStatus {
  if (s === 'processing' || s === 'ready' || s === 'error') {
    return s;
  }
  return 'error';
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

export function formatTime(ts: number): string {
  const d: Date = new Date(ts);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
    ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}
