# 光语助手 端侧 Agent 架构

> OpenHarmony 5.0 + ArkUI Stage 模型 + 纯端侧内嵌 Agent + 端云双态视觉大模型

---

## 一、设计目标

1. **零后端依赖**：不再需要任何自建 Python / Node 后端；
2. **毫秒级响应**：高频意图（OCR、紧急）走规则路径 + 端侧推理，避免 LLM 网络延迟；
3. **端云双态**：
   - **端侧优先**：端侧图像分类（MobileNetV2）+ 端侧 OCR（PaddleOCR-Lite）+ 端侧视觉大模型（MiniCPM-V / Qwen2-VL）；
   - **云端兜底**：端侧未就绪 / 推理失败时自动回退云端 Qwen-VL；
   - **离线可用**：兑现作品介绍"端侧 OCR + 视觉大模型 + 无需云端"承诺。

---

## 二、模块划分

```
LuminaApp/
├── AppScope/                       # 应用级配置
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/       # Ability 入口
│       │   │   └── EntryAbility.ets # 主入口（注入端侧引擎 + 云端配置）
│       │   ├── pages/              # ArkUI 页面
│       │   ├── agent/              # 端侧智能体（核心）
│       │   │   ├── Agent.ets       # 主控（编排+执行，含 image_classify 分发）
│       │   │   ├── IntentRouter.ets # 意图路由（规则+LLM）
│       │   │   ├── TaskPlanner.ets  # 任务编排（object_recognition → image_classify）
│       │   │   └── types.ets        # 类型定义（含 image_classify ActionType）
│       │   ├── services/           # 端侧服务（端云双态）
│       │   │   ├── LLMClient.ets              # LLM 客户端（端云双态路由 + LocalEngine 接口）
│       │   │   ├── LocalImageClassifier.ets   # 端侧图像分类（MobileNetV2 + MindSpore Lite，真实可用）
│       │   │   ├── LocalOCREngine.ets          # 端侧 OCR 引擎（PaddleOCR-Lite，骨架）
│       │   │   ├── LocalVisionLLMEngine.ets    # 端侧视觉大模型引擎（骨架）
│       │   │   ├── SpeechService.ets           # ASR + TTS
│       │   │   └── VisionService.ets           # 相机 + OCR + 分类 + 检测 + 振动（端侧优先 + 云端兜底）
│       │   ├── components/         # 无障碍 UI 组件
│       │   │   ├── BigButton.ets
│       │   │   ├── StatusBanner.ets
│       │   │   └── ConversationBubble.ets
│       │   ├── viewmodel/          # 视图模型（待扩展）
│       │   └── utils/              # 工具
│       │       ├── AccessibilityUtils.ets
│       │       ├── Logger.ets
│       │       └── PermissionUtil.ets
│       ├── module.json5            # 模块清单（权限、Ability）
│       └── resources/
│           └── rawfile/
│               └── models/         # 端侧模型资产（已落地 mobilenetv2.ms + imagenet_labels.json）
│                   ├── mobilenetv2.ms          # MobileNetV2 图像分类模型（~11MB，已下载）
│                   ├── imagenet_labels.json    # ImageNet 1001 类中英标签（已生成）
│                   ├── ch_PP-OCRv4_det_slim.ms # PaddleOCR 检测模型（待下载）
│                   ├── ch_PP-OCRv4_rec_slim.ms # PaddleOCR 识别模型（待下载）
│                   ├── ppocr_keys_v1.txt       # PaddleOCR 词表（待下载）
│                   └── minicpm-v-2b-int8.ms    # MiniCPM-V 视觉大模型（待 HarmonyOS 6+ 接入）
└── docs/                           # 工程文档
```

---

## 三、端云双态数据流

```
[UI 按钮 / 语音触发]
        │
        ▼
   ┌──────────┐
   │  Agent   │  invoke(text, image)
   └────┬─────┘
        │ 1. 意图识别
        ▼
   ┌──────────────┐
   │ IntentRouter │  规则匹配 → LLM 兜底
   └────┬─────────┘
        │ 2. 任务编排
        ▼
   ┌──────────────┐
   │ TaskPlanner  │  产出 SubTask[]（object_recognition → image_classify）
   └────┬─────────┘
        │ 3. 顺序执行
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ speak / capture_image / ocr / image_classify / llm_query │
   │ object_detect / face_detect / medicine_recognize / vibrate│
   └────┬─────────────────────────────────────────────────────┘
        │
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │              端云双态路由（LLMClient + VisionService）          │
   │                                                              │
   │  ┌──────────────────────┐  ┌─────────────────────┐           │
   │  │ LocalImageClassifier │  │ LocalOCREngine      │           │
   │  │ (MobileNetV2 + MSLite│  │ (PaddleOCR-Lite)    │           │
   │  │  真实可用，NPU 优先)  │  │  端侧 OCR 优先      │           │
   │  └──────────┬───────────┘  └──────────┬──────────┘           │
   │             │ 失败回退                  │ 失败回退              │
   │             ▼                           ▼                      │
   │  ┌──────────────────────────────────────────────────────┐    │
   │  │  LocalVisionLLMEngine (骨架) → LLMClient.cloudChat() │    │
   │  │  → 阿里云百炼 Qwen-VL（云端兜底）                      │    │
   │  └──────────────────────────────────────────────────────┘    │
   └────┬─────────────────────────────────────────────────────────┘
        │ 4. 汇总
        ▼
   AgentResponse { intent, tasks, tts_message }
        │
        ▼
   UI 更新 + TTS 播报
```

