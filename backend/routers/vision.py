"""视觉识别路由。"""

import logging
from fastapi import APIRouter, HTTPException

from schemas.vision import VisionAnalyzeRequest, VisionAnalyzeResponse
from services.vision_service import VisionService

logger = logging.getLogger("lumina.backend.vision.router")

router = APIRouter(prefix="/api/v1/vision", tags=["vision"])

# 由 main.py 注入 service 实例
_vision_service: VisionService | None = None


def init_router(service: VisionService) -> None:
    """注入 service 依赖（由 main.py 在应用启动时调用）。

    Args:
        service: VisionService 实例
    """
    global _vision_service
    _vision_service = service


def _get_service() -> VisionService:
    if _vision_service is None:
        raise HTTPException(status_code=500, detail="服务未初始化")
    return _vision_service


@router.post("/analyze", response_model=VisionAnalyzeResponse)
def vision_analyze(req: VisionAnalyzeRequest) -> VisionAnalyzeResponse:
    """视觉识别接口。

    接收 base64 图片，调用视觉大模型解析关键信息，
    返回简短中文描述供端侧 TTS 播报。
    """
    try:
        return _get_service().analyze(req.image_base64)
    except ValueError as e:
        raise HTTPException(status_code=500, detail=str(e)) from e
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    except Exception as e:
        logger.error("vision_analyze unexpected error: %s", e)
        raise HTTPException(status_code=500, detail="服务器内部错误") from e
