"""视觉识别相关 Pydantic 模型。"""

from pydantic import BaseModel


class VisionAnalyzeRequest(BaseModel):
    """视觉识别请求模型。

    Attributes:
        image_base64: 图片的 base64 编码字符串（不带 data:image/jpeg;base64, 前缀）
    """
    image_base64: str


class VisionAnalyzeResponse(BaseModel):
    """视觉识别响应模型。

    Attributes:
        tts_message: 用于 TTS 播报的中文描述
    """
    tts_message: str