---

## 四、端侧化实现路径（P0-3 落地）

### 4.1 LocalEngine 接口（LLMClient.ets 内）

```typescript
export interface LocalEngine {
  readonly ready: boolean;
  readonly kind: string;
  infer(messages: LLMMessage[]): Promise<string>;
}
```

### 4.2 端侧引擎实现

| 引擎 | 文件 | 模型 | 体积 | 状态 | 兑现承诺 |
|---|---|---|---|---|---|
| **LocalImageClassifier** | services/LocalImageClassifier.ets | **MobileNetV2（.ms）** | ~11MB | **真实可用**（已下载，待真机验证） | **端侧视觉识别（电器面板/物体分类）** |
| LocalOCREngine | services/LocalOCREngine.ets | PaddleOCR-Lite ch_PP-OCRv4 | ~15MB | 骨架（待模型转换） | 端侧 OCR |
| LocalVisionLLMEngine | services/LocalVisionLLMEngine.ets | MiniCPM-V-2B INT8 / Qwen2-VL-2B | ~1.5GB | 骨架（待 HarmonyOS 6+ aiEngine） | 视觉大模型 |

**P0-3 关键里程碑**：LocalImageClassifier 已使用真实 `@ohos.ai.mindSporeLite` API 实现：
- `mindSporeLite.loadModelFromFile()` 加载 .ms 模型；
- `mindSporeLite.Context` + `NNRTDevice` / `CpuDevice` 后端选择；
- `Model.predict()` 执行推理；
- `MSTensor.setData()` / `getData()` 输入输出张量操作；
- ImageNet 1001 类中文标签解析（已生成 `imagenet_labels.json`）。

### 4.3 路由策略

| 调用点 | 端侧优先 | 云端兜底 |
|---|---|---|
| **VisionService.classifyImage()** | **LocalImageClassifier.classify()（MobileNetV2）** | **LLMClient.cloudChat()（Qwen-VL）** |
| VisionService.ocr() | LocalOCREngine.recognize() | LLMClient.cloudChat()（Qwen-VL） |
| VisionService.objectDetect() | LLMClient.chat() 自动路由 | 同上 |
| VisionService.faceDetect() | LLMClient.chat() 自动路由 | 同上 |
| VisionService.recognizeMedicine() | LLMClient.chat() 自动路由 | 同上 |
| Agent.llmQuery(scene/emergency/general) | LLMClient.chat() 自动路由 | 同上 |
| IntentRouter.route() | LLMClient.chat() 自动路由 | 同上 |
| TaskPlanner.plan() | LLMClient.chat() 自动路由 | 同上 |

**意图路由更新**：
- 关键词「这是什么」「前面是什么」「那个东西」→ `object_recognition` 意图
- `object_recognition` → `planObjectRecognition()` → `image_classify` action
- `image_classify` → `VisionService.classifyImage()` → 端侧 MobileNetV2 优先 + 云端 Qwen-VL 兜底

### 4.4 模型资产分发

- 端侧模型放入 `entry/src/main/resources/rawfile/models/`；
- 首次启动时由 `LocalImageClassifier.copyAssetToFilesDir()` 拷贝到 `filesDir`；
- **已落地**：`mobilenetv2.ms`（~11MB）+ `imagenet_labels.json`（~30KB）已下载生成；
- 视觉大模型（>1GB）建议改为应用市场首启下载，避免 HAP 超体积上限；
- 模型下载脚本：`scripts/dl_model.ps1`（ASCII-only，避免编码问题）；
- 标签生成脚本：`scripts/gen_labels.js`（Node.js，UTF-8 安全）。

---

## 五、与原架构的差异

| 维度 | 原方案（端云协同） | 新方案（端侧优先 + 云端兜底） |
| --- | --- | --- |
| 智能体部署 | Python FastAPI 后端 | 端侧 ArkTS 内嵌 |
| 图像分类 | 云端 Qwen-VL | **端侧 MobileNetV2 优先，云端兜底** |
| OCR 实现 | 云端 Qwen-VL | 端侧 PaddleOCR-Lite 优先，云端兜底 |
| 视觉大模型 | 云端 Qwen-VL | 端侧 MiniCPM-V / Qwen2-VL 优先，云端兜底 |
| 部署成本 | 需独立部署后端服务 | 零后端 |
| 网络依赖 | 每次对话都需联网 | 端侧就绪时完全离线可用 |
| 响应延迟 | 含后端处理 + 网络 RTT | 端侧毫秒级，云端秒级 |
| 商业化路径 | SaaS 化 | 离线 + 云端双模，按需付费 |

