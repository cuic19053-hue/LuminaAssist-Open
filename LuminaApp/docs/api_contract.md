# 端侧 Agent API 契约

> 光语助手鸿蒙端侧 UI 与端侧 Agent 的内部交互规范

---

## 一、概述

光语助手已从"端云一体"架构改造为**纯端侧内嵌 Agent** 架构：

- 端侧 UI 通过 `Agent.getInstance().invoke()` 调用端侧智能体；
- 端侧 Agent 内部完成**意图识别 → 任务编排 → 子任务执行 → TTS 播报**；
- 唯一对外网络调用是云端 LLM（DeepSeek / OpenAI 等，用于开放式问答与意图兜底）；
- 不再需要任何自建 Python 后端。

UI 与 Agent 之间的契约如下。

---

## 二、调用方法

```typescript
import { Agent } from '../agent/Agent';
import { AgentResponse } from '../agent/types';

const response: AgentResponse = await Agent.getInstance().invoke({
  text: '读一下眼前这本书',
  image_base64: '...',          // 可选，由相机取帧后注入
  session_id: 'default',         // 用于多轮上下文
  location: { latitude, longitude }, // 可选
  meta: { device_model: 'Mate 60' }   // 可选
});
```

---

## 三、请求体 `AgentRequest` Schema

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `text` | string | 是 | 用户语音转写后的指令文本 |
| `image_base64` | string | 否 | 图像数据（base64 字符串，不含 `data:` 前缀） |
| `session_id` | string | 否 | 会话 ID，用于维护多轮上下文，默认 `default` |
| `location` | object | 否 | `{ latitude, longitude }` |
| `meta` | object | 否 | 自定义元数据（设备型号、用户偏好等） |

---

## 四、响应体 `AgentResponse` Schema

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `intent` | `Intent` | 是 | 识别出的意图（见下表） |
| `tasks` | `SubTask[]` | 是 | 端侧 Agent 已执行的子任务队列（执行后回填） |
| `tts_message` | string | 是 | 最终播报给用户的 TTS 文本（**必须**通过 TTS 播报） |
| `metadata` | object | 否 | 耗时、置信度等 |

### 支持的意图

| Intent | 含义 | 典型指令 |
| --- | --- | --- |
| `reading_assist` | 阅读辅助（OCR + 朗读） | "读一下说明书" |
| `object_recognition` | 物体识别 | "前面是什么" |
| `face_recognition` | 人脸识别 | "他是谁" |
| `scene_describe` | 场景描述 | "我在哪" |
| `navigation` | 导航 | "带我去火车站" |
| `qa` | 自由问答 | "今天天气怎么样" |
| `emergency` | 紧急求助 | "救命" |
| `small_talk` | 闲聊 | "你好" |
| `unknown` | 未知 | 其他 |

### `SubTask` Schema

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 子任务唯一 ID |
| `action` | `ActionType` | `speak` / `capture_image` / `ocr` / `object_detect` / `face_detect` / `llm_query` / `vibrate` / `navigate` |
| `params` | object | 动作参数 |
| `description` | string | 任务中文描述，可用于 TTS 进度播报 |
| `critical` | boolean | 是否关键任务（失败时是否中断） |

---

## 五、响应示例

```json
{
  "intent": "reading_assist",
  "tasks": [
    { "id": "task_xxx_1", "action": "speak", "params": { "text": "正在拍摄" }, "description": "准备拍摄", "critical": false },
    { "id": "task_xxx_2", "action": "capture_image", "params": {}, "description": "拍摄中", "critical": true },
    { "id": "task_xxx_3", "action": "ocr", "params": {}, "description": "识别文字中", "critical": true },
    { "id": "task_xxx_4", "action": "speak", "params": { "text": "..." }, "description": "朗读结果", "critical": true }
  ],
  "tts_message": "检测到一行字：每日三次，饭后服用。",
  "metadata": { "duration_ms": 1820, "confidence": 0.92 }
}
```

---

## 六、错误处理约定

- **必须 TTS 兜底**：所有异常路径都通过 `tts_message` 提供面向用户的中文文案。
- **禁止静默失败**：日志记录与 TTS 播报缺一不可。
- **多语言 fallback**：TTS 引擎不可用时自动降级为短振动反馈。
