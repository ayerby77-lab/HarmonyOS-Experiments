// ============================================================================
// QAService - 问答服务（提示词拼装 + LLM 调用 + 流式输出）
// ============================================================================

import { RetrievalService } from './RetrievalService';
import { KnowledgeDatabase } from './KnowledgeDatabase';
import { RetrievalResult, ChatMessage } from '../model/KnowledgeTypes';

export interface QAServiceListener {
  onStreamChunk(messageId: string, chunk: string): void;
  onComplete(messageId: string, answer: string): void;
  onError(messageId: string, errorMessage: string): void;
  onNoResults(messageId: string): void;
}

export class QAService {
  private retrieval: RetrievalService;
  private db: KnowledgeDatabase;
  private listener: QAServiceListener | undefined = undefined;
  private streamingTimers: Map<string, number> = new Map();

  constructor(db: KnowledgeDatabase) {
    this.db = db;
    this.retrieval = new RetrievalService(db);
  }

  setListener(listener: QAServiceListener): void {
    this.listener = listener;
  }

  /** 取消某条正在流式输出的消息 */
  cancelStream(messageId: string): void {
    const timer = this.streamingTimers.get(messageId);
    if (timer !== undefined) {
      clearInterval(timer);
      this.streamingTimers.delete(messageId);
    }
  }

  /** 执行问答（同步检索 + 模拟 LLM + 流式回调） */
  async ask(question: string): Promise<ChatMessage> {
    const messageId: string = `msg_${Date.now()}`;
    const userMsg: ChatMessage = {
      id: messageId,
      role: 'user',
      content: question,
      timestamp: Date.now(),
      status: 'done',
    };
    const assistantMsg: ChatMessage = {
      id: `assistant_${Date.now()}`,
      role: 'assistant',
      content: '',
      timestamp: Date.now(),
      status: 'streaming',
      sources: [],
    };

    try {
      // 步骤 1: 检索
      const sources: RetrievalResult[] = await this.retrieval.search(question, 5);

      if (sources.length === 0) {
        assistantMsg.content = '抱歉，我在课程资料中没有检索到与您问题相关的内容。您可以尝试换一个关键词，或者先导入/添加相关课程资料。';
        assistantMsg.status = 'no_results';
        this.listener?.onNoResults(assistantMsg.id);
        this.listener?.onComplete(assistantMsg.id, assistantMsg.content);
        return assistantMsg;
      }

      assistantMsg.sources = sources;

      // 步骤 2: 拼装提示词（模拟，实际应调云端大模型）
      const prompt = this.buildPrompt(question, sources);

      // 步骤 3: 调用 LLM（此处为本地模拟，真实项目通过 CFKit 云函数转发）
      const answer = await this.callLLM(prompt, sources);

      // 步骤 4: 流式输出
      await this.streamText(assistantMsg.id, answer);

      // 步骤 5: 保存历史
      try {
        await this.db.insertHistory({
          question,
          answer,
          sourcesJson: JSON.stringify(sources),
          createdAt: Date.now(),
        });
      } catch (_) { /* 不阻塞回答 */ }

      assistantMsg.content = answer;
      assistantMsg.status = 'done';
      return assistantMsg;

    } catch (error) {
      const errMsg = (error as Error).message || '请求失败，请稍后重试';
      assistantMsg.status = 'error';
      assistantMsg.errorMessage = errMsg;
      this.listener?.onError(assistantMsg.id, errMsg);
      return assistantMsg;
    }
  }

  /** ---------- 内部方法 ---------- */

  private buildPrompt(question: string, sources: RetrievalResult[]): string {
    const context = sources.map((s, i) =>
      `[资料 ${i + 1}: ${s.materialTitle}]\n${s.content}`
    ).join('\n\n');

    return `你是一个专业的课程知识问答助手。请严格基于下方提供的课程资料回答用户问题，
并在回答结尾引用资料来源编号。如果资料不足以回答问题，请说明资料中相关内容的有限。

【课程资料】
${context}

【用户问题】
${question}

【回答要求】
1. 用清晰、结构化的中文回答
2. 在关键事实后标注来源编号，如「根据资料[1]...」
3. 回答结尾列出来源：参考资料[1]、[2]
`;
  }

  /**
   * 模拟 LLM 调用：根据检索片段生成一个看起来合理的回答
   * 真实项目里应把 prompt POST 到 CFKit 云函数
   */
  private async callLLM(prompt: string, sources: RetrievalResult[]): Promise<string> {
    // 模拟网络延迟 800-1500ms
    const delay = 800 + Math.random() * 700;
    await this.wait(delay);

    if (sources.length === 0) {
      return '抱歉，课程资料中暂未找到相关内容。';
    }

    // 简单的模拟回答：把各片段首句拼起来
    const parts: string[] = [];
    parts.push('根据已检索到的课程资料，回答如下：');
    parts.push('');

    sources.forEach((s, i) => {
      const snippet = s.content.replace(/\s+/g, ' ').trim();
      const firstSentence = snippet.split(/[。！？]/)[0] || snippet.substring(0, Math.min(80, snippet.length));
      if (firstSentence.length > 10) {
        parts.push(`• ${firstSentence}。—— 来自资料[${i + 1}]《${s.materialTitle}》`);
      }
    });

    parts.push('');
    parts.push('参考资料：');
    sources.forEach((s, i) => {
      parts.push(`[${i + 1}] ${s.materialTitle}`);
    });

    return parts.join('\n');
  }

  /** 流式输出：每 60ms 吐一个字 */
  private streamText(messageId: string, fullText: string): Promise<void> {
    return new Promise((resolve) => {
      let idx = 0;
      const timer = setInterval(() => {
        if (idx >= fullText.length) {
          clearInterval(timer);
          this.streamingTimers.delete(messageId);
          this.listener?.onComplete(messageId, fullText);
          resolve();
          return;
        }
        // 一次吐 2-4 个字符，让体验更自然
        const step = 2 + Math.floor(Math.random() * 3);
        const chunk = fullText.substring(idx, idx + step);
        idx += step;
        this.listener?.onStreamChunk(messageId, chunk);
      }, 60);
      this.streamingTimers.set(messageId, timer);
    });
  }

  private wait(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
