// 示例资料种子：解剖学课程的几段正文。
// 让混合检索和流式问答管道在没有 RDB 持久化的情况下也能跑通验收。

import { KnowledgeSegment } from '../../model/Knowledge';
import { ServiceContainer } from '../ServiceContainer';

interface DemoDoc {
  documentId: string;
  revision: number;
  title: string;
  source: string;
  segments: KnowledgeSegment[];
}

const HEART: DemoDoc = {
  documentId: 'doc-heart-01',
  revision: 1,
  title: '心脏概述',
  source: '系统解剖学·循环系统',
  segments: [
    { id: 'seg-heart-01', documentId: 'doc-heart-01', documentRevision: 1, content: '心脏是一个中空的肌性器官，位于胸腔中纵隔内，约三分之二在身体正中线左侧。心脏的大小约相当于本人的拳头，重约 250 至 300 克。心脏分为左心和右心，各自又有心房和心室四个腔室。', startOffset: 0, endOffset: 110, seqIndex: 0 },
    { id: 'seg-heart-02', documentId: 'doc-heart-01', documentRevision: 1, content: '心脏内共有四个瓣膜：二尖瓣位于左心房和左心室之间，三尖瓣位于右心房和右心室之间，主动脉瓣位于左心室和主动脉之间，肺动脉瓣位于右心室和肺动脉之间。这些瓣膜保证血液单向流动，防止倒流。', startOffset: 120, endOffset: 240, seqIndex: 1 },
    { id: 'seg-heart-03', documentId: 'doc-heart-01', documentRevision: 1, content: '心脏的传导系统由特殊心肌细胞构成，包括窦房结、结间束、房室结、房室束、左右束支和浦肯野纤维网。窦房结是心脏的起搏点，位于右心房与上腔静脉交界处。', startOffset: 250, endOffset: 370, seqIndex: 2 },
  ],
};

const LUNG: DemoDoc = {
  documentId: 'doc-lung-01',
  revision: 1,
  title: '肺的形态',
  source: '系统解剖学·呼吸系统',
  segments: [
    { id: 'seg-lung-01', documentId: 'doc-lung-01', documentRevision: 1, content: '肺是呼吸系统的核心器官，位于胸腔内，左右各一。右肺比左肺稍大，分为三叶，左肺分为两叶，这是因为心脏偏向左侧占据了一定空间。', startOffset: 0, endOffset: 100, seqIndex: 0 },
    { id: 'seg-lung-02', documentId: 'doc-lung-01', documentRevision: 1, content: '肺小叶是肺的结构和功能单位，由一个细支气管及其分支和所属的肺泡构成。肺泡是气体交换的主要场所，成人约有 3 亿至 4 亿个肺泡，总表面积可达 70 平方米。', startOffset: 110, endOffset: 230, seqIndex: 1 },
  ],
};

const BRAIN: DemoDoc = {
  documentId: 'doc-brain-01',
  revision: 1,
  title: '大脑皮层',
  source: '系统解剖学·神经系统',
  segments: [
    { id: 'seg-brain-01', documentId: 'doc-brain-01', documentRevision: 1, content: '大脑皮层是覆盖在大脑半球表面的灰质层，厚度约 2 至 5 毫米。皮层由约 140 亿个神经元组成，分为额叶、顶叶、颞叶、枕叶和岛叶，不同脑叶负责不同的功能区域。', startOffset: 0, endOffset: 120, seqIndex: 0 },
    { id: 'seg-brain-02', documentId: 'doc-brain-01', documentRevision: 1, content: '脑干位于颅后窝，自上而下分为中脑、脑桥和延髓三部分。脑干是连接大脑与小脑、脊髓的桥梁，包含多个重要的神经核团和上下行纤维束，维持呼吸、心跳等基本生命活动。', startOffset: 130, endOffset: 260, seqIndex: 1 },
  ],
};

export function seedDemoDocuments(container: ServiceContainer): void {
  const docs: DemoDoc[] = [HEART, LUNG, BRAIN];
  for (let i = 0; i < docs.length; i++) {
    const doc = docs[i];
    container.seedDocument(
      doc.documentId, doc.revision, doc.title, doc.source, doc.segments
    );
  }
}
