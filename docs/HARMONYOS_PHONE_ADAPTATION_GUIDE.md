# HarmonyOS 手机端代码适配与规范指南（全流程避坑手册）

> **适用版本**：HarmonyOS NEXT (API 12+ / OpenHarmony 5.0+)  
> **面向对象**：AI 编码助手、前端/全栈转鸿蒙开发者、工程维护者  
> **核心目标**：从语法、UI、权限、导包到真机签名，彻底根除“代码在鸿蒙手机上无法运行、报错或界面错乱”的问题，确保后续生成的每一行代码**直接适配鸿蒙真机**。

---

## 一、为什么过去的代码总是无法适配鸿蒙手机？（5 大根因剖析）

在实际开发中，导致代码无法在鸿蒙手机上运行的根本原因并非单一问题，而是**语言、框架、系统权限、屏幕形态和安装机制**五个维度的叠加冲突：

| 维度 | 常见典型报错 / 表现 | 根本原因 |
|---|---|---|
| **1. 语言语法** | `arkts-no-any`<br>`arkts-no-props-by-index`<br>`arkts-no-spread`<br>数十甚至上百个 TS 编译报错 | **ArkTS 绝非普通 TypeScript**。为了获得极致性能和内存确定性，ArkTS 禁用了大量的 JS/TS 动态特性（禁止 `any`、禁止对象展开、禁止动态属性索引、禁止原型链操作等）。传统按前端/Node 习惯编写的代码会被编译器全盘拦截。 |
| **2. 模块导包** | `Cannot find module '@ohos.xxx'`<br>API 废弃告警或符号丢失 | **HarmonyOS NEXT 全面推行 Kit 化**。老旧文档或旧版工程常使用 `@ohos.*`，而纯血鸿蒙统一改为 `@kit.*`（如 `@kit.ArkUI`、`@kit.AbilityKit`），且大量旧 API 在 API 12+ 中被重构或废弃。 |
| **3. 屏幕与安全区** | 顶部内容被挖孔/状态栏遮挡<br>底部按键被系统手势横条遮盖或误触<br>折叠屏展开后排版拉伸变形 | **未做视口单位统一与避让区适配**。写死物理 `px`、未处理系统避让区（AvoidArea）、未正确配置 `expandSafeArea`、依旧使用已废弃的单页 `router` 而非多端自适应的 `Navigation` 组件。 |
| **4. 权限与硬件** | 点击拍照/录音/定位应用无响应甚至闪退<br>`BusinessError: permission denied` | **缺少动态运行时授权**。在鸿蒙手机上，相机、麦克风等高危权限仅在 `module.json5` 中声明是完全无效的，必须在业务执行前调用 `abilityAccessCtrl` 弹出系统授权框，且必须包含降级处理。 |
| **5. 真机安装与签名** | `INSTALL_FAILED_VERIFY_FAILURE`<br>`SDK component missing` | **鸿蒙真机严苛的证书与 UDID 绑定机制**。纯血鸿蒙手机完全杜绝安装无签名或未绑定设备 UDID 的 HAP。此外，`build-profile.json5` 的 SDK 版本与真机系统版本错位时，底层包管理器会直接拒装。 |

---

## 二、官方核心规范与代码红线

### 2.1 ArkTS 语法红线（严格静态类型与性能约束）

在编写 `.ets` 代码时，**必须 100% 遵守以下规则，违者无法通过 DevEco Studio 编译**：

#### ❌ 红线 1：严禁使用 `any` 或 `as unknown as T`
```typescript
// ❌ 错误写法
let data: any = JSON.parse(str);
let count = (someVar as unknown) as number;

// ✅ 正确写法：显式声明接口或具体类型
interface ResponseData {
  code: number;
  message: string;
}
let data: ResponseData = JSON.parse(str) as ResponseData;
let count: number = Number(someVar);
```

#### ❌ 红线 2：严禁通过动态字符串索引访问对象属性（`arkts-no-props-by-index`）
```typescript
// ❌ 错误写法
let val = obj["someKey"];
for (let key in obj) { ... }

// ✅ 正确写法：定义强类型 Class/Interface 使用点号访问，或使用 Map / Record
// 方式 A：点号访问已知属性
interface UserInfo {
  name: string;
  age: number;
}
let name = userInfo.name;

// 方式 B：动态键值对必须声明为 Record<string, T> 或 Map
let dict: Record<string, string> = { "key1": "val1" };
let val = dict["key1"]; // Record 允许合法索引

let map = new Map<string, string>();
map.set("key", "val");
let result = map.get("key");
```

