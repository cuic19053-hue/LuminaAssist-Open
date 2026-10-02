/**
 * @file LocalSLMEngine.ets
 * @module services
 * @description 端侧小语言模型引擎（Qwen2-0.5B-Instruct，MindSpore Lite）。
 *
 * 职责：断网环境下负责复杂的意图理解与任务编排，替换原有的纯规则匹配。
 *
 * 管线（真实实现）：
 *   messages -> ChatML 模板 -> BPE tokenize（utils/QwenTokenizer）
 *   -> 自适应输入绑定（token ids / attention mask / position ids / KV 零填充）
 *   -> 贪心迭代解码（argmax，遇 <|im_end|> 停止）-> decode -> JSON 提取
 *
 * 模型资产（由 scripts/get_model_weights.ps1 + convert_models.sh slm 生成）：
 *   rawfile/models/qwen2_1_5b_int4.ms  INT4 极速推理模型（~1GB）
 *   rawfile/models/qwen_vocab.json     BPE 词表
 *   rawfile/models/qwen_merges.txt     BPE 合并规则
 *
 * 模型 I/O 规格（与 ONNX 导出对齐，converter FP16 不改变布局）：
 *   输入: input_ids [b,1,1,seq] / attention_mask [b,1,1,seq+kv]
 *         position_ids [b,1,1,seq] / past_key_values [b,96,kv,64]
 *   输出: logits [b,1,151936,seq]（词表轴=151936，按此定位） / out_key_values
 *
 * 兼容性说明：
 *   转换产物的输入/输出张量布局存在两种已知形态（单输入文本流 / 多输入 token 流），
 *   init 时会自动探测 getInputs() 布局并选择绑定策略，失败时优雅降级
 *   （ready=false，由 LLMClient 回退规则引擎 OfflinePlanner）。
 */

import mindSporeLite from '@ohos.ai.mindSporeLite';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { Logger } from '../utils/Logger';
import { AgentPlanResponse, LLMMessage } from '../agent/types';
import { LocalEngine } from './LLMClient';
import { QwenTokenizer } from '../utils/QwenTokenizer';

const TAG: string = 'LocalSLMEngine';
const MODEL_NAME: string = 'qwen2_1_5b_int4.ms';
const VOCAB_NAME: string = 'qwen_vocab.json';
const MERGES_NAME: string = 'qwen_merges.txt';
/** Qwen2 特殊 token id */
const IM_END_ID: number = 151645;
const EOS_ID: number = 151643;
/** Qwen2-1.5B 词表规模（用于定位 logits 输出轴） */
const QWEN2_VOCAB_SIZE: number = 151936;
/** 单次生成上限与上下文窗口 */
const MAX_NEW_TOKENS: number = 128;
const MAX_CONTEXT_TOKENS: number = 1024;

/** 模型输入张量绑定信息 */
interface InputBinding {
  name: string;
  dims: Array<number>;
  dtype: number;
  role: string;
}

export class LocalSLMEngine implements LocalEngine {
  private static instance: LocalSLMEngine | null = null;
  private model: mindSporeLite.Model | null = null;
  private tokenizer: QwenTokenizer = new QwenTokenizer();
  private bindings: Array<InputBinding> = [];
  /** 绑定模式：token 流（多输入）或 文本流（单输入，历史兼容） */
  private tokenStreamMode: boolean = false;
  private logitsOutputIdx: number = 0;
  private logitsVocabDim: number = QWEN2_VOCAB_SIZE;
  /** 是否已完成 logits 输出轴定位（首次推理后） */
  private logitsLocated: boolean = false;
  private _ready: boolean = false;

  public get ready(): boolean {
    return this._ready;
  }

  public get kind(): string {
    return 'local_slm';
  }

  public get tokenizerReady(): boolean {
    return this.tokenizer.ready;
  }

  private constructor() {}

  public static getInstance(): LocalSLMEngine {
    if (LocalSLMEngine.instance === null) {
      LocalSLMEngine.instance = new LocalSLMEngine();
    }
    return LocalSLMEngine.instance;
  }

