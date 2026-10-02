/**
 * @file LocalImageClassifier.ets
 * @module services
 * @description 端侧图像分类（MindSpore Lite + MobileNetV2）。
 * 云端优先架构下由 VisionService.classifyImage 端侧优先调用。
 */

import mindSporeLite from '@ohos.ai.mindSporeLite';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { Logger } from '../utils/Logger';

const TAG: string = 'LocalImageClassifier';
const MODEL_NAME: string = 'mobilenetv2.ms';
const LABELS_NAME: string = 'imagenet_labels.json';
const INPUT_SIZE: number = 224;
const TOP_K: number = 3;

interface LabelEntry {
  zh: string;
  en: string;
}

export interface ClassificationResult {
  label: string;
  confidence: number;
}

export class LocalImageClassifier {
  private static instance: LocalImageClassifier | null = null;
  private model: mindSporeLite.Model | null = null;
  private labels: Array<LabelEntry> = [];
  private _ready: boolean = false;
  private base64Helper: util.Base64Helper = new util.Base64Helper();

  public get ready(): boolean {
    return this._ready;
  }

  private constructor() {}

  public static getInstance(): LocalImageClassifier {
    if (LocalImageClassifier.instance === null) {
      LocalImageClassifier.instance = new LocalImageClassifier();
    }
    return LocalImageClassifier.instance;
  }

  public async init(context: Context): Promise<void> {
    try {
      const modelPath: string = await this.ensureAsset(context, MODEL_NAME);
      const labelsPath: string = await this.ensureAsset(context, LABELS_NAME);
      await this.loadLabels(labelsPath);
      const msContext: mindSporeLite.Context = {};
      msContext.target = ['cpu'];
      msContext.cpu = { threadNum: 4, threadAffinityMode: 0, precisionMode: 'enforce_fp32' };
      this.model = await mindSporeLite.loadModelFromFile(modelPath, msContext);
      this._ready = true;
      Logger.info(TAG, `端侧图像分类引擎已就绪，标签数=${this.labels.length}`);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `端侧图像分类引擎初始化失败，将走云端兜底: ${msg}`);
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
      // continue copy
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

  public async classify(imageBase64: string): Promise<Array<ClassificationResult>> {
    if (!this._ready || this.model === null) {
      throw new Error('端侧图像分类引擎未就绪');
    }
    if (!imageBase64 || imageBase64.length === 0) {
      throw new Error('图像数据为空，无法分类。');
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
      return this.topK(logits);
    } finally {
      pixelMap.release();
    }
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

  public destroy(): void {
    this.model = null;
    this._ready = false;
    this.labels = [];
    Logger.info(TAG, '端侧图像分类引擎已释放');
  }
}
