# 鸿蒙开发环境从 0 搭建指南

> 适用对象：第一次接触 OpenHarmony 5.0 / DevEco Studio 的开发者
> 适用平台：Windows 10/11（macOS 见文末"平台差异"）
> 预计耗时：首次 30-60 分钟（取决于网络速度）

---

## 一、你需要装什么

| 工具 | 用途 | 是否必需 |
|---|---|---|
| **DevEco Studio 5.0+** | 鸿蒙官方 IDE（基于 IntelliJ） | ✅ 必需 |
| **OpenHarmony 5.0 SDK（API 12）** | 编译/运行鸿蒙应用 | ✅ 必需 |
| **Node.js 16 / 18 LTS** | ohpm / hvigor 工具链依赖 | ✅ 必需 |
| **ohpm（鸿蒙包管理）** | 安装 `@ohos/*` 等鸿蒙库 | ✅ 随 DevEco 一起装 |
| **hvigor 5.0+** | 鸿蒙构建工具 | ✅ 随 DevEco 一起装 |
| **Java JDK 17** | hvigor 编译需要 | ✅ 必需 |
| **OpenHarmony 真机或模拟器** | 运行 HAP | ✅ 部署阶段必需 |

> ⚠️ **DevEco Studio 已捆绑 Node.js / ohpm / hvigor / JDK 17**，只需装 IDE 即可，无需单独配置。

---

## 二、装机步骤

### 步骤 1：下载 DevEco Studio

- 官方地址：<https://developer.huawei.com/consumer/cn/deveco-studio/>
- 推荐下载 **5.0.x** 或更新稳定版
- Windows 选 `.exe`，macOS 选 `.dmg`

### 步骤 2：安装 DevEco Studio

一路 Next 即可。**关键选项**：
- 勾选"将 DevEco Studio 添加到 PATH"（命令行用 hvigor 需要）
- 安装位置建议 `C:\Huawei\DevEco Studio`（避免空格和中文路径）

### 步骤 3：首次启动向导

DevEco 首次启动会弹出 `Setup Wizard`：
1. 同意 License Agreement
2. 选择 **OpenHarmony SDK** 安装路径
   - 默认 `C:\Users\你的用户名\AppData\Local\Huawei\DevEco Studio\sdk`
   - **不要改路径里有中文/空格**，否则后续会出怪问题
3. 下载并安装 OpenHarmony 5.0 (API 12) SDK
   - 文件较大（约 3-5 GB），耐心等待
4. 选择 "HarmonyOS / OpenHarmony" 主题色（可选）

### 步骤 4：验证环境

打开 DevEco Studio → `File` → `Settings` → `Build, Execution, Deployment` → `Build Tools` → `OpenHarmony SDK`
- **OpenHarmony SDK location** 框里的路径记下来，下一步要用

### 步骤 5：导入 LuminaApp 工程

1. `File` → `Open` → 选择本仓库的 `LuminaApp/` 目录（**不是根目录**）
2. IDE 自动开始 `ohpm install` + `hvigor sync`，**首次约 5-10 分钟**
3. 等待右下角进度条走完

### 步骤 6：配置 SDK 路径

工程导入后，DevEco 会自动用 IDE 全局 SDK 路径。如果出现 "SDK 路径无效" 报错：

