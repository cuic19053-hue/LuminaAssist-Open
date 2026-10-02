"""_parse_agent_json 工具函数测试。

直接测试 main.py 中的 _parse_agent_json 函数，覆盖 JSON 解析的兜底逻辑。
"""
from __future__ import annotations

import json

import pytest

from main import _parse_agent_json


def test_parse_plain_json() -> None:
    """正例：直接 json.loads 成功。"""
    result = _parse_agent_json('{"a": 1}')
    assert result == {"a": 1}


def test_parse_json_with_codeblock_prefix() -> None:
    """正例：剥离 ```json ... ``` 代码块。"""
    raw = '```json\n{"tasks": [], "tts_message": "好的"}\n```'
    result = _parse_agent_json(raw)
    assert result["tts_message"] == "好的"


def test_parse_json_with_plain_codeblock() -> None:
    """正例：剥离 ``` ... ``` 代码块（无 json 标记）。"""
    raw = '```\n{"tasks": []}\n```'
    result = _parse_agent_json(raw)
    assert result["tasks"] == []


def test_parse_invalid_raises_jsondecodeerror() -> None:
    """反例：无法解析的内容抛 JSONDecodeError。"""
    with pytest.raises(json.JSONDecodeError):
        _parse_agent_json("这不是JSON")


def test_parse_empty_string_raises() -> None:
    """反例：空字符串抛 JSONDecodeError。"""
    with pytest.raises(json.JSONDecodeError):
        _parse_agent_json("")


def test_parse_codeblock_without_closing_fence_tolerant() -> None:
    """边界：代码块未闭合时函数仍能宽容解析（移除首行 ```json 后剩余即为 JSON）。

    这其实是一个正向特性：LLM 偶尔会漏掉闭合 ```，函数仍能恢复。
    """
    raw = '```json\n{"tasks": []}'
    result = _parse_agent_json(raw)
    assert result["tasks"] == []


def test_parse_chinese_content() -> None:
    """正例：中文内容应正确解析。"""
    raw = json.dumps({"tts_message": "好的，马上拨打"}, ensure_ascii=False)
    result = _parse_agent_json(raw)
    assert result["tts_message"] == "好的，马上拨打"
