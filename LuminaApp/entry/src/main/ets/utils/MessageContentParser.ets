/**
 * @file MessageContentParser.ets
 * @module utils
 * @description 将 AI 长文本回复解析为结构化块，便于无障碍友好排版。
 */

/** 消息块类型 */
export type MessageBlockType = 'heading' | 'section' | 'paragraph' | 'warning' | 'tip';

/** 结构化消息块 */
export interface MessageBlock {
  type: MessageBlockType;
  title: string;
  content: string;
}

/** 已知字段标签 → 展示标题 */
interface LabelRule {
  keyword: string;
  title: string;
  blockType: MessageBlockType;
}

const LABEL_RULES: Array<LabelRule> = [
  { keyword: '药品', title: '药品名称', blockType: 'heading' },
  { keyword: '主要成分', title: '主要成分', blockType: 'section' },
  { keyword: '规格', title: '规格', blockType: 'section' },
  { keyword: '用途', title: '用途', blockType: 'section' },
  { keyword: '适应症', title: '用途', blockType: 'section' },
  { keyword: '怎么使用', title: '用法用量', blockType: 'section' },
  { keyword: '用法', title: '用法用量', blockType: 'section' },
  { keyword: '用量', title: '用法用量', blockType: 'section' },
  { keyword: '禁忌', title: '禁忌注意', blockType: 'warning' },
  { keyword: '注意', title: '注意事项', blockType: 'warning' },
  { keyword: '警告', title: '重要警告', blockType: 'warning' },
  { keyword: '不良反应', title: '可能的不良反应', blockType: 'section' },
  { keyword: '相互作用', title: '相互作用', blockType: 'section' },
  { keyword: '特殊人群', title: '特殊人群', blockType: 'warning' },
  { keyword: '重要提醒', title: '重要提醒', blockType: 'warning' },
  { keyword: '有效期', title: '有效期', blockType: 'section' },
  { keyword: '生产厂家', title: '生产厂家', blockType: 'section' },
  { keyword: '联网核对', title: '联网核对', blockType: 'section' },
  { keyword: '安全提示', title: '安全提示', blockType: 'tip' }
];

const WARNING_HINTS: Array<string> = [
  '禁止', '不得', '不要', '严禁', '过敏', '立即就医', '120', '停药',
  '危险', '过量', '中毒', '紧急', '就医', '咨询医生', '咨询药师', '外用品'
];

/**
 * 将 AI 回复文本解析为结构化块列表。
 */
export class MessageContentParser {
  public static parse(text: string): Array<MessageBlock> {
    if (!text || text.trim().length === 0) {
      return [];
    }
    const normalized: string = text.replace(/\r\n/g, '\n').trim();
    const lines: Array<string> = normalized.split('\n');
    const blocks: Array<MessageBlock> = [];

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const labeled: MessageBlock | null = MessageContentParser.tryParseLabelLine(line);
      if (labeled !== null) {
        blocks.push(labeled);
        continue;
      }
      const sentenceBlocks: Array<MessageBlock> = MessageContentParser.splitToSentenceBlocks(line);
      for (let j = 0; j < sentenceBlocks.length; j++) {
        blocks.push(sentenceBlocks[j]);
      }
    }

    if (blocks.length === 0) {
      blocks.push({ type: 'paragraph', title: '', content: normalized });
    }
    return blocks;
  }

  private static tryParseLabelLine(line: string): MessageBlock | null {
    const colonIdx: number = line.indexOf('：');
    const asciiColonIdx: number = line.indexOf(':');
    let splitIdx: number = -1;
    if (colonIdx >= 0 && (asciiColonIdx < 0 || colonIdx <= asciiColonIdx)) {
      splitIdx = colonIdx;
    } else if (asciiColonIdx >= 0) {
      splitIdx = asciiColonIdx;
    }
    if (splitIdx <= 0 || splitIdx > 12) {
      return null;
    }
    const rawLabel: string = line.substring(0, splitIdx).trim();
    const content: string = line.substring(splitIdx + 1).trim();
    if (content.length === 0) {
      return null;
    }
    for (let i = 0; i < LABEL_RULES.length; i++) {
      const rule: LabelRule = LABEL_RULES[i];
      if (rawLabel.indexOf(rule.keyword) >= 0) {
        return { type: rule.blockType, title: rule.title, content: content };
      }
    }
    return { type: 'section', title: rawLabel, content: content };
  }

  private static splitToSentenceBlocks(text: string): Array<MessageBlock> {
    const parts: Array<string> = text.split(/(?<=[。！？；])/);
    const blocks: Array<MessageBlock> = [];
    for (let i = 0; i < parts.length; i++) {
      const sentence: string = parts[i].trim();
      if (sentence.length === 0) {
        continue;
      }
      blocks.push({
        type: MessageContentParser.isWarningText(sentence) ? 'warning' : 'paragraph',
        title: '',
        content: sentence
      });
    }
    return blocks;
  }

  private static isWarningText(text: string): boolean {
    for (let i = 0; i < WARNING_HINTS.length; i++) {
      if (text.indexOf(WARNING_HINTS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }
}
