import { KnowledgeSegment } from '../model/Knowledge';

/** 单段最大字符数，超过后按句子切分 */
const MAX_SEGMENT_CHARS = 400;
/** 单段最小字符数，避免切得过碎 */
const MIN_SEGMENT_CHARS = 80;

/** 句子结束标点 */
const SENTENCE_END = /[。！？!?；;]/;
/** 段落分隔（两个及以上换行） */
const PARAGRAPH_SPLIT = /\n{2,}/g;

/**
 * 资料切分服务。
 * 策略：先按段落切分；段落过长则按句子聚合到接近 MAX_SEGMENT_CHARS。
 * 每个片段保留原文起止字符偏移，可精确定位原文。
 */
export class SegmentService {

  /**
   * 将资料正文切分为片段。
   * @param documentId 资料 ID
   * @param revision 资料版本
   * @param content 原文正文
   * @returns 切分后的片段数组，按顺序排列
   */
  split(documentId: string, revision: number, content: string): KnowledgeSegment[] {
    if (!content || content.length === 0) {
      return [];
    }

    const paragraphs = this.splitParagraphs(content);
    const segments: KnowledgeSegment[] = [];
    let seqIndex = 0;

    for (const para of paragraphs) {
      const paraSegments = this.splitParagraph(para.text, para.start, documentId, revision, seqIndex);
      segments.push(...paraSegments);
      seqIndex += paraSegments.length;
    }

    return segments;
  }

  /** 按段落切分，记录每段在原文中的起止偏移 */
  private splitParagraphs(content: string): Array<{ text: string; start: number }> {
    const result: Array<{ text: string; start: number }> = [];
    const matches = content.matchAll(PARAGRAPH_SPLIT);
    let lastEnd = 0;
    for (const match of matches) {
      const start = lastEnd;
      const end = match.index ?? content.length;
      const text = content.substring(start, end);
      if (text.trim().length > 0) {
        result.push({ text, start });
      }
      lastEnd = end + (match[0].length);
    }
    // 最后一段
    const lastText = content.substring(lastEnd);
    if (lastText.trim().length > 0) {
      result.push({ text: lastText, start: lastEnd });
    }
    return result;
  }

  /**
   * 切分单个段落。
   * 若段落长度 <= MAX_SEGMENT_CHARS，直接作为一个片段。
   * 否则按句子聚合，每段接近 MAX_SEGMENT_CHARS。
   */
  private splitParagraph(
    text: string,
    baseOffset: number,
    documentId: string,
    revision: number,
    startSeq: number
  ): KnowledgeSegment[] {
    const segments: KnowledgeSegment[] = [];
    if (text.length <= MAX_SEGMENT_CHARS) {
      segments.push(this.makeSegment(documentId, revision, text, baseOffset, baseOffset + text.length, startSeq));
      return segments;
    }

    // 按句子切分
    const sentences = this.splitSentences(text);
    let currentText = '';
    let currentStart = baseOffset;
    let seq = startSeq;

    for (const sentence of sentences) {
      // 如果当前缓冲区加上这句话会超过上限，且缓冲区已有足够内容，则先提交
      if (currentText.length >= MIN_SEGMENT_CHARS && currentText.length + sentence.text.length > MAX_SEGMENT_CHARS) {
        segments.push(this.makeSegment(
          documentId, revision, currentText, currentStart, currentStart + currentText.length, seq
        ));
        seq++;
        currentText = '';
        currentStart = baseOffset + sentence.offset;
      }
      if (currentText.length === 0) {
        currentStart = baseOffset + sentence.offset;
      }
      currentText += sentence.text;
    }

    // 提交剩余内容
    if (currentText.length > 0) {
      segments.push(this.makeSegment(
        documentId, revision, currentText, currentStart, currentStart + currentText.length, seq
      ));
    }

    return segments;
  }

  /** 将段落按句子切分，保留每个句子在段落内的偏移 */
  private splitSentences(text: string): Array<{ text: string; offset: number }> {
    const sentences: Array<{ text: string; offset: number }> = [];
    let start = 0;
    for (let i = 0; i < text.length; i++) {
      if (SENTENCE_END.test(text[i])) {
        // 包含结束标点
        const end = i + 1;
        const sentence = text.substring(start, end);
        sentences.push({ text: sentence, offset: start });
        start = end;
      }
    }
    // 末尾未以标点结束的部分
    if (start < text.length) {
      sentences.push({ text: text.substring(start), offset: start });
    }
    return sentences;
  }

  private makeSegment(
    documentId: string,
    revision: number,
    content: string,
    startOffset: number,
    endOffset: number,
    seqIndex: number
  ): KnowledgeSegment {
    return {
      id: `${documentId}-r${revision}-s${seqIndex}`,
      documentId: documentId,
      documentRevision: revision,
      content: content,
      startOffset: startOffset,
      endOffset: endOffset,
      seqIndex: seqIndex
    };
  }

  /**
   * 根据片段还原其在原文中的上下文（前后各 extend 字符）。
   * @param content 原文
   * @param segment 片段
   * @param extend 前后扩展字符数
   */
  getContext(content: string, segment: KnowledgeSegment, extend: number = 50): string {
    const start = Math.max(0, segment.startOffset - extend);
    const end = Math.min(content.length, segment.endOffset + extend);
    return content.substring(start, end);
  }

  /**
   * 校验片段偏移是否与原文一致。
   * @returns 校验通过返回 true，否则返回 false
   */
  verifyOffset(content: string, segment: KnowledgeSegment): boolean {
    if (segment.startOffset < 0 || segment.endOffset > content.length) {
      return false;
    }
    if (segment.startOffset >= segment.endOffset) {
      return false;
    }
    const actual = content.substring(segment.startOffset, segment.endOffset);
    return actual === segment.content;
  }
}
