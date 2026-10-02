# 安装脚本：等待设备连接 → 卸载旧应用 → 安装新 HAP
$hdc = "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$hap = "d:\HuaWei\LuminaAssist-main\LuminaApp\entry\build\default\outputs\default\entry-default-signed.hap"

Write-Host "=== 等待设备连接（最多 120 秒）===" -ForegroundColor Cyan
$found = $false
for ($i = 0; $i -lt 40; $i++) {
    $devs = & $hdc list targets 2>&1
    if ($devs -ne "[Empty]" -and $devs.Length -gt 0 -and $devs -notlike "*Empty*") {
        $devId = $devs.Trim()
        Write-Host "设备已连接: $devId" -ForegroundColor Green
        $found = $true
        break
    }
    Start-Sleep -Seconds 3
}

if (-not $found) {
    Write-Host "未检测到设备。请在手机上操作：" -ForegroundColor Red
    Write-Host "  1. 唤醒并解锁手机屏幕" -ForegroundColor Yellow
    Write-Host "  2. 下拉通知栏 → 点击 USB 通知 → 选择「传输文件」" -ForegroundColor Yellow
    Write-Host "  3. 如果弹出「允许 USB 调试」对话框，点击「允许」" -ForegroundColor Yellow
    Write-Host "  4. 确认 设置→系统→开发人员选项→USB调试 已开启" -ForegroundColor Yellow
    Write-Host "然后重新运行此脚本" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n=== 卸载旧应用 ===" -ForegroundColor Cyan
& $hdc -t $devId shell bm uninstall -n lumi.na.app 2>&1
Start-Sleep -Seconds 2

Write-Host "`n=== 安装新 HAP ===" -ForegroundColor Cyan
& $hdc -t $devId install $hap 2>&1

Write-Host "`n=== 安装结果 ===" -ForegroundColor Cyan
$installResult = & $hdc -t $devId shell bm dump -n lumi.na.app 2>&1
if ($installResult -like "*lumi.na.app*") {
    Write-Host "安装成功！" -ForegroundColor Green
    Write-Host "现在可以在手机上打开光语助手，点击屏幕测试识别功能" -ForegroundColor Green
} else {
    Write-Host "安装可能失败，请检查上方输出" -ForegroundColor Red
}
