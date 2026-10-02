/**
 * @file Index.ets
 * @description 光语助手 LuminaAssist 主页面（对齐高保真薄荷绿界面原型 Screen 01 - 08）。
 * 
 * 遵从三条底线：
 * 1. 语音优先，触控为辅（大热区 ≥ 96vp）；
 * 2. 高对比浅色调（薄荷绿主色 #10B981，纯白云底 #F6FAF8）；
 * 3. 状态可听可见（四色状态 + 振动反馈）。
 */

import { VisionService } from '../services/VisionService';
import { Logger } from '../utils/Logger';
import { AccessibilityUtils } from '../utils/AccessibilityUtils';
import { Agent } from '../agent/Agent';
import { SpeechService } from '../services/SpeechService';
import {
  VoiceInputController,
  VoiceInputCallbacks,
  VoiceInputState
} from '../agent/VoiceInputController';
import {
  AgentRequest,
  ChatHistoryItem,
  MedicineInfo,
  MedicineRecognitionResult,
  VisionAnalyzeResult,
  SubTask,
  BackendTask
} from '../agent/types';
import { StatusBanner } from '../components/StatusBanner';
import { ConversationBubble } from '../components/ConversationBubble';
import { MedicineInfoCard } from '../components/MedicineInfoCard';
import { CameraPreviewOverlay } from '../components/CameraPreviewOverlay';
import { TaskListView, UIBackendTask } from '../components/TaskListView';
import { DocumentReaderCard } from '../components/DocumentReaderCard';
import { NetworkFallbackDialog } from '../components/NetworkFallbackDialog';
import { PrivacyDialog } from '../components/PrivacyDialog';
import { IntentRouter, FallbackChoice } from '../agent/IntentRouter';
import { TaskPlanner, TaskRunStatus, TaskProgressCallback } from '../agent/TaskPlanner';
import { GestureService } from '../services/GestureService';
import { ScreenReaderService } from '../services/ScreenReaderService';
import { AppConfig } from '../utils/AppConfig';
import { PermissionUtil } from '../utils/PermissionUtil';
import { Permissions } from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import vibrator from '@ohos.vibrator';
import connection from '@ohos.net.connection';
import { BusinessError } from '@ohos.base';

const TAG: string = 'IndexPage';

@Entry
@Component
struct Index {
  // 顶部状态与通信
  @State statusText: string = '正在聆听 · 请说出您的指令';
  @State statusLevel: string = 'idle';
  @State isOnline: boolean = true;
  @State isProcessing: boolean = false;
  @State isVoiceHolding: boolean = false;
  @State inputText: string = '';

  // 端侧模型网络异常抉择弹窗
  @State showFallbackDialog: boolean = false;
  @State fallbackReason: string = '';
  private fallbackPromiseResolver: ((choice: FallbackChoice) => void) | null = null;

  // 首次启动隐私政策与用户协议弹窗
  @State showPrivacyDialog: boolean = false;

  // 模式控制：home | medicine | object | document | tasklist
  @State activeViewMode: string = 'home';

  // 拍照与预览
  @State previewBase64: string = '';
  @State showCameraPreview: boolean = false;
  @State cameraHintText: string = '正在启动相机…';
  @State showCaptureButton: boolean = false;
  @State cameraPreviewAspectRatio: number = 0;
  @State cameraScanTarget: 'medicine' | 'object' | 'document' = 'medicine';

  // 药品识别数据 (Screen 03)
  @State medicineName: string = '';
  @State medicineInfo: MedicineInfo | null = null;
  private currentMedicine: MedicineInfo | null = null;

  // 物品识别数据 (Screen 04)
  @State objectName: string = '';
  @State objectLocation: string = '';
  @State objectTip: string = '';
  @State isOfflineDegraded: boolean = false;

  // 文档朗读数据 (Screen 05)
  @State documentTitle: string = '体检报告';
  @State documentParagraphs: Array<string> = [];

  // 多任务拆解数据 (Screen 06)
  @State taskList: Array<UIBackendTask> = [];

  // 对话历史
  @State history: Array<ChatHistoryItem> = [];
  private listScroller: Scroller = new Scroller();

  // 服务单例引用
  private visionService: VisionService = VisionService.getInstance();
  private agent: Agent = Agent.getInstance();
  private voiceCtrl: VoiceInputController = VoiceInputController.getInstance();
  private speechService: SpeechService = SpeechService.getInstance();
  private gestureService: GestureService = GestureService.getInstance();

  private cameraSurfaceHandled: boolean = false;
  private cameraPhotoTaken: boolean = false;
  // 处理看门狗：防止 isProcessing 闩死导致全屏交互无响应
  private processingWatchdog: number = -1;

