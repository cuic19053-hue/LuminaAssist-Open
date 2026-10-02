/**
 * @file types.ets
 * @module agent
 * @description 端侧 Agent 使用的类型定义。
 *
 * 所有 Agent 内部流转的数据结构（意图、子任务、响应等）均在此集中定义，
 * 避免循环依赖与类型分散。
 */

/**
 * 支持的意图类型。
 * 视障与高龄用户高频场景：阅读、识别、问答、紧急求助。
 */
export type Intent =
  | 'reading_assist'    // 阅读辅助（OCR + 朗读）
  | 'object_recognition' // 物体识别
  | 'face_recognition'   // 人脸识别
  | 'scene_describe'     // 场景描述
  | 'medicine_recognition' // 药品识别（药盒/药瓶/说明书 → 结构化用药信息）
  | 'navigation'         // 导航
  | 'qa'                 // 自由问答
  | 'emergency'          // 紧急求助
  | 'small_talk'         // 闲聊
  | 'unknown'            // 未知意图
  | 'backend_routed';    // 后端代理已路由（前后端分离架构占位）

/**
 * 子任务动作类型（端侧本地执行器使用，保留用于离线兜底）。
 */
export type ActionType =
  | 'capture_image'     // 拍摄/取帧
  | 'ocr'               // 文字识别
  | 'image_classify'    // 图像分类（端侧 MobileNetV2 + MindSpore Lite 优先 + 云端 Qwen-VL 兜底）
  | 'object_detect'     // 物体检测
  | 'face_detect'       // 人脸检测
  | 'medicine_recognize'  // 药品识别（结构化抽取 + 用药提示）
  | 'speak'             // TTS 播报
  | 'vibrate'           // 振动反馈
  | 'navigate'          // 导航
  | 'llm_query';        // 调用大模型

/**
 * 药品识别结构化结果。
 * 由 VisionService.recognizeMedicine() 从 LLM JSON 输出解析得到。
 * 字段全部可选——LLM 不一定能在画面中识别到全部信息。
 */
export interface MedicineInfo {
  /** 药品名称（通用名或商品名） */
  name?: string;
  /** 主要成分 */
  activeIngredient?: string;
  /** 规格（如 0.25g x 24 片） */
  specification?: string;
  /** 用法用量（如 一次1片，一日3次，饭后服用） */
  dosage?: string;
  /** 适应症 / 主治功能 */
  indications?: string;
  /** 禁忌与注意事项 */
  contraindications?: string;
  /** 不良反应 */
  adverseReactions?: string;
  /** 常见药物/食物相互作用 */
  interactions?: string;
  /** 特殊人群提示（儿童、孕妇、老人、肝肾功能异常等） */
  specialPopulation?: string;
  /** 有效期（如 至 2027-06） */
  expiration?: string;
  /** 生产厂家 */
  manufacturer?: string;
  /** 风险等级：0=正常，1=需注意，2=高风险（如过期/禁忌人群） */
  riskLevel?: number;
  /** 风险提示文案（riskLevel > 0 时必填，用于 TTS 强提示） */
  riskHint?: string;
  /** 图片中实际读取到的包装/说明书文字，用于约束回答 */
  observedText?: string;
  /** 联网补充信息所参考的来源摘要 */
  sourceSummary?: string;
  /** 是否确认图片主体为药品 */
  isMedicine?: boolean;
}

/**
 * 药品识别完整返回（结构化信息 + TTS 文案）。
 */
export interface MedicineRecognitionResult {
  /** 结构化药品信息 */
  info: MedicineInfo;
  /** 用于 TTS 播报的中文文案 */
  tts: string;
}

/** 药品追问回答（文字与 TTS 使用同一份内容，避免信息不一致） */
export interface MedicineQuestionResult {
  answer: string;
  tts: string;
}

/**
 * 子任务参数（保留用于离线兜底执行器）。
 */
export interface TaskParams {
  /** speak 动作的播报文本 */
  text?: string;
  /** llm_query 动作的子类型（scene/emergency/qa/small_talk/general） */
  kind?: string;
  /** llm_query 动作的用户原始提示词 */
  prompt?: string;
  /** navigate 动作的目的地 */
  destination?: string;
  /** vibrate 动作的持续毫秒数 */
  duration?: number;
}

/**
 * 单个子任务定义（保留用于离线兜底执行器）。
 */
export interface SubTask {
  /** 子任务唯一 ID，由 Planner 生成（UUID 或自增） */
  id: string;
  /** 动作类型，决定由哪个本地处理器执行 */
  action: ActionType;
  /** 动作参数（结构由 action 决定） */
  params: TaskParams;
  /** 子任务中文描述，用于 TTS 播报（视障用户核心反馈） */
  description: string;
  /** 是否关键任务（关键任务失败时主动重试） */
  critical: boolean;
}