1. 复制 [LuminaApp/local.properties.template](file:///d:/c4.ai.huawei/LuminaApp/local.properties.template) 为 `local.properties`
2. 修改 `sdk.dir=` 为步骤 4 中记下的路径
3. DevEco → `File` → `Invalidate Caches` → 重启 IDE

> ⚠️ **重要**：`local.properties` 已被 `.gitignore` 忽略，不要手动 commit。

### 步骤 7：配置签名（部署到真机必需）

1. DevEco → `File` → `Project Structure` → `Project` → `Signing Configs`
2. 勾选 `Automatically generate signature`（自动生成调试签名）
3. 等待 DevEco 自动创建 `.p12` 证书到 `LuminaApp/sign/` 目录
4. **不要把这个 `.p12` 提交到 git**（已在 .gitignore 中）

### 步骤 8：连接设备

**选项 A - 真机**：
1. 鸿蒙手机开启 `设置 → 开发者选项 → USB调试`
2. USB 连接电脑，DevEco 右下角会显示设备名
3. 点击 ▶ Run 即可部署

**选项 B - 模拟器**：
1. DevEco → `Tools` → `Device Manager`
2. 选择 `OpenHarmony 5.0 / Phone` → 下载并启动
3. 启动后右下角出现设备，点击 ▶ Run

---

## 三、命令行构建（可选，CI/无 IDE 环境）

> DevEco Studio 是推荐方式，但部分协作者可能在 Linux 服务器/CI 环境，可走命令行。

### Windows PowerShell
```powershell
# 1. 装 Node.js 18
winget install OpenJS.NodeJS.LTS

# 2. 装 JDK 17
winget install Microsoft.OpenJDK.17

# 3. 装 hvigor（需从 DevEco Studio 解压目录复制 hvigor.exe 到 PATH）
$env:PATH += ";C:\Huawei\DevEco Studio\tools\hvigor\bin"

# 4. 进入工程并构建
cd LuminaApp
hvigorw clean assembleHap --mode module -p product=default
```

### 常见报错对照表

| 报错 | 原因 | 解决 |
|---|---|---|
| `SDK location not found` | `local.properties` 未配 | 复制模板并修改 `sdk.dir=` |
| `ohpm: command not found` | PATH 没配 | 把 DevEco `tools/ohpm/bin` 加入 PATH |
| `hvigor OHPM package not installed` | ohpm 没 sync | 在 LuminaApp 根目录执行 `ohpm install` |
| `Cannot find module '@ohos.app.ability'` | SDK 缺 API 12 组件 | DevEco → SDK Manager → 安装 API 12 |
| `hvigorw: Permission denied`（macOS/Linux） | 文件无执行权限 | `chmod +x hvigorw` |

---

## 四、平台差异

| 项 | Windows | macOS |
|---|---|---|
| SDK 路径 | `C:\Users\xxx\AppData\Local\Huawei\DevEco Studio\sdk` | `/Users/xxx/Library/Huawei/DevEco Studio/sdk` |
| 路径分隔符 | `\` | `/` |
| 真机调试 | USB + 驱动（DevEco 自带） | USB + iOS 类似，信任电脑 |
| hvigor 入口 | `hvigorw.bat` | `hvigorw` |
| 包名大小写 | 不敏感 | 敏感（macOS 默认 APFS） |

> ⚠️ **包名敏感度**：本工程包名 `lumi.na.app` 在 macOS 上必须**严格小写**提交，Windows 上误改大小写提交后 macOS 会认不出。

---

## 五、给协作者的 Checklist

- [ ] DevEco Studio 5.0+ 已安装
- [ ] OpenHarmony 5.0 (API 12) SDK 已下载到本地
- [ ] Node.js 18 LTS / JDK 17 已装
- [ ] `git clone` 本仓库
- [ ] 复制 `LuminaApp/local.properties.template` 为 `LuminaApp/local.properties` 并填入 SDK 路径
- [ ] DevEco → File → Open → 选择 `LuminaApp/`（**不是仓库根目录**）
- [ ] 等待 ohpm + hvigor 自动 sync 完成
- [ ] Project Structure → Signing Configs 启用自动签名
- [ ] Tools → Device Manager 启动真机或模拟器
- [ ] 点击 ▶ Run 部署 HAP 到设备
- [ ] 设置页录入阿里云百炼（DashScope）API Key
- [ ] 点击主按钮测试 TTS 播报"光语助手已就绪"

---

## 六、相关文档

- [LuminaApp/README.md](file:///d:/c4.ai.huawei/LuminaApp/README.md) - 端侧工程说明
- [根 README.md](file:///d:/c4.ai.huawei/README.md) - 项目总览（端云双态架构）
- [backend/README.md](file:///d:/c4.ai.huawei/backend/README.md) - 后端启动指南
- [LuminaApp/docs/architecture.md](file:///d:/c4.ai.huawei/LuminaApp/docs/architecture.md) - 端云双态架构详细设计
- [LuminaApp/docs/api_contract.md](file:///d:/c4.ai.huawei/LuminaApp/docs/api_contract.md) - 端云 API 契约

---

## 七、常见问题

### Q1：模拟器启动后 HAP 装不上，提示"INSTALL_FAILED_VERIFY_FAILURE"
A：检查签名配置是否启用自动生成。Project Structure → Signing Configs → 勾选 Automatically generate signature。

### Q2：构建报"Cannot find type 'Context'" 等红字
A：DevEco 缓存过期。File → Invalidate Caches → 勾选 Clear VCS Log → Just restart。

### Q3：ohpm install 巨慢
A：国内网络环境推荐换 ohpm 镜像源。在用户目录 `~/.ohpm/ohpmrc` 加：
```ini
registry=https://repo.huaweicloud.com/repository/ohpm/
```

### Q4：怎么真机调试
A：开发者选项 → USB调试 → 首次连接手机会弹"是否信任此电脑"，点信任。DevEco 右下角应能看到设备序列号。

### Q5：后端怎么启
A：见 [backend/README.md](file:///d:/c4.ai.huawei/backend/README.md)。后端启在 8000 端口，端侧 `SettingsPage` 配置后端地址。
