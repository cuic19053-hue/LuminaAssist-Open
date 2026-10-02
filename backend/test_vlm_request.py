"""vlm_server 端到端测试：发送测试图片验证视觉推理链路（部署验证工具）。"""
import base64
import json
import time

import requests

with open("test_image.png", "rb") as f:
    b64 = base64.b64encode(f.read()).decode()

payload = {
    "model": "qwen2-vl-2b-instruct",
    "messages": [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "用一句简短中文描述这张图片"},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
            ],
        }
    ],
    "max_tokens": 100,
    "temperature": 0.2,
}

t0 = time.time()
resp = requests.post("http://127.0.0.1:8100/v1/chat/completions", json=payload, timeout=120)
elapsed = time.time() - t0
print(f"HTTP {resp.status_code}, 耗时 {elapsed:.1f}s")
data = resp.json()
print("描述:", data["choices"][0]["message"]["content"])
assert resp.status_code == 200 and data["choices"][0]["message"]["content"], "测试失败"
print("PASS")
