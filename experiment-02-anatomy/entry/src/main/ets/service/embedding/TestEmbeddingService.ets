// 测试替身实现：用文本 hash 生成确定性的伪向量。
// 真实实现应在生产环境替换为云端 embedding API 调用。
//
// 为什么要提供替身：
//   验收要求「真实服务依赖缺失时明确报告，并可运行的测试替身验证接口」。
//   本类完全离线可运行，向量维度和点积语义与真实 embedding 接口一致，
//   足以驱动 SegmentStore + HybridRetrievalService 完成混合检索的单元测试。

import {
  IEmbeddingService, EmbeddingRequest, EmbeddingResult,
  ServiceException, ServiceError
} from '../types';

// 构造参数：可选覆盖模型名与向量维度。
interface TestEmbeddingOptions {
  model?: string;
  dimension?: number;
}

function hashString(text: string): number {
  // DJB2 变种，返回 32 位整数
  let h = 5381;
  for (let i = 0; i < text.length; i++) {
    h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  }
  return h >>> 0; // 转无符号
}

function mulberry32(seed: number): () => number {
  let a = seed | 0;
  return (): number => {
    a |= 0;
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function normalize(vec: number[]): number[] {
  let norm = 0;
  for (const v of vec) norm += v * v;
  norm = Math.sqrt(norm);
  if (norm === 0) norm = 1;
  return vec.map((v: number): number => v / norm);
}

export class TestEmbeddingService implements IEmbeddingService {
  readonly defaultModel = 'test-hash-embedding-v1';
  readonly defaultDimension = 256;
  readonly available = true;

  private modelOverride?: string;
  private dimensionOverride?: number;

  constructor(opts?: TestEmbeddingOptions) {
    if (opts?.model) this.modelOverride = opts.model;
    if (opts?.dimension) this.dimensionOverride = opts.dimension;
  }

  async embedText(req: EmbeddingRequest): Promise<EmbeddingResult> {
    const start = Date.now();
    const text = req.text.trim();
    if (text.length === 0) {
      throw new ServiceException(ServiceError.INVALID_ARGUMENT, 'empty text');
    }
    const dimension: number = req.dimension ?? this.dimensionOverride ?? this.defaultDimension;
    const model: string = req.model ?? this.modelOverride ?? this.defaultModel;
    const seed = hashString(text);
    const rand = mulberry32(seed);
    const vec: number[] = [];
    for (let i = 0; i < dimension; i++) vec.push(rand() * 2 - 1);
    const result: EmbeddingResult = {
      vector: normalize(vec),
      model,
      dimension,
      latencyMs: Date.now() - start,
    };
    return result;
  }

  async embedBatch(texts: string[], model?: string): Promise<EmbeddingResult[]> {
    if (texts.length === 0) return [];
    const out: EmbeddingResult[] = [];
    for (const t of texts) {
      const rq: EmbeddingRequest = { text: t, model };
      out.push(await this.embedText(rq));
    }
    return out;
  }
}
