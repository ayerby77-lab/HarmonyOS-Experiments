// ============================================================================
// 课程知识问答 - 核心数据类型定义
// ============================================================================

/** 课程资料 */
export interface CourseMaterial {
  id: number;
  title: string;
  content: string;
  sourceType: string;       // 'manual' | 'import' | 'builtin'
  createdAt: number;
  updatedAt: number;
}

/** 切分后的文本片段 */
export interface ContentSegment {
  id: number;
  materialId: number;
  chunkIndex: number;
  content: string;
  keywords: string;         // 逗号分隔的关键词
  embeddingBlob: string;    // JSON 序列化的向量 (Base64)
}

/** 问答历史 */
export interface QAHistory {
  id: number;
  question: string;
  answer: string;
  sourcesJson: string;      // JSON: Array<RetrievalResult>
  createdAt: number;
}

/** 检索返回的片段 */
export interface RetrievalResult {
  segmentId: number;
  materialId: number;
  materialTitle: string;
  content: string;
  score: number;            // 综合得分 0-1
  scoreBreakdown: {         // 得分组成（便于调试）
    keywordScore: number;
    vectorScore: number;
  };
}

/** 对话消息 */
export interface ChatMessage {
  id: string;               // UUID 或时间戳
  role: 'user' | 'assistant';
  content: string;
  sources?: RetrievalResult[];
  timestamp: number;
  status: 'streaming' | 'done' | 'error';
  errorMessage?: string;
}

/** 处理状态 */
export enum ProcessStatus {
  Idle = 'idle',
  Loading = 'loading',
  Processing = 'processing',
  Streaming = 'streaming',
  Done = 'done',
  Error = 'error',
  NoNetwork = 'no_network',
  NoResults = 'no_results'
}

/** 云端请求配置 */
export interface CloudConfig {
  /** 云函数调用入口（可替换为真实 CFKit 地址） */
  qaEndpoint: string;
  embeddingEndpoint: string;
  /** 本地模拟开关：true 时使用本地 TF-IDF 与模拟 LLM */
  useLocalSimulation: boolean;
}