#### ❌ 红线 3：严禁使用对象扩展运算符进行浅拷贝合并（`arkts-no-spread`）
```typescript
// ❌ 错误写法
let newObj = { ...oldObj, extra: "value" };

// ✅ 正确写法：显式赋值、工厂方法或构造函数
class Config {
  host: string = "";
  port: number = 80;
  extra: string = "";

  static cloneWithExtra(base: Config, extra: string): Config {
    let target = new Config();
    target.host = base.host;
    target.port = base.port;
    target.extra = extra;
    return target;
  }
}
```

#### ❌ 红线 4：禁止在 `struct` 中声明普通 constructor
ArkUI 的组件由框架管理生命周期，结构体内部不允许声明构造函数：
```typescript
// ❌ 错误写法
@Component
struct MyCard {
  constructor() { } // 编译报错！
}

// ✅ 正确写法：使用生命周期钩子
@Component
struct MyCard {
  @Prop title: string = '';

  aboutToAppear(): void {
    // 初始化逻辑放这里
  }

  build() {
    Column() {
      Text(this.title)
    }
  }
}
```

---

### 2.2 HarmonyOS NEXT 统一 Kit 导包标准

在 HarmonyOS NEXT 中，废弃旧版分散的 `@ohos.*`，全面采用 Kit 化模块包：

| 模块类别 | 推荐 Kit 导入方式（NEXT 推荐） | 旧版遗留写法（避免使用） |
|---|---|---|
| **UI 与组件** | `import { promptAction } from '@kit.ArkUI';` | `@ohos.promptAction` |
| **基础应用能力** | `import { common, Want, AbilityConstant } from '@kit.AbilityKit';` | `@ohos.app.ability.*` |
| **系统异常处理** | `import { BusinessError } from '@kit.BasicServicesKit';` | `@ohos.base` |
| **多媒体音频** | `import { audio } from '@kit.AudioKit';` | `@ohos.multimedia.audio` |
| **多媒体相机** | `import { camera } from '@kit.CameraKit';` | `@ohos.multimedia.camera` |
| **图像与 PixelMap** | `import { image } from '@kit.ImageKit';` | `@ohos.multimedia.image` |
| **AI 与端侧推理** | `import { mindSporeLite } from '@kit.MindSporeLiteKit';` | `@ohos.ai.mindSporeLite` |
| **窗口与安全区** | `import { window } from '@kit.ArkUI';` | `@ohos.window` |
| **网络请求** | `import { http } from '@kit.NetworkKit';` | `@ohos.net.http` |
| **权限控制** | `import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';` | `@ohos.abilityAccessCtrl` |

---

### 2.3 手机端屏幕与安全区（避让区）适配标准

鸿蒙手机具有**挖孔屏、圆角、状态栏、手势导航栏（Home Indicator）**。必须确保内容不被遮挡。

#### 1. 严格使用 `vp` 与 `fp`
* 长度、宽高、边距、圆角：**一律使用 `vp`**（直接写数值如 `24`、`16` 默认为 vp）或百分比（`'100%'`）。
* 字体大小：**一律使用 `fp`**（如 `16` 默认为 fp）。
* **严禁写死 `px`**：不同机型屏幕像素密度（DPI）差异巨大，写死 px 会导致小屏手机放不下、高分屏手机极小。

#### 2. 沉浸式与安全区扩展（`expandSafeArea`）
为了让应用具有现代沉浸式视觉，同时核心内容不被挖孔和导航条遮挡：
```typescript
@Entry
@Component
struct MainPage {
  build() {
    Column() {
      // 1. 状态栏顶部安全垫（或自定义导航头）
      // 2. 业务内容主体（置于安全区域内）
      Scroll() {
        Column({ space: 16 }) {
          Text("主标题")
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          // 业务控件...
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      .layoutWeight(1)

      // 3. 底部主要操作按钮区（避开底部手势导航条）
      Button("立即开始")
        .width('90%')
        .height(48)
        .margin({ bottom: 16 })
    }
    .width('100%')
    .height('100%')
    // 沉浸式背景延伸至状态栏与导航栏，但子元素受布局 padding 保护
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
```