  /**
   * 统一的 isProcessing 置位入口：启动 60s 看门狗。
   * 超时后强制解锁并给出错误提示，避免任何异步链路卡死导致全屏点击无响应。
   */
  private beginProcessing(): void {
    this.isProcessing = true;
    if (this.processingWatchdog !== -1) {
      clearTimeout(this.processingWatchdog);
    }
    this.processingWatchdog = setTimeout(() => {
      if (this.isProcessing) {
        this.endProcessing();
        this.isVoiceHolding = false;
        this.statusLevel = 'error';
        this.statusText = '处理超时，请重试';
        AccessibilityUtils.getInstance().speak('处理超时，请重试');
        Logger.error(TAG, '处理看门狗超时，强制解锁交互');
      }
    }, 60000);
  }

  private endProcessing(): void {
    this.isProcessing = false;
    if (this.processingWatchdog !== -1) {
      clearTimeout(this.processingWatchdog);
      this.processingWatchdog = -1;
    }
  }

  aboutToAppear(): void {
    ScreenReaderService.getInstance().registerProvider((): string => this.buildScreenReadText());
    this.initGestureService();

    // 首次启动合规检查：根据工信部与华为审核要求弹出隐私政策授权弹窗
    this.checkPrivacyAgreement();

    // 订阅任务执行进度：驱动【任务拆解 Task List】卡片用实时打勾替代"一次性全勾"
    const progressListener: TaskProgressCallback = {
      onTaskStatus: (index: number, total: number, task: BackendTask,
        status: TaskRunStatus, message: string): void => {
        this.updateTaskStatus(index, status, message);
      }
    };
    TaskPlanner.getInstance().setProgressListener(progressListener);

    // 云端不可达时自动无缝降级端侧离线规划引擎，不再死锁等待未展示的弹窗
    IntentRouter.getInstance().setFallbackPromptHandler(null);

    // 初始化网络状态探测与实时监听
    this.initNetworkMonitoring();
  }

  aboutToDisappear(): void {
    ScreenReaderService.getInstance().unregisterProvider();
    IntentRouter.getInstance().setFallbackPromptHandler(null);
    TaskPlanner.getInstance().setProgressListener(null);
    if (this.netConn !== null) {
      try {
        this.netConn.unregister((_err: BusinessError) => {});
      } catch (e) {}
      this.netConn = null;
    }
  }