/**
 * 意图识别结果（保留用于本地规则匹配兜底，前后端分离架构下不再主用）。
 */
export interface IntentResult {
  /** 识别出的意图 */
  intent: Intent;
  /** 意图置信度 [0, 1] */
  confidence: number;
  /** 从原文中抽取的实体（位置、人物、物体等） */
  entities: Record<string, string>;
  /** 用于任务编排的附加上下文 */
  context: Record<string, Object>;
}

/**
 * Agent 执行元数据。
 * 记录耗时、置信度、错误等信息，供 UI 层展示与排查。
 */
export interface AgentMetadata {
  /** 本次 invoke 总耗时（毫秒） */
  duration_ms: number;
  /** 意图置信度 */
  confidence?: number;
  /** 错误信息（执行失败时填充） */
  error?: string;
}

/**
 * Agent 对外的统一响应。
 * 与原 ApiClient 响应结构保持一致，便于 UI 层平滑迁移。
 *
 * 架构变更（2026-07-20 前后端分离）：
 * - intent 默认 'backend_routed'，端侧不再做意图识别；
 * - tasks 字段保留 SubTask[] 类型用于离线兜底场景，正常路径下为空数组；
 * - 实际执行的任务由 TaskPlanner.execute(BackendTask[]) 内部 TTS 反馈。
 */
export interface AgentResponse {
  /** 意图标签 */
  intent: Intent;
  /** 子任务队列（前后端分离架构下默认空，仅离线兜底时填充） */
  tasks: SubTask[];
  /** 直接播报给用户的 TTS 文本（禁止为空） */
  tts_message: string;
  /** 元数据（耗时、模型版本、置信度等） */
  metadata?: AgentMetadata;
}

/**
 * 地理位置信息。
 */
export interface Location {
  /** 纬度 */
  latitude: number;
  /** 经度 */
  longitude: number;
}

/**
 * Agent 请求体。
 * 由 UI 层 / 语音层封装后传入。
 */
export interface AgentRequest {
  /** 用户语音转写后的文本（必填） */
  text: string;
  /** 可选的图像（拍照/取帧结果） */
  image_base64?: string;
  /** 会话上下文（多轮对话） */
  session_id?: string;
  /** 设备位置（可选，用于导航意图） */
  location?: Location;
  /** 附加元数据（时间、设备型号等） */
  meta?: Record<string, Object>;
}

/**
 * 多模态消息（用于端侧 LLMClient 离线兜底调用）。
 * 参考 OpenAI / DeepSeek Chat Completion 格式。
 */
export interface LLMMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
  /** 可选图像（多模态 LLM 使用） */
  image_base64?: string;
}

/**
 * 对话历史条目（用于多轮对话上下文与 UI 展示）。
 */
export interface ChatHistoryItem {
  /** 角色：user / assistant */
  role: string;
  /** 消息文本 */
  text: string;
  /** 可选：视觉识别预览图 base64（不含 data URL 前缀） */
  imageBase64?: string;
}

/**
 * 关键词规则（保留用于离线兜底意图路由）。
 */
export interface KeywordRule {
  /** 触发关键词列表 */
  keywords: string[];
  /** 命中后映射到的意图 */
  intent: Intent;
}

/**
 * 视觉识别结构化结果。
 * 由 VisionService.analyzeItem() 从 Qwen-VL JSON 输出解析得到。
 */
export interface VisionAnalyzeResult {
  /** 物品名称 */
  item_name: string;
  /** 物品类别（如 medicine/appliance/food/document/unknown） */
  category: string;
  /** 核心要素（已过滤条形码/厂家等冗余信息） */
  key_info: string;
  /** 可直接朗读的中文口语化 TTS 文案，无 Markdown */
  tts_message: string;
  /** 是否模糊/不可识别 */
  is_blurry: boolean;
}

/**
 * 后端下发的任务单元。
 * 由 /api/v1/agent/plan 返回，端侧 TaskPlanner 负责执行。
 */
export interface BackendTask {
  /**
   * 动作类型：capture_image / image_classify / medicine_recognition /
   * send_sms / call_ride / vision_analyze / emergency_call(make_call/dial) / read_screen
   */
  action: string;
  /** 动作目标（联系人/电话/目的地/固定标识） */
  target: string;
  /** 动作内容（如短信正文） */
  content: string;
}

/**
 * /api/v1/agent/plan 请求体。
 */
export interface PlanRequestBody {
  text: string;
  session_id?: string;
  history?: Array<Record<string, string>>;
}

/**
 * /api/v1/agent/plan 响应体。
 */
export interface AgentPlanResponse {
  /** 后端规划的任务列表 */
  tasks: Array<BackendTask>;
  /** TTS 播报文本 */
  tts_message: string;
}

/**
 * /api/v1/vision/analyze 响应体。
 */
export interface VisionAnalyzeResponse {
  /** TTS 播报文本 */
  tts_message: string;
}
