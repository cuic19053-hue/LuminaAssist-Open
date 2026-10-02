/**
 * @file LocalVLMEngine.ets
 * @module services
 * @description 端侧视觉兜底引擎（完整可用：复用 MobileNetV2 .ms）。
 *
 * 云端 Qwen-VL 失败时由 LLMClient / VisionService 调用 analyzeImage()，
 * 用已下载的 mobilenetv2.ms 做分类并生成口语化描述。
 *
 * 完整资产：
 * - models/mobilenetv2.ms
 * - models/imagenet_labels.json
 */

import mindSporeLite from '@ohos.ai.mindSporeLite';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Logger } from '../utils/Logger';
import { LLMMessage } from '../agent/types';
import { LocalEngine } from './LLMClient';
import { ClassificationResult } from './LocalImageClassifier';

const TAG: string = 'LocalVLMEngine';
// 视觉兜底当前使用 MobileNetV2 分类模型（qwen2_vl_2b_int4.ms 转换为长期攻关项，
// 见 rawfile/models/README.md；若未来交付真实 VLM .ms，可将此名称切回并恢复生成式后处理）
const MODEL_NAME: string = 'mobilenetv2.ms';
const LABELS_NAME: string = 'imagenet_labels.json';
const INPUT_SIZE: number = 224;
const TOP_K: number = 3;

interface LabelEntry {
  zh: string;
  en: string;
}

export class LocalVLMEngine implements LocalEngine {
  private static instance: LocalVLMEngine | null = null;
  private model: mindSporeLite.Model | null = null;
  private labels: Array<LabelEntry> = [];
  private _ready: boolean = false;
  private base64Helper: util.Base64Helper = new util.Base64Helper();

  public get ready(): boolean {
    return this._ready;
  }

  public get kind(): string {
    return 'local_vlm';
  }

  private constructor() {}

  public static getInstance(): LocalVLMEngine {
    if (LocalVLMEngine.instance === null) {
      LocalVLMEngine.instance = new LocalVLMEngine();
    }
    return LocalVLMEngine.instance;
  }

