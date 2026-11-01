// 测试替身：模拟 CloudModelProxy 的流式行为，完全离线可运行。
// 逐 token 发回（节流 30ms），支持中途取消。

import { SourceCitation } from '../../model/Knowledge';
import {
  IChatService, ChatTurn, ChatHandle, StreamEventImpl
} from '../types';

interface BuildSeg {
  text: string;
  documentTitle: string;
}

export class TestCloudModelService implements IChatService {
  ask(
    turn: ChatTurn,
    onEvent: (event: StreamEventImpl) => void,
    onComplete: () => void
  ): ChatHandle {
    let cancelled = false;
    let completed = false;
    const timers: number[] = [];
    const delay = 30;

    const finish = (): void => {
      if (completed) return;
      completed = true;
      for (let i = 0; i < timers.length; i++) {
        clearTimeout(timers[i]);
      }
      timers.length = 0;
      onComplete();
    };

    const cancel = (): void => {
      cancelled = true;
      finish();
    };

    const segments: BuildSeg[] = turn.segments ?? [];
    const answer = buildAnswer(turn.question, segments);

    onEvent(StreamEventImpl.makeRetrieving());

    // citation 事件
    const rawSegs = turn.segments ?? [];
    for (let i = 0; i < rawSegs.length; i++) {
      const seg = rawSegs[i];
      const t: number = setTimeout((): void => {
        if (cancelled || completed) return;
        const c: SourceCitation = {
          documentId: seg.documentId,
          documentRevision: 0,
          segmentId: seg.segmentId,
          documentTitle: seg.documentTitle,
          source: seg.source,
          excerpt: seg.text.length > 40 ? seg.text.substring(0, 40) : seg.text,
        };
        onEvent(StreamEventImpl.makeCitation(c));
      }, delay * (i + 1) * 2);
      timers.push(t);
    }

    let idx = 0;
    const tick = (): void => {
      if (cancelled || completed) return;
      if (idx >= answer.length) {
        onEvent(StreamEventImpl.makeDone());
        finish();
        return;
      }
      const remaining = answer.length - idx;
      const chunkLen = Math.min(remaining, 2 + (idx % 3));
      const chunk = answer.substring(idx, idx + chunkLen);
      onEvent(StreamEventImpl.makeToken(chunk));
      idx += chunkLen;
      const t: number = setTimeout(tick, delay);
      timers.push(t);
    };
    tick();

    const handle: ChatHandle = { cancel: cancel };
    return handle;
  }
}

function buildAnswer(question: string, segments: BuildSeg[]): string {
  if (segments.length === 0) {
    return '现有资料中没有找到与这个问题相关的内容，请尝试换一种方式提问。';
  }
  const cited: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    const t = seg.text.length > 80 ? seg.text.substring(0, 80) + '...' : seg.text;
    cited.push('[' + (i + 1) + '] ' + t);
  }
  return '根据课程资料的梳理：\n' + cited.join('\n') + '\n\n希望这段资料能帮到你。';
}
