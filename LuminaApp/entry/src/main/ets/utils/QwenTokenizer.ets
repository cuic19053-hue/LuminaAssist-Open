/**
 * @file QwenTokenizer.ets
 * @module utils
 * @description Qwen2 字节级 BPE 分词器（纯逻辑，可单元测试）。
 *
 * 依据 Qwen2-0.5B-Instruct 的 vocab.json + merges.txt 实现 GPT-2 风格 byte-level BPE：
 * 1. 文本按 GPT-2 正则预切分；
 * 2. 每个片段 UTF-8 编码后经 bytes_to_unicode 映射为可打印字符序列；
 * 3. 按 merges.txt 优先级合并；
 * 4. 查 vocab.json 得到 token id。
 *
 * 资产约定（由 scripts/get_model_weights.ps1 下载并放置）：
 *   rawfile/models/qwen_vocab.json   （token -> id）
 *   rawfile/models/qwen_merges.txt   （BPE 合并规则）
 */

const BYTE_ENCODER: Map<number, string> = buildByteEncoder();
const BYTE_DECODER: Map<string, number> = buildByteDecoder(BYTE_ENCODER);

function buildByteEncoder(): Map<number, string> {
  const bs: Array<number> = [];
  for (let b = 33; b <= 126; b++) {
    bs.push(b);
  }
  for (let b = 161; b <= 172; b++) {
    bs.push(b);
  }
  for (let b = 174; b <= 255; b++) {
    bs.push(b);
  }
  const cs: Array<string> = bs.map((b: number): string => String.fromCharCode(b));
  let n: number = 0;
  const encoder: Map<number, string> = new Map<number, string>();
  for (let b = 0; b < 256; b++) {
    if (bs.indexOf(b) === -1) {
      bs.push(b);
      cs.push(String.fromCharCode(256 + n));
      n++;
    }
  }
  for (let i = 0; i < bs.length; i++) {
    encoder.set(bs[i], cs[i]);
  }
  return encoder;
}

function buildByteDecoder(encoder: Map<number, string>): Map<string, number> {
  const decoder: Map<string, number> = new Map<string, number>();
  encoder.forEach((v: string, k: number) => {
    decoder.set(v, k);
  });
  return decoder;
}

/** GPT-2 预切分正则（Qwen2 采用同族模式，\p{L}/\p{N} 需 u 标志） */
const SPLIT_RE: RegExp =
  /'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+/gu;

/**
 * 字节级 BPE 分词器。
 */
export class QwenTokenizer {
  private vocab: Map<string, number> = new Map<string, number>();
  private reverseVocab: Map<number, string> = new Map<number, string>();
  private mergeRanks: Map<string, number> = new Map<string, number>();
  private _ready: boolean = false;

  public get ready(): boolean {
    return this._ready;
  }

  public get vocabSize(): number {
    return this.vocab.size;
  }

