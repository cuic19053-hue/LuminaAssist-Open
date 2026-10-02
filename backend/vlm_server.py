"""Qwen2-VL-2B-Instruct 本地视觉大模型推理服务。

OpenAI 兼容接口（/v1/chat/completions），供 LuminaAssist 后端 vision_analyze 优先调用；
阿里云百炼作为降级链路。模型权重位于 backend/models/qwen2-vl-2b-instruct/
（离线部署，运行时不访问网络）。

启动方式（backend 目录下）：
    python vlm_server.py
    # 可选环境变量：
    #   VLM_MODEL_DIR   模型目录（默认 ./models/qwen2-vl-2b-instruct）
    #   VLM_PORT        监听端口（默认 8100）
    #   VLM_DEVICE      推理设备（默认 auto：CUDA 优先，回退 CPU）

接口清单：
    GET  /health                健康检查（含模型加载状态）
    POST /v1/chat/completions   OpenAI 兼容对话补全（支持 text + image_url 消息）

说明：
- 仅实现后端所需的消息子集：content 为字符串，或 [{type:text|image_url}] 数组；
  image_url 支持 data:image/...;base64,xxx 数据 URI。
- 非流式响应；usage 为近似估算（视觉 token 数无法精确对账）。
- 全局推理锁：单 GPU 串行处理，避免显存竞争。
"""

import base64
import io
import logging
import os
import threading
import time
import uuid
from typing import Any, Dict, List

import torch
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("lumina.vlm")

MODEL_DIR = os.getenv("VLM_MODEL_DIR", os.path.join(os.path.dirname(__file__), "models", "qwen2-vl-2b-instruct"))
VLM_PORT = int(os.getenv("VLM_PORT", "8100"))
DEVICE = os.getenv("VLM_DEVICE", "auto")
MAX_NEW_TOKENS_CAP = 512

app = FastAPI(title="LuminaAssist Local VLM", version="1.0.0")

_state: Dict[str, Any] = {"model": None, "processor": None, "ready": False, "device": None, "error": ""}
_infer_lock = threading.Lock()


class ChatMessage(BaseModel):
    role: str
    content: Any  # str 或 [{type, text|image_url}] 数组


class ChatCompletionRequest(BaseModel):
    model: str = "qwen2-vl-2b-instruct"
    messages: List[ChatMessage]
    max_tokens: int = 256
    temperature: float = 0.4


def _resolve_device() -> str:
    if DEVICE != "auto":
        return DEVICE
    return "cuda" if torch.cuda.is_available() else "cpu"


def load_model() -> None:
    """加载模型与预处理器（进程启动时调用一次）。"""
    from transformers import AutoProcessor, Qwen2VLForConditionalGeneration

    if not os.path.isdir(MODEL_DIR):
        _state["error"] = f"模型目录不存在: {MODEL_DIR}"
        logger.error(_state["error"])
        return

    device = _resolve_device()
    dtype = torch.bfloat16 if device == "cuda" else torch.float32
    logger.info("开始加载 Qwen2-VL-2B（device=%s, dtype=%s, dir=%s）...", device, dtype, MODEL_DIR)
    t0 = time.time()
    try:
        processor = AutoProcessor.from_pretrained(MODEL_DIR, local_files_only=True, trust_remote_code=True)
        model = Qwen2VLForConditionalGeneration.from_pretrained(
            MODEL_DIR,
            torch_dtype=dtype,
            local_files_only=True,
            trust_remote_code=True,
            low_cpu_mem_usage=True,
        ).to(device)
        model.eval()
        _state.update({"model": model, "processor": processor, "ready": True, "device": device, "error": ""})
        logger.info("模型加载完成，耗时 %.1fs", time.time() - t0)
    except Exception as exc:  # noqa: BLE001
        _state["error"] = f"模型加载失败: {exc}"
        logger.exception(_state["error"])


