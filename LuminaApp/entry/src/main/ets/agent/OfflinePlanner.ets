/**
 * @file OfflinePlanner.ets
 * @module agent
 * @description 纯本地规则规划器：云端 API 与端侧 LLM 均不可用时的最终兜底。
 * 覆盖打电话/短信/打车/识物/识药/紧急呼叫等高频意图，不依赖任何网络或 .ms 大模型。
 */

import { AgentPlanResponse, BackendTask } from './types';

/**
 * 基于关键词的离线任务规划。
 * @param text 用户指令
 * @returns tasks + tts_message
 */
export function planOffline(text: string): AgentPlanResponse {
  const t: string = text.trim();
  if (t.length === 0) {
    return { tasks: [], tts_message: '请说出您的指令' };
  }

  // 紧急号码
  if (containsAny(t, ['120', '110', '119', '急救', '报警', '火警'])) {
    let target: string = '120';
    if (t.indexOf('110') >= 0 || t.indexOf('报警') >= 0) {
      target = '110';
    } else if (t.indexOf('119') >= 0 || t.indexOf('火警') >= 0) {
      target = '119';
    }
    return singleTask('emergency_call', target, '', `好的，正在呼叫${target}`);
  }

  // 打电话（优先于短信，避免「给妈妈打电话」误判为发短信）
  if (containsAny(t, ['打电话', '打出', '呼叫', '拨打', '通电话']) &&
    !containsAny(t, ['短信', '发消息', '发微信'])) {
    const name: string = extractContact(t);
    return singleTask('emergency_call', name.length > 0 ? name : '', '',
      name.length > 0 ? `好的，正在拨打${name}` : '好的，正在打开拨号');
  }

  // 发短信
  if (containsAny(t, ['发短信', '发消息', '短信'])) {
    const name: string = extractContact(t);
    const content: string = extractSmsContent(t);
    return singleTask('send_sms', name.length > 0 ? name : '', content,
      name.length > 0 ? `好的，准备给${name}发短信` : '好的，准备发短信');
  }

  // 打车
  if (containsAny(t, ['打车', '叫车', '叫出租车', '网约车'])) {
    const dest: string = extractDestination(t);
    return singleTask('call_ride', dest.length > 0 ? dest : 'default', '',
      dest.length > 0 ? `好的，正在叫车去${dest}` : '好的，正在叫车');
  }

  // 药品识别
  if (containsAny(t, ['药', '药盒', '药瓶', '说明书', '怎么吃', '用法用量'])) {
    return multiTasks([
      { action: 'capture_image', target: 'camera', content: '' },
      { action: 'medicine_recognition', target: 'camera', content: '' }
    ], '好的，本地模式识别药品');
  }

  // 读屏
  if (containsAny(t, ['读屏', '屏幕上写', '读一下屏幕', '朗读屏幕'])) {
    return singleTask('read_screen', 'screen', '', '好的，正在朗读屏幕');
  }

  // 纯文字阅读（OCR）
  if (containsAny(t, ['读信', '读书', '读文字', '读一下文字'])) {
    return multiTasks([
      { action: 'capture_image', target: 'camera', content: '' },
      { action: 'read_text', target: 'camera', content: '' }
    ], '好的，本地极速读取文字');
  }

  // 视觉详细描述
  if (containsAny(t, ['看看上面写', '详细描述', '读一下'])) {
    return multiTasks([
      { action: 'capture_image', target: 'camera', content: '' },
      { action: 'vision_analyze', target: 'camera', content: '' }
    ], '好的，本地模式拍照识别');
  }

  // 通用识物
  if (containsAny(t, ['这是什么', '识别', '看看', '拍一下', '帮我看', '认一下'])) {
    return multiTasks([
      { action: 'capture_image', target: 'camera', content: '' },
      { action: 'image_classify', target: 'camera', content: '' }
    ], '好的，本地模式识别物品');
  }

  // 闲聊 / 未知：仍返回可播报文案，保证有反馈
  return { tasks: [], tts_message: '本地模式已开启。您可以说：打电话、发短信、打车、识别物品或识别药品。' };
}

function singleTask(action: string, target: string, content: string, tts: string): AgentPlanResponse {
  const task: BackendTask = { action: action, target: target, content: content };
  return { tasks: [task], tts_message: tts };
}

function multiTasks(tasks: Array<BackendTask>, tts: string): AgentPlanResponse {
  return { tasks: tasks, tts_message: tts };
}

function containsAny(text: string, keys: Array<string>): boolean {
  for (let i = 0; i < keys.length; i++) {
    if (text.indexOf(keys[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 从「给X打电话/发短信」等句式抽取联系人（纯字符串，兼容 ArkTS）。 */
function extractContact(text: string): string {
  const prefixes: Array<string> = ['给', '打电话给', '发短信给', '呼叫', '拨打'];
  const suffixes: Array<string> = ['打电话', '的电话', '发短信', '发消息', '电话'];
  for (let i = 0; i < prefixes.length; i++) {
    const p: string = prefixes[i];
    const idx: number = text.indexOf(p);
    if (idx < 0) {
      continue;
    }
    let rest: string = text.substring(idx + p.length);
    for (let j = 0; j < suffixes.length; j++) {
      const sIdx: number = rest.indexOf(suffixes[j]);
      if (sIdx > 0) {
        rest = rest.substring(0, sIdx);
        break;
      }
    }
    rest = rest.split('的').join('').trim();
    if (rest.length > 0 && rest.length <= 12) {
      return rest;
    }
  }
  return '';
}

function extractSmsContent(text: string): string {
  const idx: number = text.indexOf('说');
  if (idx >= 0 && idx < text.length - 1) {
    return text.substring(idx + 1).trim();
  }
  return '';
}

function extractDestination(text: string): string {
  let idx: number = text.indexOf('去');
  if (idx < 0) {
    idx = text.indexOf('到');
  }
  if (idx >= 0 && idx < text.length - 1) {
    let dest: string = text.substring(idx + 1).trim();
    dest = dest.replace('打车', '').replace('叫车', '').trim();
    return dest;
  }
  return '';
}