  /**
   * 从文本内容初始化（内容由调用方从 rawfile / 沙箱读出）。
   * @param vocabJson vocab.json 文本
   * @param mergesText merges.txt 文本
   */
  public loadFromText(vocabJson: string, mergesText: string): void {
    const parsed: Record<string, number> = JSON.parse(vocabJson) as Record<string, number>;
    const keys: Array<string> = Object.keys(parsed);
    for (const k of keys) {
      this.vocab.set(k, parsed[k]);
    }
    this.vocab.forEach((v: number, k: string) => {
      this.reverseVocab.set(v, k);
    });

    const lines: Array<string> = mergesText.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.startsWith('#version')) {
        continue;
      }
      const parts: Array<string> = line.split(' ');
      if (parts.length === 2) {
        this.mergeRanks.set(parts[0] + ',' + parts[1], this.mergeRanks.size);
      }
    }
    this._ready = true;
  }

  /**
   * 文本 -> token ids（含 BPE 合并）。
   */
  public encode(text: string): Array<number> {
    if (!this._ready) {
      throw new Error('QwenTokenizer 未初始化');
    }
    const pieces: Array<string> = text.match(SPLIT_RE) ?? [text];
    const ids: Array<number> = [];
    for (const piece of pieces) {
      const word: Array<string> = this.byteEncode(piece);
      const merged: Array<string> = this.bpe(word);
      for (const sym of merged) {
        const id: number | undefined = this.vocab.get(sym);
        if (id !== undefined) {
          ids.push(id);
        }
      }
    }
    return ids;
  }

  /**
   * token ids -> 文本。
   */
  public decode(ids: Array<number>): string {
    if (!this._ready) {
      throw new Error('QwenTokenizer 未初始化');
    }
    let bytes: Array<number> = [];
    for (const id of ids) {
      const token: string | undefined = this.reverseVocab.get(id);
      if (token === undefined) {
        continue;
      }
      for (const ch of token) {
        const b: number | undefined = BYTE_DECODER.get(ch);
        if (b !== undefined) {
          bytes.push(b);
        }
      }
    }
    return utf8Decode(bytes);
  }

  /** UTF-8 字节 -> byte-unicode 字符序列 */
  private byteEncode(piece: string): Array<string> {
    const bytes: Array<number> = utf8Encode(piece);
    const out: Array<string> = [];
    for (const b of bytes) {
      const c: string | undefined = BYTE_ENCODER.get(b);
      if (c !== undefined) {
        out.push(c);
      }
    }
    return out;
  }

  /** 经典 BPE：反复合并 rank 最小的相邻 pair */
  private bpe(word: Array<string>): Array<string> {
    if (word.length <= 1) {
      return word;
    }
    let symbols: Array<string> = word.slice();
    while (true) {
      let bestRank: number = -1;
      let bestIdx: number = -1;
      for (let i = 0; i < symbols.length - 1; i++) {
        const rank: number | undefined = this.mergeRanks.get(symbols[i] + ',' + symbols[i + 1]);
        if (rank !== undefined && (bestRank === -1 || rank < bestRank)) {
          bestRank = rank;
          bestIdx = i;
        }
      }
      if (bestIdx === -1) {
        break;
      }
      const merged: string = symbols[bestIdx] + symbols[bestIdx + 1];
      symbols.splice(bestIdx, 2, merged);
    }
    return symbols;
  }

  /**
   * 拼接 Qwen2 ChatML 模板（planning 用）。
   */
  public applyChatTemplate(system: string, user: string): string {
    return '<|im_start|>system\n' + system + '<|im_end|>\n' +
      '<|im_start|>user\n' + user + '<|im_end|>\n' +
      '<|im_start|>assistant\n';
  }
}

/** UTF-8 编码（纯 ArkTS，无 TextEncoder 依赖，便于纯逻辑单测） */
export function utf8Encode(text: string): Array<number> {
  const out: Array<number> = [];
  for (let i = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const lo: number = text.charCodeAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    } else {
      out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
        0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    }
  }
  return out;
}

/** UTF-8 解码 */
export function utf8Decode(bytes: Array<number>): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b: number = bytes[i];
    let code: number = 0;
    let len: number = 1;
    if (b < 0x80) {
      code = b;
      len = 1;
    } else if ((b & 0xE0) === 0xC0) {
      code = b & 0x1F;
      len = 2;
    } else if ((b & 0xF0) === 0xE0) {
      code = b & 0x0F;
      len = 3;
    } else if ((b & 0xF8) === 0xF0) {
      code = b & 0x07;
      len = 4;
    } else {
      i++;
      continue;
    }
    if (i + len > bytes.length) {
      break;
    }
    let valid: boolean = true;
    for (let j = 1; j < len; j++) {
      if ((bytes[i + j] & 0xC0) !== 0x80) {
        valid = false;
        break;
      }
      code = (code << 6) | (bytes[i + j] & 0x3F);
    }
    if (!valid) {
      i++;
      continue;
    }
    if (code >= 0x10000) {
      code -= 0x10000;
      out += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF));
    } else {
      out += String.fromCharCode(code);
    }
    i += len;
  }
  return out;
}
