"""健康检查路由。"""

from fastapi import APIRouter

router = APIRouter(tags=["health"])

# 由 main.py 注入状态
_api_key_configured: bool = False


def init_router(api_key_configured: bool) -> None:
    """注入健康检查状态。"""
    global _api_key_configured
    _api_key_configured = api_key_configured


@router.get("/health")
def health_check() -> dict:
    """健康检查接口。

    返回服务状态及 API Key 配置情况（不返回实际 Key 值）。
    """
    return {"status": "ok", "api_key_configured": _api_key_configured}
