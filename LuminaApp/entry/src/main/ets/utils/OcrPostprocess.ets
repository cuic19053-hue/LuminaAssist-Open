/**
 * @file OcrPostprocess.ets
 * @module utils
 * @description PaddleOCR 端侧后处理纯逻辑模块（可单元测试）。
 *
 * 包含三部分：
 * 1. DBNet 概率图后处理：二值化 -> 连通域 -> 文本框（DB 可微二聚的简化 CPU 版）；
 * 2. 几何工具：框从模型输入坐标映射回原图、按阅读顺序排序、透视裁剪（用仿射近似）；
 * 3. CRNN CTC 贪心解码。
 */

/** 单个文本区域框（原图像素坐标，顺序：左上、右上、右下、左下） */
export interface OcrBox {
  points: Array<[number, number]>;
}

/** 单行识别结果 */
export interface OcrLine {
  text: string;
  confidence: number;
  box: OcrBox;
}

/** 模型输入/输出尺寸常量（与 convert_models.sh 中 converter_lite --inputShape 一致） */
export const DET_INPUT: number = 320;
export const REC_WIDTH: number = 320;
export const REC_HEIGHT: number = 48;
/** DB 二值化阈值 */
export const DB_THRESH: number = 0.3;
/** 最小框面积（像素），过滤噪点 */
export const MIN_BOX_AREA: number = 80;

/**
 * DBNet 概率图 -> 文本框（模型输入坐标系）。
 * @param probMap [DET_INPUT*DET_INPUT] Float32，值域 [0,1]
 */
export function findTextBoxes(probMap: Float32Array): Array<OcrBox> {
  const visited: Array<boolean> = new Array<boolean>(DET_INPUT * DET_INPUT).fill(false);
  const boxes: Array<OcrBox> = [];
  const queue: Array<number> = [];
  for (let start = 0; start < DET_INPUT * DET_INPUT; start++) {
    if (visited[start] || probMap[start] < DB_THRESH) {
      continue;
    }
    // BFS 连通域
    queue.length = 0;
    queue.push(start);
    visited[start] = true;
    let minX: number = DET_INPUT;
    let minY: number = DET_INPUT;
    let maxX: number = 0;
    let maxY: number = 0;
    let count: number = 0;
    let sum: number = 0;
    let head: number = 0;
    while (head < queue.length) {
      const idx: number = queue[head];
      head++;
      const x: number = idx % DET_INPUT;
      const y: number = Math.floor(idx / DET_INPUT);
      count++;
      sum += probMap[idx];
      if (x < minX) { minX = x; }
      if (x > maxX) { maxX = x; }
      if (y < minY) { minY = y; }
      if (y > maxY) { maxY = y; }
      const neighbors: Array<number> = [idx - 1, idx + 1, idx - DET_INPUT, idx + DET_INPUT];
      for (let n = 0; n < neighbors.length; n++) {
        const nb: number = neighbors[n];
        if (nb < 0 || nb >= DET_INPUT * DET_INPUT || visited[nb]) {
          continue;
        }
        // 防止左右跨行
        if (n === 0 && x === 0) { continue; }
        if (n === 1 && x === DET_INPUT - 1) { continue; }
        if (probMap[nb] >= DB_THRESH) {
          visited[nb] = true;
          queue.push(nb);
        }
      }
    }
    if (count < 4) { continue; }
    const w: number = maxX - minX + 1;
    const h: number = maxY - minY + 1;
    if (w * h < MIN_BOX_AREA) { continue; }
    // 按 DB 论文用区域均值校验置信度
    const score: number = sum / count;
    if (score < DB_THRESH) { continue; }
    boxes.push({
      points: [[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]]
    });
  }
  return boxes;
}

/**
 * 将模型输入坐标系中的框映射回原图坐标系。
 * @param boxes 模型输入坐标框
 * @param srcWidth 原图宽
 * @param srcHeight 原图高（det 预处理为等比缩放 + padding 到 DET_INPUT）
 */
export function mapBoxesToSource(boxes: Array<OcrBox>, srcWidth: number, srcHeight: number): Array<OcrBox> {
  const scale: number = Math.min(DET_INPUT / srcWidth, DET_INPUT / srcHeight);
  const padX: number = (DET_INPUT - srcWidth * scale) / 2;
  const padY: number = (DET_INPUT - srcHeight * scale) / 2;
  return boxes.map((b: OcrBox): OcrBox => {
    return {
      points: b.points.map((p: [number, number]): [number, number] => {
        return [(p[0] - padX) / scale, (p[1] - padY) / scale];
      })
    };
  });
}

/**
 * 框按阅读顺序排序：先按纵坐标分行（行高容差 50%），行内按横坐标。
 */
export function sortBoxesReadingOrder(boxes: Array<OcrBox>): Array<OcrBox> {
  const sorted: Array<OcrBox> = boxes.slice();
  sorted.sort((a: OcrBox, b: OcrBox): number => {
    const ay: number = a.points[0][1];
    const by: number = b.points[0][1];
    const ah: number = Math.max(1, a.points[2][1] - a.points[0][1]);
    const bh: number = Math.max(1, b.points[2][1] - b.points[0][1]);
    const sameLine: boolean = Math.abs(ay - by) < Math.min(ah, bh) * 0.5;
    if (sameLine) {
      return a.points[0][0] - b.points[0][0];
    }
    return ay - by;
  });
  return sorted;
}

