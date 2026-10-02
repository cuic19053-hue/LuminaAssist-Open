import { describe, it, expect } from '@ohos/hypium';
import { QwenTokenizer, utf8Encode, utf8Decode } from '../../main/ets/utils/QwenTokenizer';
import {
  findTextBoxes, mapBoxesToSource, sortBoxesReadingOrder,
  ctcGreedyDecode, detPreprocess, recPreprocess,
  DET_INPUT, REC_WIDTH, REC_HEIGHT
} from '../../main/ets/utils/OcrPostprocess';

export default function engineUnitTest() {
  describe('QwenTokenizerTest', () => {
    it('utf8_roundtrip_ascii', 0, () => {
      const text: string = 'Hello, world!';
      const bytes: Array<number> = utf8Encode(text);
      expect(utf8Decode(bytes)).assertEqual(text);
    });

    it('utf8_roundtrip_chinese', 0, () => {
      const text: string = '帮我读一下桌上的字，第2行。';
      const bytes: Array<number> = utf8Encode(text);
      expect(bytes.length).assertLarger(text.length); // 中文 UTF-8 每字 3 字节
      expect(utf8Decode(bytes)).assertEqual(text);
    });

    it('utf8_roundtrip_emoji', 0, () => {
      const text: string = 'ok👍';
      const bytes: Array<number> = utf8Encode(text);
      expect(bytes.length).assertEqual(2 + 4); // ascii*2 + emoji 4 字节
      expect(utf8Decode(bytes)).assertEqual(text);
    });

    it('byte_bpe_roundtrip', 0, () => {
      // 构造微型词表：单字符 + 一个合并规则
      // vocab 键使用 byte-unicode 表示：可打印 ascii 直接是原字符
      let vocabJson: string = '{"h":0,"e":1,"l":2,"o":3,"hello":4}';
      let mergesText: string = '#version: 0.2\nh e\nhe l\nhel l\nhell o\n';
      const tk: QwenTokenizer = new QwenTokenizer();
      tk.loadFromText(vocabJson, mergesText);
      expect(tk.ready).assertTrue();
      expect(tk.vocabSize).assertEqual(5);

      const ids: Array<number> = tk.encode('hello');
      expect(ids.length).assertLarger(0);
      // BPE 应能合并出 "hello"（id=4）
      expect(ids.indexOf(4)).assertLarger(-1);
      // 解码回原文
      expect(tk.decode(ids)).assertEqual('hello');
    });

    it('unknown_token_skipped', 0, () => {
      const tk: QwenTokenizer = new QwenTokenizer();
      tk.loadFromText('{"a":0}', '#version: 0.2\n');
      // "b" 不在词表，encode 应跳过而不崩溃
      expect(tk.encode('b').length).assertEqual(0);
    });

    it('not_ready_throws', 0, () => {
      const tk: QwenTokenizer = new QwenTokenizer();
      let threw: boolean = false;
      try {
        tk.encode('hello');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('chat_template_markers', 0, () => {
      const tk: QwenTokenizer = new QwenTokenizer();
      tk.loadFromText('{}', '#version: 0.2\n');
      const prompt: string = tk.applyChatTemplate('sys', 'user text');
      expect(prompt).assertContain('<|im_start|>system');
      expect(prompt).assertContain('<|im_end|>');
      expect(prompt).assertContain('<|im_start|>assistant');
    });
  });

  describe('OcrPostprocessTest', () => {
    it('find_no_text_in_blank_map', 0, () => {
      const blank: Float32Array = new Float32Array(DET_INPUT * DET_INPUT);
      expect(findTextBoxes(blank).length).assertEqual(0);
    });

    it('find_single_text_box', 0, () => {
      const prob: Float32Array = new Float32Array(DET_INPUT * DET_INPUT);
      // 在 (50..80, 40..55) 画一个高亮文本区域
      for (let y = 40; y < 55; y++) {
        for (let x = 50; x < 80; x++) {
          prob[y * DET_INPUT + x] = 0.9;
        }
      }
      const boxes = findTextBoxes(prob);
      expect(boxes.length).assertEqual(1);
      const b = boxes[0];
      // 检测到框左上角应接近 (50, 40)
      expect(Math.abs(b.points[0][0] - 50)).assertLarger(-1);
      expect(b.points[0][0]).assertEqual(50);
      expect(b.points[0][1]).assertEqual(40);
      expect(b.points[2][0]).assertEqual(79);
      expect(b.points[2][1]).assertEqual(54);
    });

    it('map_boxes_identity_when_same_size', 0, () => {
      const boxes = [{
        points: [[0, 0] as [number, number], [10, 0] as [number, number],
          [10, 10] as [number, number], [0, 10] as [number, number]]
      }];
      const mapped = mapBoxesToSource(boxes, DET_INPUT, DET_INPUT);
      expect(mapped[0].points[0][0]).assertEqual(0);
      expect(mapped[0].points[2][1]).assertEqual(10);
    });

    it('sort_reading_order', 0, () => {
      // 右上的框先创建，应排在左下框之后
      const topRight = {
        points: [[200, 10] as [number, number], [300, 10] as [number, number],
          [300, 30] as [number, number], [200, 30] as [number, number]]
      };
      const bottomLeft = {
        points: [[10, 100] as [number, number], [100, 100] as [number, number],
          [100, 130] as [number, number], [10, 130] as [number, number]]
      };
      const sorted = sortBoxesReadingOrder([bottomLeft, topRight]);
      expect(sorted[0].points[0][1]).assertEqual(10);
      expect(sorted[1].points[0][1]).assertEqual(100);
    });

    it('ctc_decode_with_blank_and_collapse', 0, () => {
      // numClasses=4: 0=blank, 1='a', 2='b', 3='c'
      const numClasses: number = 4;
      const seqLen: number = 5;
      const probs: Float32Array = new Float32Array(seqLen * numClasses);
      const set = (t: number, c: number, v: number): void => {
        probs[t * numClasses + c] = v;
      };
      set(0, 0, 0.9); // blank
      set(1, 1, 0.8); // 'a'
      set(2, 1, 0.7); // 'a' 连续 -> 折叠
      set(3, 0, 0.6); // blank
      set(4, 2, 0.9); // 'b'
      const result = ctcGreedyDecode(probs, seqLen, numClasses, ['a', 'b', 'c']);
      expect(result.text).assertEqual('ab');
      expect(result.confidence).assertLarger(0.5);
    });

    it('det_preprocess_size', 0, () => {
      const rgba: Uint8Array = new Uint8Array(100 * 50 * 4);
      const out: Float32Array = detPreprocess(rgba, 100, 50);
      expect(out.length).assertEqual(3 * DET_INPUT * DET_INPUT);
      // pad 区域值应为 -1
      expect(out[0]).assertEqual(-1);
    });

    it('rec_preprocess_size', 0, () => {
      const rgba: Uint8Array = new Uint8Array(60 * 20 * 4);
      const out: Float32Array = recPreprocess(rgba, 60, 20);
      expect(out.length).assertEqual(3 * REC_HEIGHT * REC_WIDTH);
    });
  });
}
