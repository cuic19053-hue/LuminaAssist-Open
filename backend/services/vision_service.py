"""视觉识别服务。

封装 Qwen-VL 视觉大模型调用与 Prompt 管理。
"""

import logging
from typing import List, Dict, Any

from services.llm_client import LLMClient
from schemas.vision import VisionAnalyzeResponse

logger = logging.getLogger("lumina.backend.vision")


VISION_PROMPT = (
    "你是一位视障辅助助手，请用简短中文描述图片中的关键信息"
    "（如药品名称、说明书、菜单、物体等），不超过 50 字，"
    "直接给出描述，不要加前缀。"
)


class VisionService:
    """视觉识别服务。

    Attributes:
        llm_client: LLM 客户端
        vision_model: 视觉大模型名称
    """

    def __init__(self, llm_client: LLMClient, vision_model: str):
        self.llm_client = llm_client
        self.vision_model = vision_model

    def analyze(self, image_base64: str) -> VisionAnalyzeResponse:
        """视觉分析入口。

        Args:
            image_base64: base64 编码的 JPEG 图像（不带前缀）

        Returns:
            VisionAnalyzeResponse: 包含 tts_message 的响应
        """
        messages: List[Dict[str, Any]] = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": VISION_PROMPT},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}}
                ]
            }
        ]
        content = self.llm_client.chat(
            model=self.vision_model,
            messages=messages,
            temperature=0.4,
            max_tokens=200,
        )
        return VisionAnalyzeResponse(tts_message=content.strip())