  public async init(context: Context): Promise<void> {
    try {
      // 1. 分词器（先于模型：失败即整体降级，避免产生无效推理）
      const vocabText: string = await this.readRawText(context, VOCAB_NAME);
      const mergesText: string = await this.readRawText(context, MERGES_NAME);
      this.tokenizer.loadFromText(vocabText, mergesText);
      Logger.info(TAG, `Qwen 分词器就绪（词表 ${this.tokenizer.vocabSize}）`);

      // 2. 模型
      const modelPath: string = await this.ensureAsset(context, MODEL_NAME);
      const msContext: mindSporeLite.Context = {};
      msContext.target = ['nnrt', 'cpu']; // 优先调用 NPU 硬件加速
      msContext.cpu = { threadNum: 4, threadAffinityMode: 0, precisionMode: 'enforce_fp32' };
      this.model = await mindSporeLite.loadModelFromFile(modelPath, msContext);

      // 3. 自适应输入绑定与输出定位
      this.detectIOBinding();

      this._ready = true;
      Logger.info(TAG, `端侧小语言模型引擎已就绪 (${MODEL_NAME})，绑定模式=${this.tokenStreamMode ? 'token_stream' : 'text_blob'}`);
    } catch (error) {
      const msg: string = error instanceof Error ? error.message : JSON.stringify(error);
      Logger.warn(TAG, `端侧 SLM 初始化失败，断网时将回退到规则匹配: ${msg}`);
      this._ready = false;
      this.model = null;
    }
  }

  /** 探测模型输入布局，生成绑定表 */
  private detectIOBinding(): void {
    const model = this.model;
    if (model === null) {
      return;
    }
    const inputs: mindSporeLite.MSTensor[] = model.getInputs();
    this.bindings = [];
    for (const t of inputs) {
      const name: string = t.name;
      const dims: Array<number> = t.shape;
      const lower: string = name.toLowerCase();
      let role: string = 'unknown';
      if (lower.includes('cache') || lower.includes('past')) {
        role = 'kv_cache';
      } else if (lower.includes('mask')) {
        role = 'attention_mask';
      } else if (lower.includes('position')) {
        role = 'position_ids';
      } else if (lower.includes('id') || lower.includes('token') || lower.includes('input')) {
        role = 'token_ids';
      }
      this.bindings.push({ name: name, dims: dims, dtype: t.dtype, role: role });
      Logger.info(TAG, `输入张量: ${name} shape=[${dims.join(',')}] role=${role}`);
    }

    const tokenInput: InputBinding | undefined =
      this.bindings.find((b: InputBinding): boolean => b.role === 'token_ids');
    this.tokenStreamMode = this.bindings.length > 0 && tokenInput !== undefined;
  }

  /**
   * 文本生成（贪心解码）。
   * @param prompt 已套用 ChatML 模板的完整 prompt
   * @returns 模型生成文本
   */
  public async generate(prompt: string): Promise<string> {
    const model = this.model;
    if (!this._ready || model === null) {
      throw new Error('端侧小语言模型引擎未就绪');
    }
    if (!this.tokenizer.ready) {
      throw new Error('Qwen 分词器未就绪');
    }

    const promptIds: Array<number> = this.tokenizer.encode(prompt);
    const generated: Array<number> = [];

    for (let step = 0; step < MAX_NEW_TOKENS; step++) {
      const contextIds: Array<number> = promptIds.concat(generated);
      if (contextIds.length > MAX_CONTEXT_TOKENS) {
        contextIds.splice(0, contextIds.length - MAX_CONTEXT_TOKENS);
      }
      const logits: Float32Array = await this.predictStep(contextIds);
      const nextId: number = argmaxLastFrame(logits, this.logitsVocabDim);
      if (nextId === IM_END_ID || nextId === EOS_ID) {
        break;
      }
      generated.push(nextId);
    }

    if (generated.length === 0) {
      throw new Error('端侧模型未生成任何 token');
    }
    return this.tokenizer.decode(generated);
  }

  /**
   * 单步前向：按绑定表填充输入张量，返回 logits。
   */
  private async predictStep(contextIds: Array<number>): Promise<Float32Array> {
    const model = this.model;
    if (model === null) {
      throw new Error('模型未加载');
    }
    const inputs: mindSporeLite.MSTensor[] = model.getInputs();
    const seqLen: number = contextIds.length;

    for (let i = 0; i < inputs.length && i < this.bindings.length; i++) {
      const binding: InputBinding = this.bindings[i];
      const tensor: mindSporeLite.MSTensor = inputs[i];
      if (binding.role === 'token_ids' || (!this.tokenStreamMode && i === 0)) {
        // token ids 以 float32 喂入（与 Tlntin 导出管线 input_dtype=float32 对齐）
        const f32: Float32Array = new Float32Array(seqLen);
        for (let s = 0; s < seqLen; s++) {
          f32[s] = contextIds[s];
        }
        tensor.setData(f32.buffer as ArrayBuffer);
      } else if (binding.role === 'attention_mask') {
        const ones: Float32Array = new Float32Array(tensorSize(binding.dims));
        ones.fill(1);
        tensor.setData(ones.buffer as ArrayBuffer);
      } else if (binding.role === 'position_ids') {
        // 静态形状下位置固定为 [0..seq)
        const pos: Float32Array = new Float32Array(tensorSize(binding.dims));
        for (let s = 0; s < pos.length; s++) {
          pos[s] = s % Math.max(1, seqLen);
        }
        tensor.setData(pos.buffer as ArrayBuffer);
      } else {
        // kv_cache / unknown：零填充
        const zeros: Float32Array = new Float32Array(tensorSize(binding.dims));
        tensor.setData(zeros.buffer as ArrayBuffer);
      }
    }

    const outputs: mindSporeLite.MSTensor[] = await model.predict(inputs);
    if (outputs.length === 0) {
      throw new Error('模型无输出');
    }
    // 首次推理时定位 logits 输出：形状含词表规模（151936）的输出轴
    if (!this.logitsLocated) {
      const idx: number = outputs.findIndex((t: mindSporeLite.MSTensor): boolean => {
        return t.shape.indexOf(QWEN2_VOCAB_SIZE) >= 0;
      });
      this.logitsOutputIdx = idx >= 0 ? idx : 0;
      if (idx < 0) {
        Logger.warn(TAG, `未找到词表规模输出轴，默认使用 outputs[0] shape=[${outputs[0].shape.join(',')}]`);
      } else {
        Logger.info(TAG, `logits 输出定位: index=${idx} shape=[${outputs[idx].shape.join(',')}]`);
      }
      this.logitsLocated = true;
    }
    return new Float32Array(outputs[this.logitsOutputIdx].getData());
  }