---

## 六、关键设计决策

1. **规则 + LLM 双层意图路由**：70%+ 高频意图走规则路径（O(1)），减少 LLM 调用与成本。
2. **LocalEngine 接口注入**：端侧推理引擎通过 `setLocalEngine()` / `setLocalOCREngine()` / `setLocalImageClassifier()` 注入，对调用方零侵入，符合开闭原则。
3. **骨架两态降级**：每个端侧引擎有 `ready=false`（骨架）和 `ready=true`（完整）两态，未就绪时自动走云端兜底，符合"可降级"铁律。
4. **TTS 兜底**：所有错误路径都通过 `tts_message` 兜底，视障用户永远有"语音反馈"（VUI 铁律 3）。
5. **多轮上下文**：`session_id` 维护会话历史，最多 20 轮。
6. **振动降级**：TTS 引擎不可用时短振动反馈，避免完全无响应。
7. **NPU 优先**：端侧推理通过 NNRT 优先使用 NPU，CPU 兜底（模拟器不支持 NPU，必须真机测试）。
8. **MobileNetV2 选型**：选择 MobileNetV2 而非更大模型，平衡精度与端侧性能（224x224 输入，~11MB 体积，NPU 加速下毫秒级响应）。

---

## 七、待办与风险

### 7.1 端侧引擎完整化（按优先级）

1. **LocalImageClassifier 真机验证**（P0，本周内）
   - 已完成：代码实现 + 模型下载 + 标签生成 + 路由接入；
   - 待验证：nova 14 真机 NPU 推理延迟、Top-3 准确率、电器面板识别效果；
   - 阻塞项：build-profile.json5 签名问题需先解决。

2. **LocalOCREngine.recognize() 完整实现**（P1，1-2 周）
   - 模型转换：PaddleOCR-Lite → ONNX → .ms
   - DBNet 后处理 + CTC 解码
   - 透视变换 + 框排序

3. **LocalVisionLLMEngine.infer() 完整实现**（P2，4-8 周）
   - 模型选型与转换：MiniCPM-V-2B / Qwen2-VL-2B → .ms
   - BPE tokenizer 实现
   - 自回归采样循环 + KV Cache
   - 图像预处理（resize / normalize）
   - 或等待 HarmonyOS 6+ @kit.AIKit.aiEngine 系统级端侧 LLM

### 7.2 已知风险

| 风险 | 说明 | 应对 |
|---|---|---|
| NPU 算子不全 | Qwen-VL 部分算子可能不在 NNRT 支持清单 | converter 工具验证，必要时 CPU 兜底 |
| 内存峰值 OOM | 0.5B+ 模型推理峰值 800MB+ | EntryAbility 检测 systemMemorySize，低端机禁用端侧 |
| HAP 体积超限 | 视觉大模型 1-2GB | 模型走 rawfile + 首启下载，禁止内嵌 |
| 真机测试必须 | 模拟器不支持 NPU | 必须在 nova 14 等真机验证 |
| 签名配置未解 | build-profile.json5 签名问题阻塞真机安装 | 优先解决签名问题，端侧化才能真机验证 |
| ImageNet 类别局限 | MobileNetV2 1001 类未覆盖药品/菜单等细粒度场景 | 药品走 medicine_recognize（云端 LLM），菜单走 ocr（端侧 OCR 待落地） |

---

## 八、商业化路径

- **C 端订阅**：端侧图像分类 + OCR 免费使用，端侧视觉大模型 + 多轮对话走订阅；
- **B 端 SDK**：端侧图像分类 + OCR + 物体识别作为独立 SDK 售卖，规避云端 token 成本；
- **政府采购**：端侧化满足"数据不出设备"硬性要求；
- **老人机预装**：端侧化满足"无网可用"硬性要求。

---

## 九、P0-3 落地证据（2026-07-20）

| 证据项 | 文件 / 资产 | 状态 |
|---|---|---|
| 端侧推理代码 | services/LocalImageClassifier.ets | 完整实现 mindSporeLite API |
| 端云双态路由 | services/VisionService.ets::classifyImage() | 端侧优先 + 云端兜底 |
| 任务分发 | agent/Agent.ets::executeOne(image_classify) | 已接入 |
| 意图编排 | agent/TaskPlanner.ets::planObjectRecognition() | 已路由到 image_classify |
| 类型定义 | agent/types.ets::ActionType | 已添加 'image_classify' |
| 引擎注入 | entryability/EntryAbility.ets::initLocalEngines() | 已注入 LocalImageClassifier |
| 模型资产 | rawfile/models/mobilenetv2.ms | 已下载（~11MB） |
| 标签资产 | rawfile/models/imagenet_labels.json | 已生成（1000 项中英双语） |
| 下载脚本 | scripts/dl_model.ps1 | ASCII-only，可重复执行 |
| 标签脚本 | scripts/gen_labels.js | Node.js UTF-8 安全 |
| 架构文档 | docs/architecture.md | 本文件，已反映真实落地 |