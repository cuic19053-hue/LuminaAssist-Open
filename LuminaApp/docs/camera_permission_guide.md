# 相机与麦克风权限申请指南

> 光语助手鸿蒙端侧应用所需权限的声明与动态申请规范

---

## 一、概述

光语助手作为面向视障与高龄用户的端侧应用，其核心能力依赖以下系统权限：

| 权限 | 用途 | 申请时机 |
| --- | --- | --- |
| `ohos.permission.CAMERA` | 相机采集，用于 OCR 文字识别、目标检测等视觉辅助场景 | 用户触发"拍照识别""读眼前内容"等功能时 |
| `ohos.permission.MICROPHONE` | 麦克风录音，用于采集用户语音指令 | 用户触发"开始语音对话"时 |
| `ohos.permission.INTERNET` | 网络访问，用于调用云端 LLM | 应用启动时（普通权限） |
| `ohos.permission.READ_MEDIA` | 读取媒体文件（可选），用于从相册选取图片进行识别 | 用户触发"从相册选择"时 |
| `ohos.permission.VIBRATE` | 触觉反馈，TTS 不可用时降级提示 | 始终生效 |

其中 **CAMERA 与 MICROPHONE 属于用户授权敏感权限**，必须遵循"按需申请"原则，禁止在应用启动时批量申请。

---

## 二、module.json5 位置说明

本工程的权限声明已写入：

```
LuminaApp/entry/src/main/module.json5
```

开发者无需手动添加。如需调整请修改该文件。

---

## 三、动态申请权限的 ArkTS 代码

工程已封装 `utils/PermissionUtil.ets`，用法：

```typescript
import { PermissionUtil } from '../utils/PermissionUtil';
import { Permissions } from '@ohos.abilityAccessCtrl';

const granted: Permissions[] = await PermissionUtil.requestPermissions(
  this.context,
  ['ohos.permission.CAMERA', 'ohos.permission.MICROPHONE']
);
if (granted.includes('ohos.permission.CAMERA')) {
  // 相机权限已授予
}
```

### 最佳实践

1. **按需申请**：禁止在 `EntryAbility.onCreate` 中批量申请敏感权限；
2. **失败兜底**：权限被拒时通过 TTS 告知用户，并提供"跳转到系统设置"的入口；
3. **复用检查**：进入相关功能前先 `hasPermission()`，避免重复弹窗。

---

## 四、注意事项

- **禁止启动时批量申请敏感权限**：视障用户对"突然弹窗"敏感度高，按需申请更友好。
- **授权失败禁止静默**：必须 TTS 播报失败原因与解决方案。
- **INTERNET 为普通权限**：声明后安装时自动授予，无需动态申请。
- **reason 资源必须存在**：`module.json5` 中 `reason` 字段引用的字符串资源已在 `entry/src/main/resources/base/element/string.json` 中定义。