  /**
   * 检查是否已完成首次《用户协议》与《隐私政策》授权确认
   */
  private async checkPrivacyAgreement(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await AppConfig.getInstance().ensureInit(ctx);
      const agreed: boolean = await AppConfig.getInstance().hasAgreedPrivacy();
      if (!agreed) {
        this.showPrivacyDialog = true;
      }
    } catch (e) {
      Logger.error(TAG, `检查隐私政策授权状态失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 用户同意隐私政策与用户协议
   */
  private async handlePrivacyAgree(): Promise<void> {
    try {
      await AppConfig.getInstance().setAgreedPrivacy(true);
      this.showPrivacyDialog = false;
      AccessibilityUtils.getInstance().speak('欢迎使用光语助手，请点击识别药品或长按屏幕说出指令。');
    } catch (e) {
      Logger.error(TAG, `保存隐私政策同意状态失败: ${JSON.stringify(e)}`);
      this.showPrivacyDialog = false;
    }
  }

  /**
   * 用户拒绝隐私政策：安全退出应用
   */
  private handlePrivacyDisagree(): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      ctx.terminateSelf();
    } catch (e) {
      Logger.error(TAG, `退出应用失败: ${JSON.stringify(e)}`);
    }
  }

  private netConn: connection.NetConnection | null = null;

  /**
   * 初始化系统网络状态探测与连接变化监听
   */
  private initNetworkMonitoring(): void {
    try {
      connection.hasDefaultNet().then((hasNet: boolean) => {
        this.isOnline = hasNet;
        if (!hasNet) {
          this.statusText = '离线模式 · 触屏与本地任务就绪';
          this.statusLevel = 'idle';
        }
      }).catch(() => {
        this.isOnline = true;
      });

      this.netConn = connection.createNetConnection();
      this.netConn.on('netAvailable', (_netHandle: connection.NetHandle) => {
        Logger.info(TAG, '网络已连通，切换至云端在线');
        this.isOnline = true;
        this.statusLevel = 'idle';
        this.statusText = '已连接云端 · 长按说话或点击卡片';
      });
      this.netConn.on('netLost', (_netHandle: connection.NetHandle) => {
        Logger.info(TAG, '网络已断开，切换至端侧离线');
        this.isOnline = false;
        this.statusLevel = 'idle';
        this.statusText = '离线模式 · 触屏与本地任务就绪';
      });
      this.netConn.on('netUnavailable', () => {
        this.isOnline = false;
        this.statusLevel = 'idle';
        this.statusText = '离线模式 · 触屏与本地任务就绪';
      });
      this.netConn.register((_err: BusinessError) => {
        Logger.info(TAG, '网络状态变化监听注册成功');
      });
    } catch (e) {
      Logger.warn(TAG, `注册网络监听异常: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 规划生成后立即把任务卡片上屏（全部为「待执行」）。
   * 随后由 TaskPlanner 的进度回调逐项改为「进行中 / 已完成」，形成实时打勾效果。
   */
  private applyPlanTasks(tasks: Array<BackendTask>): void {
    if (!tasks || tasks.length === 0) {
      return;
    }
    const uiTasks: Array<UIBackendTask> = tasks.map((t: BackendTask): UIBackendTask => {
      const item: UIBackendTask = {
        action: t.action,
        target: t.target ?? '',
        content: t.content ?? '',
        status: 'pend',
        statusText: '待执行'
      };
      return item;
    });
    this.taskList = uiTasks;
    this.activeViewMode = 'tasklist';
  }

  /**
   * 更新单个任务的执行状态（由 TaskPlanner 进度回调驱动）。
   * @param index 任务下标
   * @param status 执行状态
   * @param message 结果文案
   */
  private updateTaskStatus(index: number, status: TaskRunStatus, message: string): void {
    if (index < 0 || index >= this.taskList.length) {
      return;
    }
    let statusText: string = '待执行';
    // 卡片视觉只有三态：pend 灰点 / run 橙点 / done 绿勾；失败也走橙点并靠文案区分
    let cardStatus: 'done' | 'run' | 'pend' = 'pend';
    if (status === 'run') {
      cardStatus = 'run';
      statusText = message.length > 0 ? message : '进行中';
    } else if (status === 'done') {
      cardStatus = 'done';
      statusText = message.length > 0 ? message : '已完成';
    } else if (status === 'fail') {
      cardStatus = 'run';
      statusText = message.length > 0 ? message : '执行失败';
    }

    const updated: Array<UIBackendTask> = this.taskList.slice();
    const old: UIBackendTask = updated[index];
    const next: UIBackendTask = {
      action: old.action,
      target: old.target,
      content: old.content,
      status: cardStatus,
      statusText: statusText
    };
    updated[index] = next;
    this.taskList = updated;
    Logger.info(TAG, `任务卡片更新 [${index}] -> ${status} ${statusText}`);
  }

  /**
   * 初始化手势快捷服务（敲3下：药品识别，敲2下：物品识别，长按1s：语音助手）
   */
  private initGestureService(): void {
    this.gestureService.registerCallbacks({
      onTripleTap: () => {
        this.startScanFlow('medicine');
      },
      onDoubleTap: () => {
        this.startScanFlow('object');
      },
      onLongPress: () => {
        this.onVoicePressStart();
      },
      onLongPressEnd: () => {
        this.onVoicePressEnd();
      }
    });
  }

  private buildScreenReadText(): string {
    const parts: Array<string> = [];
    if (this.statusText.length > 0) {
      parts.push(`当前状态：${this.statusText}`);
    }
    if (this.activeViewMode === 'medicine' && this.medicineInfo !== null) {
      parts.push(`当前药品识别结果：${this.medicineName}。${this.medicineInfo.indications ?? ''}`);
    } else if (this.activeViewMode === 'object') {
      parts.push(`当前物品识别：${this.objectName}。位于${this.objectLocation}`);
    }
    return parts.join('。');
  }

  /**
   * 启动相机拍照识别（药品 / 物品 / 文档）
   */
  private async startScanFlow(target: 'medicine' | 'object' | 'document'): Promise<void> {
    if (this.isProcessing || this.isVoiceHolding) {
      return;
    }
    this.beginProcessing();
    this.cameraScanTarget = target;
    this.previewBase64 = '';
    this.cameraSurfaceHandled = false;
    this.cameraPhotoTaken = false;
    this.showCaptureButton = false;
    this.cameraPreviewAspectRatio = 0;
    this.cameraHintText = target === 'medicine'
      ? '请将药盒放入框内，对准后自动拍摄'
      : (target === 'object' ? '请将物品对准画面中央' : '请将纸质文档对准框内');
    this.showCameraPreview = true;
    this.statusLevel = 'listening';
    this.statusText = '相机启动中…';

    AccessibilityUtils.getInstance().speak(`相机已打开，${this.cameraHintText}`);
    await this.vibrateShort();
  }

  private handleCameraSurfaceReady(surfaceId: string): void {
    if (this.cameraSurfaceHandled || !this.showCameraPreview) {
      return;
    }
    this.cameraSurfaceHandled = true;
    this.startLivePreviewFlow(surfaceId);
  }

  private async startLivePreviewFlow(surfaceId: string): Promise<void> {
    try {
      await this.visionService.startLivePreview(surfaceId);
      this.cameraPreviewAspectRatio = this.visionService.getLivePreviewAspectRatio();
      this.statusText = '相机取景中…';
      this.showCaptureButton = true;

      // 预热 2000ms 后自动抓拍
      await this.waitMs(2000);
      if (!this.showCameraPreview || this.cameraPhotoTaken) {
        return;
      }
      await this.captureAndProcessPhoto();
    } catch (error) {
      await this.closeCameraPreview();
      const msg: string = error instanceof Error ? error.message : '相机启动失败，请重试';
      this.endProcessing();
      this.statusLevel = 'error';
      this.statusText = '相机不可用';
      AccessibilityUtils.getInstance().speak(msg);
    }
  }

  private handleCameraCaptureTap(): void {
    if (this.cameraPhotoTaken || !this.showCameraPreview) {
      return;
    }
    this.captureAndProcessPhoto();
  }

  private async closeCameraPreview(): Promise<void> {
    this.showCameraPreview = false;
    this.showCaptureButton = false;
    this.cameraPreviewAspectRatio = 0;
    await this.visionService.stopLivePreview();
  }

  private async captureAndProcessPhoto(): Promise<void> {
    if (this.cameraPhotoTaken) {
      return;
    }
    this.cameraPhotoTaken = true;
    this.statusText = '正在拍摄…';

    try {
      const imageBase64: string = await this.visionService.captureFromLiveSession();
      await this.closeCameraPreview();
      this.previewBase64 = imageBase64;
      await this.vibrateShort();
      this.statusLevel = 'thinking';

      if (this.cameraScanTarget === 'medicine') {
        // 药品识别
        this.statusText = '正在分析药品信息…';
        AccessibilityUtils.getInstance().speak('已拍好，正在分析药品信息');
        const medicineResult: MedicineRecognitionResult =
          await this.visionService.recognizeMedicine(imageBase64);
        
        if (medicineResult.info.isMedicine === false || !medicineResult.info.name) {
          this.statusLevel = 'idle';
          this.statusText = medicineResult.tts;
          AccessibilityUtils.getInstance().speak(medicineResult.tts);
          return;
        }

        this.currentMedicine = medicineResult.info;
        this.medicineInfo = medicineResult.info;
        this.medicineName = medicineResult.info.name ?? '当前药品';
        this.activeViewMode = 'medicine';

        this.statusLevel = 'speaking';
        this.statusText = `已识别${this.medicineName}，可以继续提问`;
        AccessibilityUtils.getInstance().speak(medicineResult.tts);

      } else if (this.cameraScanTarget === 'object') {
        // 物品识别
        this.statusText = '正在辨识物品与位置关系…';
        AccessibilityUtils.getInstance().speak('已拍好，正在分析物品');
        const objectResult: VisionAnalyzeResult =
          await this.visionService.analyzeItem(imageBase64);

        this.objectName = objectResult.item_name;
        this.objectLocation = '您正前方';
        this.objectTip = objectResult.key_info;
        this.activeViewMode = 'object';

        this.statusLevel = 'speaking';
        this.statusText = `识别结果：${this.objectName}`;
        AccessibilityUtils.getInstance().speak(objectResult.tts_message);

      } else if (this.cameraScanTarget === 'document') {
        // 文档朗读
        this.statusText = '正在提取文档文字并分段…';
        AccessibilityUtils.getInstance().speak('已拍好，正在提取文档内容');
        const rawText: string =
          await this.visionService.readTextOffline(imageBase64);

        const lines: string[] = rawText.split('\n').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
        if (lines.length > 1 && lines[0].length <= 25) {
          this.documentTitle = lines[0];
        } else {
          this.documentTitle = '扫描文档';
        }

        // 分段
        const paragraphs: string[] = rawText
          .split(/[\n。；;]/)
          .map((p: string) => p.trim())
          .filter((p: string) => p.length > 0);
        this.documentParagraphs = paragraphs.length > 0 ? paragraphs : [rawText];
        this.activeViewMode = 'document';

        this.statusLevel = 'speaking';
        this.statusText = `已生成分段朗读，共 ${this.documentParagraphs.length} 段`;
        const firstPara: string = this.documentParagraphs[0];
        AccessibilityUtils.getInstance().speak(`文档识别完成，共 ${this.documentParagraphs.length} 段。正在朗读第一段：${firstPara}`);
      }
    } catch (error) {
      await this.closeCameraPreview();
      const msg: string = error instanceof Error ? error.message : '识别失败，请重试';
      this.statusLevel = 'error';
      this.statusText = '识别异常';
      AccessibilityUtils.getInstance().speak(msg);
    } finally {
      this.endProcessing();
      this.cameraPhotoTaken = false;
    }
  }

  /**
   * 处理文本/语音提问或指令
   * @param text 指令文本
   * @param fromVoice 是否来自语音链路（onPlanDone 回调时 isProcessing 已在置位中，需放行避免死锁丢弃结果）
   */
  private async processUserCommand(text: string, fromVoice: boolean = false): Promise<void> {
    if (text.trim().length === 0 || (this.isProcessing && !fromVoice)) {
      return;
    }
    this.beginProcessing();
    this.statusLevel = 'thinking';
    this.statusText = '正在理解指令…';

    const userItem: ChatHistoryItem = { role: 'user', text: text.trim() };
    this.history = this.history.concat(userItem);
    this.scrollHistoryToEnd();

    try {
      if (this.activeViewMode === 'medicine' && this.currentMedicine !== null) {
        // 药品问答
        const result = await this.visionService.answerMedicineQuestion(this.currentMedicine, text.trim());
        const assistantItem: ChatHistoryItem = { role: 'assistant', text: result.answer };
        this.history = this.history.concat(assistantItem);
        this.statusLevel = 'speaking';
        this.statusText = '问题已回答';
        AccessibilityUtils.getInstance().speak(result.tts);
      } else {
        // Agent 任务编排：规划一生成先上屏任务卡片，随后由进度回调实时打勾
        const request: AgentRequest = { text: text.trim() };
        const response = await this.agent.invoke(request, (tasks: Array<BackendTask>): void => {
          this.applyPlanTasks(tasks);
        });

        const ttsMsg = response.tts_message.length > 0 ? response.tts_message : '指令已处理。';
        const assistantItem: ChatHistoryItem = { role: 'assistant', text: ttsMsg };
        this.history = this.history.concat(assistantItem);

        // 兜底：极少数未走 onPlanReady 的路径（如端侧兜底拆分）在此补齐卡片
        if (!response.tasks || response.tasks.length === 0) {
          // 无任务：直接播报文案
          this.statusLevel = 'speaking';
          this.statusText = '回复完成';
          AccessibilityUtils.getInstance().speak(ttsMsg);
        } else {
          // 有任务：execute 内部已用 preAnnounce 统一播报过，此处不再重复朗读
          if (this.taskList.length === 0) {
            const fallbackTasks: Array<BackendTask> = response.tasks.map((t: SubTask): BackendTask => {
              const bt: BackendTask = {
                action: t.action,
                target: t.params?.destination ?? '',
                content: t.params?.text ?? ''
              };
              return bt;
            });
            this.applyPlanTasks(fallbackTasks);
          }
          this.statusLevel = 'speaking';
          this.statusText = '已为您执行多任务编排';
        }
      }
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : '指令执行失败';
      this.statusLevel = 'error';
      this.statusText = '处理失败';
      AccessibilityUtils.getInstance().speak(msg);
    } finally {
      this.endProcessing();
      this.scrollHistoryToEnd();
    }
  }

  private async onVoicePressStart(): Promise<void> {
    if (this.isProcessing || this.isVoiceHolding) {
      return;
    }

    // 华为合规要求：按需申请麦克风权限
    const hasMic: boolean = await PermissionUtil.hasPermission('ohos.permission.MICROPHONE');
    if (!hasMic) {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const granted: Array<Permissions> = await PermissionUtil.requestPermissions(ctx, ['ohos.permission.MICROPHONE']);
      if (granted.indexOf('ohos.permission.MICROPHONE') < 0) {
        this.statusLevel = 'error';
        this.statusText = '未授予麦克风权限';
        AccessibilityUtils.getInstance().speak('未授予麦克风权限，无法使用语音功能。请在系统设置中开启。');
        return;
      }
    }

    if (!this.isOnline) {
      this.vibrateShort();
      this.statusLevel = 'idle';
      this.statusText = '离线模式 · 请在下方输入指令或点击卡片';
      AccessibilityUtils.getInstance().speak('当前处于离线模式，语音识别需要网络。您可以直接在下方输入指令，或点击功能卡片。');
      return;
    }
    this.isVoiceHolding = true;
    this.beginProcessing();
    this.statusLevel = 'listening';
    this.statusText = '正在聆听…松开结束';
    this.vibrateShort();

    const callbacks: VoiceInputCallbacks = {
      onStateChange: (state: VoiceInputState): void => {
        if (state === 'listening') {
          this.statusLevel = 'listening';
          this.statusText = '正在聆听…松开结束';
        } else if (state === 'processing') {
          this.statusLevel = 'thinking';
          this.statusText = '正在理解指令…';
        } else if (state === 'done') {
          this.statusLevel = 'idle';
          this.endProcessing();
          this.isVoiceHolding = false;
        }
      },
      onPartialResult: (partial: string): void => {
        if (partial.length > 0) {
          this.statusText = partial;
        }
      },
      onError: (msg: string): void => {
        const isNetError: boolean = !this.isOnline ||
          msg.indexOf('离线') >= 0 ||
          msg.indexOf('网络') >= 0 ||
          msg.indexOf('network') >= 0 ||
          msg.indexOf('连接失败') >= 0 ||
          msg.indexOf('超时') >= 0 ||
          msg.indexOf('2300006') >= 0;

        if (isNetError) {
          this.isOnline = false;
          this.statusLevel = 'idle';
          this.statusText = '离线模式 · 请在下方输入指令或点击卡片';
          AccessibilityUtils.getInstance().speak('当前处于离线模式，语音识别暂不可用。您可以在下方直接输入文字指令，或者点击卡片使用。');
        } else {
          this.statusLevel = 'error';
          this.statusText = msg;
        }
        this.endProcessing();
        this.isVoiceHolding = false;
      },
      onPlanReady: (tasks: Array<BackendTask>): void => {
        // 规划一出来就把【任务拆解 Task List】卡片上屏（待执行态），
        // 之后每个任务开始/完成时由进度回调实时改状态，形成"双任务实时打勾"
        this.applyPlanTasks(tasks);
        this.statusLevel = 'thinking';
        this.statusText = '任务拆解完成，正在执行…';
      },
      onPlanDone: (userText: string, assistantText: string, tasks?: Array<BackendTask>): void => {
        const userItem: ChatHistoryItem = { role: 'user', text: userText.trim() };
        const assistantItem: ChatHistoryItem = { role: 'assistant', text: assistantText };
        this.history = this.history.concat(userItem, assistantItem);
        this.scrollHistoryToEnd();

        if (tasks && tasks.length > 0) {
          // 卡片已在 onPlanReady 上屏并随进度更新，这里只做兜底补齐
          if (this.taskList.length === 0) {
            this.applyPlanTasks(tasks);
          }
          this.activeViewMode = 'tasklist';
          this.statusLevel = 'speaking';
          this.statusText = '已为您执行多任务编排';
        } else {
          this.statusLevel = 'speaking';
          this.statusText = '指令已执行';
        }
        this.endProcessing();
        this.isVoiceHolding = false;
      }
    };
    this.voiceCtrl.start(callbacks);
  }

  private onVoicePressEnd(): void {
    if (!this.isVoiceHolding) {
      return;
    }
    if (!this.isOnline) {
      this.isVoiceHolding = false;
      return;
    }
    this.statusText = '正在解析语音…';
    this.voiceCtrl.stop();
  }

  private scrollHistoryToEnd(): void {
    setTimeout(() => {
      this.listScroller.scrollEdge(Edge.Bottom);
    }, 80);
  }

  private async vibrateShort(): Promise<void> {
    try {
      vibrator.startVibration({ type: 'time', duration: 150 }, { id: 0, usage: 'touch' });
    } catch (e) {
      Logger.warn(TAG, `振动失败: ${JSON.stringify(e)}`);
    }
  }

  private waitMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  build() {
    Stack() {
      Column() {
        // 1. 顶部 Header 与 StatusBanner
        Row({ space: 10 }) {
          Button('设置')
            .width(72)
            .height(40)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#E6F8F1')
            .border({ width: 1, color: '#BFE9D8' })
            .fontColor('#04785C')
            .borderRadius(12)
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' });
            })

          StatusBanner({
            text: this.statusText,
            level: this.statusLevel,
            isOnline: this.isOnline
          })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        // 2. 主区动态内容（首页/药品/物品/文档/多任务）
        Scroll(this.listScroller) {
          Column({ space: 16 }) {

            // 模式 1：首页默认视图 (Screen 01)
            if (this.activeViewMode === 'home') {
              // 问候头部
              Row() {
                Column({ space: 4 }) {
                  Text('下午好，王阿姨 🌿')
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('光线充足 · 语音优先模式')
                    .fontSize(12)
                    .fontColor('#8AA09A')
                }
                .alignItems(HorizontalAlign.Start)

                Text('云端在线')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#04785C')
                  .backgroundColor('#E6F8F1')
                  .border({ width: 1, color: '#BFE9D8' })
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(12)
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)

              // Hero 药品识别大卡
              Column({ space: 10 }) {
                Text('MEDICINE SCAN')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
                  .opacity(0.85)

                Text('药品识别')
                  .fontSize(26)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')

                Text('拍一张药盒照片，立即告诉您\n药名、怎么吃、有什么禁忌')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .opacity(0.92)
                  .lineHeight(20)

                Row({ space: 8 }) {
                  Text('相机')
                    .fontSize(14)
                  Text('拍摄药盒')
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#04785C')
                }
                .padding({ left: 18, right: 18, top: 10, bottom: 10 })
                .backgroundColor('#FFFFFF')
                .borderRadius(20)
                .margin({ top: 6 })

                Row() {
                  Text('敲 3 下屏幕，随时唤起')
                    .fontSize(11)
                    .fontColor('#FFFFFF')
                    .opacity(0.9)
                }
                .alignSelf(ItemAlign.End)
              }
              .width('100%')
              .padding(20)
              .borderRadius(26)
              .backgroundColor('#10B981')
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.startScanFlow('medicine');
              })

              // 三宫格功能卡片
              Row({ space: 12 }) {
                // 物品识别
                Column({ space: 6 }) {
                  Stack() {
                    Text('🔍')
                      .fontSize(24)
                  }
                  .width(46)
                  .height(46)
                  .borderRadius(14)
                  .backgroundColor('#E5F5F3')

                  Text('物品识别')
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('这是什么')
                    .fontSize(11)
                    .fontColor('#8AA09A')
                }
                .layoutWeight(1)
                .padding(14)
                .backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(18)
                .onClick(() => {
                  this.startScanFlow('object');
                })

                // 文档朗读
                Column({ space: 6 }) {
                  Stack() {
                    Text('📖')
                      .fontSize(24)
                  }
                  .width(46)
                  .height(46)
                  .borderRadius(14)
                  .backgroundColor('#E6F8F1')

                  Text('文档朗读')
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('读给您听')
                    .fontSize(11)
                    .fontColor('#8AA09A')
                }
                .layoutWeight(1)
                .padding(14)
                .backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(18)
                .onClick(() => {
                  this.startScanFlow('document');
                })

                // 语音助手
                Column({ space: 6 }) {
                  Stack() {
                    Text('🎙️')
                      .fontSize(24)
                  }
                  .width(46)
                  .height(46)
                  .borderRadius(14)
                  .backgroundColor('#FDEEF1')

                  Text('语音助手')
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('说句话就行')
                    .fontSize(11)
                    .fontColor('#8AA09A')
                }
                .layoutWeight(1)
                .padding(14)
                .backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(18)
                .onClick(() => {
                  this.onVoicePressStart();
                })
              }
              .width('100%')

              // 快捷手势常驻条
              Row({ space: 8 }) {
                Text('敲3下')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0F766E')
                  .backgroundColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                Text('药品识别 · ')
                  .fontSize(12)
                  .fontColor('#0F766E')

                Text('敲2下')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0F766E')
                  .backgroundColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                Text('物品识别 · ')
                  .fontSize(12)
                  .fontColor('#0F766E')

                Text('长按1秒')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#0F766E')
                  .backgroundColor('#FFFFFF')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                Text('语音助手')
                  .fontSize(12)
                  .fontColor('#0F766E')
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#E5F5F3')
              .border({ width: 1, color: '#C9ECE8', style: BorderStyle.Dashed })
              .borderRadius(12)
            }

            // 模式 2：药品识别结果 (Screen 03)
            if (this.activeViewMode === 'medicine' && this.medicineInfo !== null) {
              MedicineInfoCard({
                medicineName: this.medicineName,
                info: this.medicineInfo,
                onAskClick: (q: string) => {
                  this.processUserCommand(q);
                }
              })
            }

            // 模式 3：物品识别结果 (Screen 04)
            if (this.activeViewMode === 'object') {
              Column({ space: 14 }) {
                Row() {
                  Text('物品识别结果')
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#182925')
                  Text('已识别')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#04785C')
                    .backgroundColor('#E6F8F1')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(10)
                }
                .width('100%')
                .justifyContent(FlexAlign.SpaceBetween)

                Column({ space: 12 }) {
                  Row({ space: 10 }) {
                    Text('是什么')
                      .fontSize(12)
                      .fontColor('#8AA09A')
                      .width(60)
                    Text(this.objectName)
                      .fontSize(16)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#0D9488')
                      .layoutWeight(1)
                  }
                  Row({ space: 10 }) {
                    Text('在哪里')
                      .fontSize(12)
                      .fontColor('#8AA09A')
                      .width(60)
                    Text(this.objectLocation)
                      .fontSize(15)
                      .fontColor('#182925')
                      .layoutWeight(1)
                  }
                  Row({ space: 10 }) {
                    Text('小提示')
                      .fontSize(12)
                      .fontColor('#8AA09A')
                      .width(60)
                    Text(this.objectTip.length > 0 ? this.objectTip : '物体状态稳定，可放心伸手拿取')
                      .fontSize(14)
                      .fontColor('#48605A')
                      .layoutWeight(1)
                  }
                }
                .width('100%')
                .padding(14)
                .backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#E2ECE7' })
                .borderRadius(16)

                if (this.isOfflineDegraded) {
                  Row({ space: 8 }) {
                    Text('⚠️')
                    Text('当前为离线模式：联网后可获取更详细的物理描述与精准定位。')
                      .fontSize(12)
                      .fontColor('#8A6100')
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding(12)
                  .backgroundColor('#FFF6E5')
                  .border({ width: 1, color: '#F4DFB0' })
                  .borderRadius(12)
                }
              }
              .width('100%')
            }

            // 模式 4：文档朗读 (Screen 05)
            if (this.activeViewMode === 'document') {
              DocumentReaderCard({
                title: this.documentTitle,
                paragraphs: this.documentParagraphs
              })
            }

            // 模式 5：多任务拆解 (Screen 06)
            if (this.activeViewMode === 'tasklist') {
              TaskListView({
                tasks: this.taskList
              })
            }

            // 历史对话气泡流
            ForEach(this.history, (item: ChatHistoryItem, index: number) => {
              ConversationBubble({
                role: item.role === 'assistant' ? 'assistant' : 'user',
                text: item.text,
                imageBase64: item.imageBase64 ?? ''
              })
            }, (item: ChatHistoryItem, index: number) => `${index}_${item.role}_${item.text.length}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
        }
        .layoutWeight(1)
        .width('100%')

        // 3. 底部悬浮语音球与交互区 (Voice Dock)
        Column({ space: 8 }) {
          // 语音球主入口
          Stack() {
            Button()
              .width(76)
              .height(76)
              .borderRadius(38)
              .backgroundColor('#0D9488')
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.onVoicePressStart();
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  this.onVoicePressEnd();
                }
              })

            Text('🎙️')
              .fontSize(32)
              .hitTestBehavior(HitTestMode.None)
          }
          .width(88)
          .height(88)
          .alignContent(Alignment.Center)

          Text('按住说话下指令，随时唤起')
            .fontSize(11)
            .fontColor('#8AA09A')

          // 文本输入兜底区
          Row({ space: 8 }) {
            TextInput({ text: this.inputText, placeholder: '或输入指令，如：打给女儿' })
              .layoutWeight(1)
              .height(44)
              .fontSize(14)
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#C6E8E1' })
              .borderRadius(22)
              .padding({ left: 16, right: 12 })
              .onChange((v: string) => {
                this.inputText = v;
              })
              .onSubmit(() => {
                const t = this.inputText.trim();
                this.inputText = '';
                this.processUserCommand(t);
              })

            Button('发送')
              .width(64)
              .height(44)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#0D9488')
              .fontColor('#FFFFFF')
              .borderRadius(22)
              .onClick(() => {
                const t = this.inputText.trim();
                this.inputText = '';
                this.processUserCommand(t);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        }
        .width('100%')
        .backgroundColor('#F6FAF8')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#EEF6F1')
      .onTouch((event: TouchEvent) => {
        // 全屏监听手势服务
        this.gestureService.handleTouchEvent(event);
      })

      // 全屏相机取景浮层 (Screen 02)
      if (this.showCameraPreview) {
        CameraPreviewOverlay({
          hintText: this.cameraHintText,
          showCaptureButton: this.showCaptureButton,
          previewAspectRatio: this.cameraPreviewAspectRatio,
          onSurfaceReady: (surfaceId: string): void => {
            this.handleCameraSurfaceReady(surfaceId);
          },
          onCaptureTap: (): void => {
            this.handleCameraCaptureTap();
          },
          onCancel: (): void => {
            this.closeCameraPreview();
          }
        })
      }

      // 首次启动合规授权弹窗（工信部与华为应用市场隐私规范）
      PrivacyDialog({
        isVisible: this.showPrivacyDialog,
        onAgree: (): void => {
          this.handlePrivacyAgree();
        },
        onDisagree: (): void => {
          this.handlePrivacyDisagree();
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
