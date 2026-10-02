# 端侧模型资产

本目录为「云端优先 → 端侧本地模型 → 规则兜底」三级策略的模型存放点。

## 当前模型集（三模型方案，2026-09-01 交付）

| 文件 | 用途 | 加载代码 | 状态 |
|------|------|----------|------|
| `qwen2_1_5b_int4.ms` (~1GB) | 指令意图规划（断网复杂指令理解） | `LocalSLMEngine` | ✅ 已升级至 1.5B INT4（需自行通过 converter_lite 转换） |
| `paddle_ocr_det_fp16.ms` (1.2MB) / `paddle_ocr_rec_fp16.ms` (5.3MB) | 离线纯文本读取（检测 + 识别） | `LocalOCREngine` | ✅ 已交付（FP16，benchmark 通过） |
| `ppocr_keys_v1.txt` | CTC 解码字符表（6623 类 + blank） | `LocalOCREngine` | ✅ 已入库 |
| `qwen_vocab.json` / `qwen_merges.txt` | Qwen2 字节级 BPE 分词器 | `QwenTokenizer` | ✅ 已入库 |
| `mobilenetv2.ms` | 图像分类 + 视觉兜底 | `LocalImageClassifier` / `LocalVLMEngine` | 脚本可下载 |
| `imagenet_labels.json` | ImageNet 中文标签 | 同上 | 已入库 |

> **历史命名说明**：早期使用过 0.5B 的 FP16 版本。目前为了榨干 12GB 运存设备的算力，已全线升级至 1.5B 的 INT4 量化版，需自行准备并命名为 `qwen2_1_5b_int4.ms`。

## 获取方式

三个模型在 ModelScope / MindSpore 社区**均无现成 `.ms` 文件**，需自行转换：

```powershell
# 第 1 步（Windows）：下载原始权重到 build/model_workspace/
powershell -ExecutionPolicy Bypass -File LuminaApp/scripts/get_model_weights.ps1

# 第 2 步（WSL）：转换并自动放入本目录
#   仅提供 Linux 版 converter_lite，因此转换在 WSL 中执行
wsl bash scripts/convert_models.sh slm_1_5b_int4  # 转换 1.5B 模型为 INT4

# 第 0 步（任何时候）：下载 mobilenetv2.ms 视觉兜底模型
powershell -ExecutionPolicy Bypass -File LuminaApp/scripts/setup_local_models.ps1
```

转换依赖与版本约束：

- MindSpore Lite converter **2.1.0**（鸿蒙端侧运行时兼容版本，仅 Linux 包）
- Qwen 管线 python 环境需 **python3.9/3.10**（mindspore_lite 2.1.1 wheel 提供 cp39/cp310）
- Qwen2-VL-2B 视觉模型暂缓：无公开的 VL → MindSpore Lite 转换成功案例，
  视觉理解短期由 `mobilenetv2.ms` 兜底，VLM 作为长期攻关项

## 集成约束（模型转换完成后需代码适配）

1. **LocalOCREngine**：需改造为加载 `det` + `rec` 两个模型，
   实现 DB 后处理（检测框）与 CRNN CTC 解码（识别文本），当前推理输出为模拟文案。
2. **LocalSLMEngine**：当前将 prompt 按 UTF-8 原文字节直接送入模型输入，
   转换后的 Qwen2 模型需要 **BPE tokenizer**（`tokenizer.json` 已由下载脚本获取）
   以及多输入（token ids / attention mask / 位置）迭代解码循环。
3. **打包体积**：`qwen2_0_5b_int4.ms` 约数百 MB，超过约 100MB 的模型建议
   不随 HAP 内置（`rawfile`），改为首启后经网络下载到应用沙箱
   （`ensureAsset` 已支持沙箱路径优先，可复用该机制扩展）。

## 旧策略说明（历史）

`qwen2-1.5b-instruct-int8.ms`、`minicpm-v-2b-int8.ms` 等旧文件已废弃，
`setup_local_models.ps1` 会自动清理残留。文本规划在 SLM 未就绪时由
`OfflinePlanner` + `LocalLLMEngine`（规则引擎）兜底，不依赖权重。