  public async infer(messages: LLMMessage[]): Promise<string> {
    // ChatML 模板拼接：取第一条 system，其余 user/assistant 按序拼接为 user 段
    let system: string = '你是光语助手，一个离线语音助手。';
    let userParts: string = '';
    for (let i = 0; i < messages.length; i++) {
      const m: LLMMessage = messages[i];
      if (m.role === 'system') {
        system = m.content;
      } else {
        userParts += m.content + '\n';
      }
    }
    const prompt: string = this.tokenizer.applyChatTemplate(system, userParts.trim());
    return await this.generate(prompt);
  }

  public async planIntent(text: string): Promise<AgentPlanResponse> {
    const systemPrompt: string =
      '你是光语助手的任务规划器。根据用户指令，输出严格的 JSON。\n' +
      '格式：{"tasks":[{"action":"...","target":"...","content":"..."}],"tts_message":"..."}\n' +
      'action 可选：read_text / image_classify / medicine_recognition / send_sms / call_ride / emergency_call / read_screen\n';

    const prompt: string = this.tokenizer.applyChatTemplate(systemPrompt, text);
    const rawResponse: string = await this.generate(prompt);
    Logger.info(TAG, `端侧 SLM 规划结果: ${rawResponse}`);

    try {
      // 提取 json
      const jsonStart: number = rawResponse.indexOf('{');
      const jsonEnd: number = rawResponse.lastIndexOf('}');
      if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
        const jsonStr: string = rawResponse.substring(jsonStart, jsonEnd + 1);
        return JSON.parse(jsonStr) as AgentPlanResponse;
      }
    } catch (e) {
      Logger.warn(TAG, `解析端侧 SLM JSON 失败: ${e}`);
    }
    throw new Error('端侧 SLM 无法生成有效的任务结构');
  }

  private async readRawText(context: Context, name: string): Promise<string> {
    // 优先沙箱（ensureAsset 拷贝后），失败回退 rawfile 直读
    const dest: string = `${context.filesDir}/${name}`;
    try {
      if (fs.accessSync(dest)) {
        const st = fs.statSync(dest);
        if (st.size > 0) {
          const file = fs.openSync(dest, fs.OpenMode.READ_ONLY);
          try {
            const buf = new ArrayBuffer(st.size);
            fs.readSync(file.fd, buf);
            return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
          } finally {
            fs.closeSync(file);
          }
        }
      }
    } catch (e) {}
    const content: Uint8Array = await context.resourceManager.getRawFileContent(`models/${name}`);
    return util.TextDecoder.create('utf-8').decodeToString(content);
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
    } catch (e) {}

    const content: Uint8Array = await context.resourceManager.getRawFileContent(`models/${name}`);
    const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
    return dest;
  }

  public destroy(): void {
    this.model = null;
    this._ready = false;
    this.bindings = [];
    this.logitsLocated = false;
    Logger.info(TAG, '端侧 SLM 引擎已释放');
  }
}

/** 张量元素总数 */
function tensorSize(dims: Array<number>): number {
  let n: number = 1;
  for (const d of dims) {
    n *= Math.max(1, d);
  }
  return n;
}

/** 取最后一帧 logits 的 argmax（logits 长度 = seq * vocab，取末帧） */
function argmaxLastFrame(logits: Float32Array, vocabDim: number): number {
  const start: number = Math.max(0, logits.length - vocabDim);
  let best: number = start;
  for (let i = start + 1; i < logits.length; i++) {
    if (logits[i] > logits[best]) {
      best = i;
    }
  }
  return best - start;
}
