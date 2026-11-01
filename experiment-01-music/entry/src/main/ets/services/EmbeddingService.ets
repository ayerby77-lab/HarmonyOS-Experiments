// ============================================================================
// EmbeddingService - 将文本转换为向量（用于语义匹配）
// ============================================================================
// 鸿蒙端没有原生 ML Kit，这里实现一个轻量的本地模拟版本：
//   1. 对中文做简单的字/词切分（单字 + 常用双字组合）
//   2. 计算 "Term Frequency" 构成稀疏向量
//   3. 向量序列化为 JSON 存入数据库
// 接口保持与云端 Embedding 模型一致，方便后续替换为 CFKit 云端调用。
// ============================================================================

/** 向量维度（模拟向量空间维度） */
const VEC_DIM: number = 128;

export interface EmbeddingService {
  /** 将文本编码为向量 */
  encode(text: string): number[];
  /** 批量编码 */
  encodeBatch(texts: string[]): number[][];
}

export class LocalEmbeddingService implements EmbeddingService {
  /**
   * 简易分词：单字 + 相邻双字组合
   * 例: "人工智能" -> ["人","工","智","能","人工","工智","智能"]
   */
  private tokenize(text: string): string[] {
    const tokens: string[] = [];
    if (!text || text.length === 0) { return tokens; }
    // 过滤空白符
    const clean = text.replace(/\s+/g, '');
    for (let i = 0; i < clean.length; i++) {
      const ch = clean[i];
      if (ch && ch.length > 0) { tokens.push(ch); }
    }
    for (let i = 0; i < clean.length - 1; i++) {
      const bi = clean.substring(i, i + 2);
      if (bi && bi.length === 2) { tokens.push(bi); }
    }
    return tokens;
  }

  /**
   * 简易哈希到向量维度的桶（SimHash 思路）
   */
  private hashBucket(token: string): number {
    let h: number = 0;
    for (let i = 0; i < token.length; i++) {
      h = (h * 31 + token.charCodeAt(i)) >>> 0;
    }
    return h % VEC_DIM;
  }

  encode(text: string): number[] {
    const tokens: string[] = this.tokenize(text);
    const vec: number[] = new Array(VEC_DIM).fill(0);
    for (const tok of tokens) {
      const bucket = this.hashBucket(tok);
      vec[bucket] += 1;
    }
    // L2 归一化
    let norm: number = 0;
    for (const v of vec) { norm += v * v; }
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let i = 0; i < vec.length; i++) { vec[i] = vec[i] / norm; }
    }
    return vec;
  }

  encodeBatch(texts: string[]): number[][] {
    return texts.map(t => this.encode(t));
  }

  /** 计算余弦相似度 */
  static cosineSimilarity(a: number[], b: number[]): number {
    if (a.length !== b.length) { return 0; }
    let dot: number = 0;
    for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; }
    return dot;
  }
}

/** 辅助：为文本提取关键词（Top N tokens） */
export function extractKeywords(text: string, topN: number = 6): string {
  const tokens: string[] = [];
  const clean = text.replace(/\s+/g, '');
  // 优先双字
  for (let i = 0; i < clean.length - 1; i++) {
    tokens.push(clean.substring(i, i + 2));
  }
  // 再单字
  for (let i = 0; i < clean.length; i++) {
    tokens.push(clean[i]);
  }
  // 统计频率
  const freq: Record<string, number> = {};
  for (const t of tokens) {
    freq[t] = (freq[t] || 0) + 1;
  }
  const entries = Object.entries(freq).sort((a, b) => b[1] - a[1]);
  const stopwords: Set<string> = new Set(['的', '了', '是', '在', '我', '有', '和', '就', '不', '人', '都', '一', '一个', '上', '也', '很', '到', '说', '要', '去', '你', '会', '着', '没有', '看', '好', '自己', '这']);
  const filtered = entries.filter(([w]) => !stopwords.has(w) && w.trim().length > 0);
  const top = filtered.slice(0, topN).map(([w]) => w);
  return top.join(',');
}