  public async init(context: Context): Promise<void> {
    try {
      const modelPath: string = await this.ensureAsset(context, MODEL_NAME);
      const labelsPath: string = await this.ensureAsset(context, LABELS_NAME);
      await this.loadLabels(labelsPath);
      const msContext: mindSporeLite.Context = {};
      msContext.target = ['nnrt', 'cpu']; // 优先调用 NPU 硬件加速
      msContext.cpu = { threadNum: 4, threadAffinityMode: 0, precisionMode: 'enforce_fp32' };
      this.model = await mindSporeLite.loadModelFromFile(modelPath, msContext);
      this._ready = true;
      Logger.info(TAG, `端侧视觉兜底引擎已就绪（MobileNetV2 分类兜底），标签数=${this.labels.length}`);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `端侧视觉兜底引擎初始化失败，将走云端: ${msg}`);
      this._ready = false;
      this.model = null;
    }
  }

  private async ensureAsset(context: Context, name: string): Promise<string> {
    const dest: string = `${context.filesDir}/${name}`;
    try {
      if (fs.accessSync(dest)) {
        const st = fs.statSync(dest);
        if (st.size > 0) {
          return dest;
        }
      }
    } catch (e) {
      // continue
    }
    const content: Uint8Array = await context.resourceManager.getRawFileContent(`models/${name}`);
    const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content.buffer);
    } finally {
      fs.closeSync(file);
    }
    return dest;
  }

  private async loadLabels(path: string): Promise<void> {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const st = fs.statSync(path);
      const buf = new ArrayBuffer(st.size);
      fs.readSync(file.fd, buf);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      this.labels = JSON.parse(text) as Array<LabelEntry>;
    } finally {
      fs.closeSync(file);
    }
  }

  public async infer(messages: LLMMessage[]): Promise<string> {
    let imageBase64: string = '';
    let question: string = '请描述图中的物品。';
    for (let i = 0; i < messages.length; i++) {
      const m: LLMMessage = messages[i];
      if (m.image_base64 !== undefined && m.image_base64.length > 0) {
        imageBase64 = m.image_base64;
      }
      if (m.role === 'user' && m.content.length > 0) {
        question = m.content;
      }
    }
    if (imageBase64.length === 0) {
      throw new Error('端侧视觉兜底需要图像输入');
    }
    return await this.analyzeImage(imageBase64, question);
  }

  /**
   * 本地看图：MobileNetV2 分类 + Top-K 中文标签，组合成口语化描述。
   */
  public async analyzeImage(imageBase64: string, question: string): Promise<string> {
    if (!this._ready || this.model === null) {
      throw new Error('端侧视觉兜底引擎未就绪');
    }

    const pixelMap: image.PixelMap = await this.decodeBase64ToPixelMap(imageBase64);
    try {
      const inputBuf: ArrayBuffer = await this.preprocess(pixelMap);
      const inputs: mindSporeLite.MSTensor[] = this.model.getInputs();
      if (inputs.length === 0) {
        throw new Error('模型无输入张量');
      }
      inputs[0].setData(inputBuf);
      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(inputs);
      if (outputs.length === 0) {
        throw new Error('模型无输出张量');
      }
      const logits: Float32Array = new Float32Array(outputs[0].getData());
      const top: Array<ClassificationResult> = this.topK(logits);
      if (top.length === 0) {
        throw new Error('分类结果为空');
      }
      const names: string = top.map((r: ClassificationResult): string => r.label).join('、');
      const confidencePct: number = Math.round(top[0].confidence * 100);
      return `本地识别：画面中最可能的物品是${names}（置信度约${confidencePct}%）。` +
        `您问的是“${question}”，离线模式下仅能提供物品类别，联网后可获得更详细的描述。`;
    } finally {
      pixelMap.release();
    }
  }

  private topK(logits: Float32Array): Array<ClassificationResult> {
    const idx: Array<number> = [];
    for (let i = 0; i < logits.length; i++) {
      idx.push(i);
    }
    idx.sort((a: number, b: number): number => logits[b] - logits[a]);
    const results: Array<ClassificationResult> = [];
    for (let k = 0; k < Math.min(TOP_K, idx.length); k++) {
      const id: number = idx[k];
      const label: LabelEntry = this.labels[id] ?? { zh: `类别_${id}`, en: `class_${id}` };
      results.push({ label: label.zh, confidence: this.softmax(logits, id) });
    }
    return results;
  }

  private softmax(logits: Float32Array, target: number): number {
    let max: number = -Infinity;
    for (let i = 0; i < logits.length; i++) {
      if (logits[i] > max) {
        max = logits[i];
      }
    }
    let sum: number = 0;
    for (let i = 0; i < logits.length; i++) {
      sum += Math.exp(logits[i] - max);
    }
    return Math.exp(logits[target] - max) / sum;
  }

  private async preprocess(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    const regionSize: number = INPUT_SIZE * INPUT_SIZE;
    const pixels: ArrayBuffer = new ArrayBuffer(regionSize * 4);
    await pixelMap.readPixelsToBuffer(pixels);
    const raw: Uint8Array = new Uint8Array(pixels);
    const out: Float32Array = new Float32Array(regionSize * 3);
    const mean: Array<number> = [0.485, 0.456, 0.406];
    const std: Array<number> = [0.229, 0.224, 0.225];
    for (let i = 0; i < regionSize; i++) {
      out[i * 3 + 0] = (raw[i * 4 + 0] / 255.0 - mean[0]) / std[0];
      out[i * 3 + 1] = (raw[i * 4 + 1] / 255.0 - mean[1]) / std[1];
      out[i * 3 + 2] = (raw[i * 4 + 2] / 255.0 - mean[2]) / std[2];
    }
    return out.buffer;
  }

  private async decodeBase64ToPixelMap(base64: string): Promise<image.PixelMap> {
    return new Promise<image.PixelMap>((resolve, reject) => {
      try {
        const bytes: Uint8Array = this.base64Helper.decodeSync(base64);
        const source: image.ImageSource = image.createImageSource(bytes.buffer);
        const opts: image.DecodingOptions = {
          sampleSize: 1,
          editable: true,
          desiredSize: { width: INPUT_SIZE, height: INPUT_SIZE }
        };
        source.createPixelMap(opts, (err: BusinessError, pm: image.PixelMap) => {
          if (err) {
            reject(new Error(`解码图像失败: ${err.message}`));
            return;
          }
          resolve(pm);
        });
      } catch (e) {
        reject(e instanceof Error ? e : new Error(JSON.stringify(e)));
      }
    });
  }

  public destroy(): void {
    this.model = null;
    this._ready = false;
    this.labels = [];
    Logger.info(TAG, '端侧视觉兜底引擎已释放');
  }
}
