#!/bin/bash
# LuminaAssist macOS 安装与运行脚本：等待设备连接 → (可选)卸载旧应用 → 安装新 HAP → 启动应用

HDC_BIN="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
if ! command -v hdc &> /dev/null; then
    if [ -f "$HDC_BIN" ]; then
        HDC="$HDC_BIN"
    else
        echo "错误: 未找到 hdc 工具，请确保安装了 DevEco Studio"
        exit 1
    fi
else
    HDC="hdc"
fi

BUNDLE_NAME="lumi.na.app"
ABILITY_NAME="EntryAbility"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAP_DEFAULT="$SCRIPT_DIR/entry/build/default/outputs/default/entry-default-signed.hap"
HAP="${1:-$HAP_DEFAULT}"

echo "=== 检查鸿蒙设备连接状态 ==="
DEV_ID=""
for i in {1..30}; do
    TARGETS=$($HDC list targets 2>&1)
    if [ -n "$TARGETS" ] && [[ "$TARGETS" != *"[Empty]"* ]] && [[ "$TARGETS" != *"Empty"* ]]; then
        if [[ "$TARGETS" == *"Unauthorized"* ]]; then
            echo "警告: 设备处于未授权状态，请在手机上点击「允许 USB 调试」..."
        else
            DEV_ID=$(echo "$TARGETS" | head -n 1 | awk '{print $1}')
            echo "设备已连接且已授权: $DEV_ID"
            break
        fi
    fi
    sleep 2
done

if [ -z "$DEV_ID" ]; then
    echo "未检测到已授权的设备。请检查："
    echo "  1. 手机屏幕是否解锁"
    echo "  2. USB 连接模式是否为「传输文件」"
    echo "  3. 是否弹出「允许 USB 调试」提示并点击了「允许」"
    exit 1
fi

if [ -f "$HAP" ]; then
    echo -e "\n=== 正在安装 HAP: $HAP ==="
    $HDC -t "$DEV_ID" install "$HAP"
    
    echo -e "\n=== 启动应用 ==="
    $HDC -t "$DEV_ID" shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME"
    echo "完成！"
else
    echo -e "\n提示: 未在默认路径找到已签名的 HAP 文件: $HAP"
    echo "如需安装，请在 DevEco Studio 中先 Build App/Hap，或将 HAP 路径作为参数传入："
    echo "  ./install_hap.sh <path_to_hap>"
fi
