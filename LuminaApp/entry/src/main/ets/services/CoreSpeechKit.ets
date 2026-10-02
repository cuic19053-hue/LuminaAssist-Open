/**
 * @file CoreSpeechKit.ets
 * @description 本地类型声明，替代 @kit.CoreSpeechKit。
 * OpenHarmony SDK 不含此模块，运行时通过 canIUse 检测可用性。
 */

import { BusinessError } from '@ohos.base';

export class speechRecognizer {
  static createEngine(_params: CreateEngineParams, _callback: (err: BusinessError, engine: SpeechRecognitionEngineImpl) => void): void {
    // OpenHarmony 骨架模式：不实现，由 canIUse 运行时拦截
  }
}

export class SpeechRecognitionEngineImpl {
  setListener(_listener: RecognitionListener): void {}
  startListening(_params: StartParams): void {}
  finish(_sessionId: string): void {}
  cancel(_sessionId: string): void {}
  shutdown(): void {}
}

export class CreateEngineParams {
  language: string = '';
  online: number = 0;
  sessionId?: string;
}

export type SpeechRecognitionEngine = SpeechRecognitionEngineImpl;

export class RecognitionListener {
  onStart: (sessionId: string, eventMessage: string) => void = () => {};
  onEvent: (sessionId: string, eventCode: number, eventMessage: string) => void = () => {};
  onResult: (sessionId: string, result: SpeechRecognitionResult) => void = () => {};
  onComplete: (sessionId: string, eventMessage: string) => void = () => {};
  onError: (sessionId: string, errorCode: number, errorMessage: string) => void = () => {};
}

export class SpeechRecognitionResult {
  result: string = '';
  isFinal: boolean = false;
  isLast: boolean = false;
  confidence?: number;
}

export class StartParams {
  sessionId: string = '';
  audioInfo: AudioInfo = new AudioInfo();
  extraParams?: Record<string, Object>;
}

export class AudioInfo {
  audioType: string = '';
  sampleRate: number = 0;
  soundChannel: number = 0;
  sampleBit: number = 0;
  audioSourceType?: number;
  channels?: number;
  audioEncoding?: number;
}