/**
 * CTC 贪心解码。
 * @param probs [seqLen * numClasses] 逐帧类别概率
 * @param seqLen 时间步数
 * @param numClasses 类别数（含 index 0 = CTC blank）
 * @param charset 字符表（index 0 blank；index 1..N 对应 charset[0..N-1]）
 */
export function ctcGreedyDecode(
  probs: Float32Array,
  seqLen: number,
  numClasses: number,
  charset: Array<string>
): OcrLineText {
  let text: string = '';
  let confSum: number = 0;
  let confCount: number = 0;
  let prevClass: number = -1;
  for (let t = 0; t < seqLen; t++) {
    let best: number = 0;
    let bestScore: number = probs[t * numClasses];
    for (let c = 1; c < numClasses; c++) {
      const s: number = probs[t * numClasses + c];
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    if (best !== 0 && best !== prevClass) {
      // blank=0；类别 i 对应 charset[i-1]
      const ch: string = charset[best - 1] ?? '';
      if (ch.length > 0) {
        text += ch;
        confSum += bestScore;
        confCount++;
      }
    }
    prevClass = best;
  }
  return { text: text, confidence: confCount > 0 ? confSum / confCount : 0 };
}

/** CTC 解码结果 */
export interface OcrLineText {
  text: string;
  confidence: number;
}

/**
 * rec 输入预处理：把裁剪出的行图（RGBA 像素）等比缩放到 48 高、pad 到 320 宽，
 * 归一化 (x/255 - 0.5)/0.5，输出 CHW Float32。
 */
export function recPreprocess(
  rgba: Uint8Array,
  srcWidth: number,
  srcHeight: number
): Float32Array {
  const scale: number = Math.min(REC_HEIGHT / srcHeight, REC_WIDTH / srcWidth);
  const newW: number = Math.max(1, Math.floor(srcWidth * scale));
  const newH: number = Math.max(1, Math.floor(srcHeight * scale));
  const out: Float32Array = new Float32Array(3 * REC_HEIGHT * REC_WIDTH);
  for (let y = 0; y < REC_HEIGHT; y++) {
    for (let x = 0; x < REC_WIDTH; x++) {
      // 双线性最近邻近似：源图内取点，越界 pad 0（归一化后为 -1）
      let r: number = -1;
      let g: number = -1;
      let b: number = -1;
      if (x < newW && y < newH) {
        const sx: number = Math.min(srcWidth - 1, Math.floor(x / scale));
        const sy: number = Math.min(srcHeight - 1, Math.floor(y / scale));
        const si: number = (sy * srcWidth + sx) * 4;
        r = (rgba[si] / 255.0 - 0.5) / 0.5;
        g = (rgba[si + 1] / 255.0 - 0.5) / 0.5;
        b = (rgba[si + 2] / 255.0 - 0.5) / 0.5;
      }
      out[0 * REC_HEIGHT * REC_WIDTH + y * REC_WIDTH + x] = r;
      out[1 * REC_HEIGHT * REC_WIDTH + y * REC_WIDTH + x] = g;
      out[2 * REC_HEIGHT * REC_WIDTH + y * REC_WIDTH + x] = b;
    }
  }
  return out;
}

/**
 * det 输入预处理：RGBA -> RGB 等比缩放 + padding 到 320x320，归一化 (x/255-0.5)/0.5，CHW。
 * 同时返回缩放参数供坐标映射（本模块 mapBoxesToSource 使用相同公式）。
 */
export function detPreprocess(
  rgba: Uint8Array,
  srcWidth: number,
  srcHeight: number
): Float32Array {
  const scale: number = Math.min(DET_INPUT / srcWidth, DET_INPUT / srcHeight);
  const newW: number = Math.max(1, Math.floor(srcWidth * scale));
  const newH: number = Math.max(1, Math.floor(srcHeight * scale));
  const padX: number = Math.floor((DET_INPUT - newW) / 2);
  const padY: number = Math.floor((DET_INPUT - newH) / 2);
  const out: Float32Array = new Float32Array(3 * DET_INPUT * DET_INPUT);
  // 先填充 -1（pad 归一化值）
  out.fill(-1);
  for (let y = 0; y < newH; y++) {
    const sy: number = Math.min(srcHeight - 1, Math.floor(y / scale));
    for (let x = 0; x < newW; x++) {
      const sx: number = Math.min(srcWidth - 1, Math.floor(x / scale));
      const si: number = (sy * srcWidth + sx) * 4;
      const di: number = (y + padY) * DET_INPUT + (x + padX);
      out[0 * DET_INPUT * DET_INPUT + di] = (rgba[si] / 255.0 - 0.5) / 0.5;
      out[1 * DET_INPUT * DET_INPUT + di] = (rgba[si + 1] / 255.0 - 0.5) / 0.5;
      out[2 * DET_INPUT * DET_INPUT + di] = (rgba[si + 2] / 255.0 - 0.5) / 0.5;
    }
  }
  return out;
}
