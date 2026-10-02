import os

# 修改 LocalOCREngine.ets 顶部注释
p1 = r'd:\c4.ai.huawei\LuminaApp\entry\src\main\ets\services\LocalOCREngine.ets'
with open(p1, 'r', encoding='utf-8') as f:
    c = f.read()
old1 = '端侧 OCR 引擎（基于 PaddleOCR-Lite + @ohos.ai.mindSporeLite）。'
new1 = '''【已弃用 2026-07-20】端侧 OCR 引擎骨架（保留作为接口预留）。
 *
 * 弃用说明：放弃端侧 OCR，OCR 场景统一走云端 Qwen-VL。本文件保留作为接口预留与未来重启参考。
 * 同步修订作品介绍：原"端侧 OCR + 视觉大模型"改为"云端 OCR + 端侧图像分类"。
 *
 * 原始设计（保留作为历史参考）：
 * - 基于 PaddleOCR-Lite + @ohos.ai.mindSporeLite'''
c = c.replace(old1, new1)
with open(p1, 'w', encoding='utf-8') as f:
    f.write(c)
print('LocalOCREngine.ets OK')

# 修改 LocalVisionLLMEngine.ets 顶部注释
p2 = r'd:\c4.ai.huawei\LuminaApp\entry\src\main\ets\services\LocalVisionLLMEngine.ets'
with open(p2, 'r', encoding='utf-8') as f:
    c = f.read()
old2 = '端侧视觉大模型引擎（基于 @ohos.ai.mindSporeLite）。'
new2 = '''【已弃用 2026-07-20】端侧视觉大模型引擎骨架（保留作为接口预留）。
 *
 * 弃用说明：API 12 端侧视觉大模型工程化难度过高，暂不投入开发。
 * 所有视觉大模型能力统一走云端 Qwen-VL（通过 LLMClient.chat() 调用）。
 * 端侧视觉能力由 LocalImageClassifier（MobileNetV2 图像分类）承担，已落地可用。
 * 本文件保留作为接口预留与未来 HarmonyOS 6+ aiEngine 普及后重启时的参考骨架。
 *
 * 原始设计（保留作为历史参考）：
 * - 基于 @ohos.ai.mindSporeLite 加载 .ms 格式的端侧视觉大模型'''
c = c.replace(old2, new2)
with open(p2, 'w', encoding='utf-8') as f:
    f.write(c)
print('LocalVisionLLMEngine.ets OK')