#### 3. 页面路由采用 `Navigation` 替代已废弃的 `router`
官方在 HarmonyOS NEXT 中推荐使用 `Navigation` 架构，直板手机自动单栏展示，折叠屏展开或平板自动分栏，无需手动针对不同设备重写页面逻辑。

---

### 2.4 手机硬件权限的动态申请标准

在手机上调用敏感权限（相机、麦克风、位置、媒体等）必须采用“静态声明 + 动态申请”两步法。

#### 第一步：`entry/src/main/module.json5` 声明
```json5
"requestPermissions": [
  {
    "name": "ohos.permission.CAMERA",
    "reason": "$string:perm_camera_reason",
    "usedScene": {
      "abilities": ["EntryAbility"],
      "when": "inuse"
    }
  },
  {
    "name": "ohos.permission.MICROPHONE",
    "reason": "$string:perm_microphone_reason",
    "usedScene": {
      "abilities": ["EntryAbility"],
      "when": "inuse"
    }
  }
]
```

#### 第二步：ArkTS 动态申请封装（即抄即用模板）
```typescript
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class PermissionManager {
  /**
   * 申请手机硬件权限
   * @param context UIAbilityContext 上下文
   * @param permissions 需要申请的权限列表
   */
  public static async requestPermissions(
    context: common.UIAbilityContext,
    permissions: Array<Permissions>
  ): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const grantResult = await atManager.requestPermissionsFromUser(context, permissions);
      // 校验每个权限是否全部授权 (0 代表 PERMISSION_GRANTED)
      for (let i = 0; i < grantResult.authResults.length; i++) {
        if (grantResult.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[Permission] Request failed: code=${error.code}, msg=${error.message}`);
      return false;
    }
  }
}
```

---

### 2.5 手机真机签名与安装屏障解决

很多时候“代码没问题但在手机上就是跑不起来”，是因为真机未正确签名或版本错配。

#### 1. 版本一致性原则（`build-profile.json5`）
```json5
"products": [
  {
    "name": "default",
    "signingConfig": "default",
    "compileSdkVersion": "6.1.1(24)",  // 必须与本地已安装的 SDK 严格一致
    "compatibleSdkVersion": "5.0.0(12)", // 必须小于或等于真机系统版本
    "targetSdkVersion": "6.1.1(24)",
    "runtimeOS": "HarmonyOS"
  }
]
```
> **注意**：如果手机系统版本低于 `compatibleSdkVersion`，手机会直接拒绝安装。

#### 2. 真机自动签名流程（必须在 DevEco Studio 中绑定 UDID）
1. 鸿蒙手机用 USB 连接电脑，手机开启 `设置 > 开发人员选项 > USB 调试`。
2. 打开 DevEco Studio：`File > Project Structure > Project > Signing Configs`。
3. 勾选 **`Automatically generate signature`**。
4. 登录华为开发者账号，DevEco 会自动获取已连手机的 UDID，并在华为云端生成绑定该手机的调试证书（`.cer`）与 Profile（`.p7b`），自动写入工程配置。
5. 签名成功后，点击绿色 ▶ Run 按钮，HAP 包即可顺利推送到真机手机并直接运行。

---

## 三、保证以后代码“立即适配鸿蒙手机”的执行清单（Checklist）

以后凡是为本项目生成或修改鸿蒙端侧代码，必须逐条过目以下 Checklist：

- [ ] **1. 零语法红线**：代码中无 `any`、无未受约束的类型断言、无对象动态字符串键访问（`obj[key]`，除非为明确的 Record）、无对象展开运算符（`{...obj}`）。
- [ ] **2. 统一 Kit 导包**：全面使用 `@kit.*` 导入官方能力，无失效或遗留的 `@ohos.*` 导入。
- [ ] **3. 屏幕与单位适配**：尺寸无裸 `px`，全部使用 `vp`/`fp`/百分比；页面容器配置了安全区避让（`expandSafeArea`），防止内容撞进手机挖孔区或底部导航条。
- [ ] **4. 权限与容错兜底**：调用相机、录音、定位等硬件功能前，均有动态权限检查与优雅降级提示，避免硬件未授权崩溃。
- [ ] **5. 异步调用全防护**：所有异步 Promise 与系统 API 调用均包裹 `try-catch`，并捕获 `BusinessError` 输出结构化日志，保证应用在离线或异常状态下不会闪退。
- [ ] **6. 架构与路由**：新组件与页面优先适配 `Navigation` 导航框架，保证从直板机到折叠屏均能无缝排版。
