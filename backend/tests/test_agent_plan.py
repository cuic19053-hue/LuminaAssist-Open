"""Agent 任务规划接口测试。

覆盖 POST /api/v1/agent/plan 接口的正例/反例/边界/异常路径。
使用 fake_openai 夹具隔离真实阿里云百炼调用。
"""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from tests.conftest import FakeOpenAI


# ==================== 正例 ====================

def test_plan_normal_returns_tasks_and_tts(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """正例：LLM 返回标准 JSON，接口应解析为 tasks 列表。"""
    fake_openai.set_chat_response(
        json.dumps({
            "tasks": [
                {"action": "emergency_call", "target": "女儿", "content": ""},
            ],
            "tts_message": "好的，马上拨打女儿电话",
        }, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "帮我打给女儿"})
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["tasks"]) == 1
    assert body["tasks"][0]["action"] == "emergency_call"
    assert body["tasks"][0]["target"] == "女儿"
    assert body["tts_message"] == "好的，马上拨打女儿电话"


def test_plan_empty_tasks_with_tts(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """正例：LLM 返回空 tasks（无法理解意图时），接口应原样下发。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": "我没听明白，请再说一遍"}, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "你好"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["tasks"] == []
    assert body["tts_message"] == "我没听明白，请再说一遍"


def test_plan_multi_tasks_order_preserved(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """正例：多任务顺序应保留（capture_image 必须先于 image_classify）。"""
    fake_openai.set_chat_response(
        json.dumps({
            "tasks": [
                {"action": "capture_image", "target": "camera", "content": ""},
                {"action": "image_classify", "target": "camera", "content": ""},
            ],
            "tts_message": "好的，马上识别",
        }, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "看看这是什么"})
    body = resp.json()
    assert body["tasks"][0]["action"] == "capture_image"
    assert body["tasks"][1]["action"] == "image_classify"


# ==================== 边界 ====================

def test_plan_json_wrapped_in_codeblock(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：LLM 返回 ```json ... ``` 包裹的 JSON，应能兜底解析。"""
    raw = """```json
{"tasks": [{"action": "send_sms", "target": "120", "content": "我摔倒了"}], "tts_message": "马上发送"}
```"""
    fake_openai.set_chat_response(raw)
    resp = client.post("/api/v1/agent/plan", json={"text": "发短信给120"})
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["tasks"]) == 1
    assert body["tasks"][0]["action"] == "send_sms"


def test_plan_json_wrapped_in_plain_codeblock(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：LLM 返回 ``` ... ``` 包裹（无 json 标记）的 JSON。"""
    raw = """```
{"tasks": [], "tts_message": "好的"}
```"""
    fake_openai.set_chat_response(raw)
    resp = client.post("/api/v1/agent/plan", json={"text": "嗯"})
    assert resp.status_code == 200
    assert resp.json()["tts_message"] == "好的"


def test_plan_invalid_json_falls_back_to_empty(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """反例：LLM 返回无法解析的内容，应兜底返回空 tasks 与提示语（不返回 500）。"""
    fake_openai.set_chat_response("这不是JSON，是一段普通文本")
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["tasks"] == []
    assert body["tts_message"] == "我没听明白，请再说一遍"


def test_plan_tasks_not_list_falls_back_to_empty(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：tasks 字段非 list 时应兜底为空数组。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": "not_a_list", "tts_message": "好的"}, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    body = resp.json()
    assert body["tasks"] == []


def test_plan_tts_message_not_string_falls_back(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：tts_message 非 str 时应兜底为"好的"。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": 12345}, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    body = resp.json()
    assert body["tts_message"] == "好的"


def test_plan_missing_tts_message_uses_default(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：LLM 漏返 tts_message 时使用默认值"好的"。"""
    fake_openai.set_chat_response(json.dumps({"tasks": []}, ensure_ascii=False))
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    body = resp.json()
    assert body["tts_message"] == "好的"


def test_plan_empty_text_still_calls_llm(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """边界：空文本也应进入 LLM 调用（由 LLM 决定如何兜底）。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": "请说出您的指令"}, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": ""})
    assert resp.status_code == 200
    assert fake_openai.create_call_count == 1


# ==================== 反例 ====================

def test_plan_missing_text_field_returns_422(client: TestClient) -> None:
    """反例：请求体缺少 text 字段，应返回 422 校验错误。"""
    resp = client.post("/api/v1/agent/plan", json={})
    assert resp.status_code == 422


def test_plan_wrong_content_type_returns_422(client: TestClient) -> None:
    """反例：非 JSON 请求体应被拒绝。"""
    resp = client.post(
        "/api/v1/agent/plan",
        content="text=hello",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert resp.status_code == 422


def test_plan_llm_exception_returns_502(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """反例：LLM 调用抛异常时返回 502。"""
    fake_openai.set_raise(RuntimeError("网络超时"))
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    assert resp.status_code == 502
    assert resp.json()["detail"] == "Agent 服务暂不可用"


def test_plan_no_api_key_returns_500(monkeypatch: pytest.MonkeyPatch, client: TestClient) -> None:
    """反例：未配置 API Key 时返回 500。"""
    import main as main_module
    monkeypatch.setattr(main_module, "ALIYUN_API_KEY", "")
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    assert resp.status_code == 500
    assert resp.json()["detail"] == "服务端未配置 API Key"


# ==================== 安全 ====================

def test_plan_response_does_not_leak_api_key(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """安全：响应体中不得出现 API Key 字符串。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": "好的"}, ensure_ascii=False)
    )
    resp = client.post("/api/v1/agent/plan", json={"text": "测试"})
    assert "sk-" not in resp.text
    assert "ALIYUN_API_KEY" not in resp.text


def test_plan_calls_llm_once_per_request(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """正例：每次请求只调用一次 LLM（无重试导致费用翻倍）。"""
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": "好的"}, ensure_ascii=False)
    )
    client.post("/api/v1/agent/plan", json={"text": "测试"})
    assert fake_openai.create_call_count == 1

def test_plan_with_profile_injection(client: TestClient, fake_openai: FakeOpenAI) -> None:
    """正例：当前用户存在时，档案信息应该注入到 System Prompt。"""
    # Create fake user in DB and login to get token
    response = client.post("/api/v1/auth/login", json={"device_id": "test_device_profile"})
    token = response.json()["access_token"]
    
    # Update profile
    headers = {"Authorization": f"Bearer {token}"}
    client.put("/api/v1/auth/profile", json={
        "chronic_diseases": ["高血压"],
        "allergies": [],
        "medication_habits": "晚上吃药"
    }, headers=headers)
    
    fake_openai.set_chat_response(
        json.dumps({"tasks": [], "tts_message": "好的"}, ensure_ascii=False)
    )
    
    client.post("/api/v1/agent/plan", json={"text": "测试"}, headers=headers)
    
    # Check if prompt has the injected context
    assert len(fake_openai.last_messages) == 2
    system_msg = fake_openai.last_messages[0]["content"]
    assert "高血压" in system_msg
    assert "晚上吃药" in system_msg