def _extract_parts(messages: List[ChatMessage]) -> tuple:
    """解析 OpenAI 消息为数组：[(role, text|None, PIL.Image|None), ...]。"""
    parsed: List[tuple] = []
    for msg in messages:
        if isinstance(msg.content, str):
            parsed.append((msg.role, msg.content, None))
            continue
        text_acc: List[str] = []
        image: Image.Image | None = None
        for part in msg.content:
            # Pydantic 将 content 数组元素解析为 dict，需按 dict 访问（兼容对象形式）
            if isinstance(part, dict):
                ptype = part.get("type")
                if ptype == "text":
                    text_acc.append(str(part.get("text", "")))
                elif ptype == "image_url":
                    iu = part.get("image_url")
                    url = iu.get("url", "") if isinstance(iu, dict) else str(iu)
                    if url.startswith("data:"):
                        b64_data = url.split(",", 1)[1] if "," in url else ""
                        image = Image.open(io.BytesIO(base64.b64decode(b64_data))).convert("RGB")
                    else:
                        raise HTTPException(status_code=400, detail="仅支持 base64 data URI 图片")
            else:
                ptype = getattr(part, "type", None)
                if ptype == "text":
                    text_acc.append(str(getattr(part, "text", "")))
        parsed.append((msg.role, " ".join(text_acc).strip(), image))
    return parsed


def _build_inputs(parsed: List[tuple]) -> Dict[str, Any]:
    """构造 Qwen2-VL 处理器输入（chat template + 图像张量）。"""
    processor = _state["processor"]
    conv: List[Dict[str, Any]] = []
    images: List[Image.Image] = []
    for role, text, img in parsed:
        content: List[Dict[str, Any]] = []
        if img is not None:
            content.append({"type": "image"})
            images.append(img)
        if text:
            content.append({"type": "text", "text": text})
        conv.append({"role": role, "content": content})
    prompt = processor.apply_chat_template(conv, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=[prompt], images=images if images else None, return_tensors="pt")
    device = _state["device"]
    return {k: v.to(device) for k, v in inputs.items()}


@app.get("/health")
def health() -> Dict[str, Any]:
    return {
        "status": "ok" if _state["ready"] else "error",
        "model_loaded": _state["ready"],
        "device": _state["device"],
        "error": _state["error"],
        "model_dir": MODEL_DIR,
    }


@app.post("/v1/chat/completions")
def chat_completions(req: ChatCompletionRequest) -> Dict[str, Any]:
    if not _state["ready"]:
        raise HTTPException(status_code=503, detail=_state["error"] or "模型未就绪")

    parsed = _extract_parts(req.messages)
    if all(img is None and not text for _, text, img in parsed):
        raise HTTPException(status_code=400, detail="消息内容为空")

    model = _state["model"]
    max_new = max(16, min(req.max_tokens, MAX_NEW_TOKENS_CAP))
    t0 = time.time()
    try:
        with _infer_lock:
            inputs = _build_inputs(parsed)
            with torch.inference_mode():
                out_ids = model.generate(
                    **inputs,
                    max_new_tokens=max_new,
                    do_sample=req.temperature > 0,
                    temperature=max(req.temperature, 0.01),
                    repetition_penalty=1.05,
                )
        # 仅截取新生成部分
        gen_ids = out_ids[:, inputs["input_ids"].shape[1]:]
        text = _state["processor"].batch_decode(gen_ids, skip_special_tokens=True)[0].strip()
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("推理失败")
        raise HTTPException(status_code=500, detail=f"推理失败: {exc}") from exc

    n_images = sum(1 for _, _, img in parsed if img is not None)
    prompt_tokens = int(inputs["input_ids"].shape[1]) + n_images * 256
    logger.info("推理完成: %.1fs, prompt≈%d tokens, 输出 %d 字符", time.time() - t0, prompt_tokens, len(text))
    return {
        "id": f"chatcmpl-local-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": req.model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": max_new, "total_tokens": prompt_tokens + max_new},
    }


if __name__ == "__main__":
    import uvicorn

    load_model()
    if not _state["ready"]:
        logger.error("模型未加载成功，服务以降级状态启动（/health 将返回 error）")
    uvicorn.run(app, host="0.0.0.0", port=VLM_PORT, log_level="info")
