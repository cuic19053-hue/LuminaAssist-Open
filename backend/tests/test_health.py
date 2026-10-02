"""健康检查接口测试。

覆盖 GET /health 接口的正例与异常路径。
"""
from __future__ import annotations

from fastapi.testclient import TestClient


def test_health_returns_ok_status(client: TestClient) -> None:
    """正例：/health 始终返回 status=ok。"""
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert "api_key_configured" in body
    assert isinstance(body["api_key_configured"], bool)


def test_health_api_key_field_is_bool_not_string(client: TestClient) -> None:
    """边界：api_key_configured 必须是布尔值，禁止返回真实 Key 字符串。"""
    resp = client.get("/health")
    body = resp.json()
    assert body["api_key_configured"] in (True, False)
    # 安全检查：响应体中不得出现 sk- 前缀的 API Key
    body_text = resp.text
    assert "sk-" not in body_text, "健康检查接口泄露 API Key"


def test_health_method_not_allowed(client: TestClient) -> None:
    """反例：/health 不允许 POST。"""
    resp = client.post("/health")
    assert resp.status_code == 405


def test_health_no_auth_required(client: TestClient) -> None:
    """正例：/health 无需鉴权即可访问（用于端侧启动连通性检测）。"""
    resp = client.get("/health", headers={})
    assert resp.status_code == 200
