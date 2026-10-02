<#
.SYNOPSIS
  下载模型转换所需的原始权重文件（Windows 侧执行）。
.DESCRIPTION
  下载内容（输出到 build/model_workspace/）：
  1. Qwen2-0.5B-Instruct 原始权重（HF 镜像，约 1GB）
     - 用于 WSL 侧 qwen-mindspore-lite-llm 管线导出 .ms
  2. PaddleOCR PP-OCRv3 slim 推理模型（检测 + 识别，各约 10MB）
     - 用于 WSL 侧 paddle2onnx -> converter_lite 转 .ms

  转换步骤见 scripts/convert_models.sh（在 WSL 中执行）。
.NOTES
  powershell -ExecutionPolicy Bypass -File scripts/get_model_weights.ps1
#>

param(
    # 工作区目录（build/ 已被 .gitignore 忽略）
    [string]$Workspace = (Join-Path (Split-Path -Parent $PSScriptRoot) "build\model_workspace")
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path $Workspace -Force | Out-Null

function Download-File {
    param([string]$Name, [string]$Url, [long]$MinBytes, [string]$Dest)
    if (Test-Path $Dest) {
        $size = (Get-Item $Dest).Length
        if ($size -ge $MinBytes) {
            Write-Host ("[SKIP] {0} exists ({1:N1} MB)" -f $Name, ($size / 1MB)) -ForegroundColor Yellow
            return
        }
        Remove-Item $Dest -Force
    }
    Write-Host ("Downloading {0} ..." -f $Name) -ForegroundColor Cyan
    $tmp = "$Dest.download"
    # PowerShell 5.1 的 Invoke-WebRequest 不支持 308 重定向（hf-mirror -> CDN LFS），
    # 因此统一使用系统自带 curl.exe 跟随重定向下载；
    # -C - 支持断点续传，网络中断（如代理重置连接）后重跑自动续传
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        & curl.exe -sSL --retry 3 --retry-delay 2 --connect-timeout 30 -C - -o $tmp $Url
        if ($LASTEXITCODE -eq 0) {
            break
        }
        Write-Host ("curl exit {0} (attempt {1}/{2})，10s 后断点续传..." -f $LASTEXITCODE, $attempt, $maxAttempts) -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) {
        throw ("curl failed with exit code {0} after {1} attempts（保留 .download 断点，重跑本脚本可续传）" -f $LASTEXITCODE, $maxAttempts)
    }
    $size = (Get-Item $tmp).Length
    if ($size -lt $MinBytes) {
        Remove-Item $tmp -Force
        throw ("{0} incomplete: {1:N2} MB" -f $Name, ($size / 1MB))
    }
    Move-Item $tmp $Dest -Force
    Write-Host ("[OK] {0} ({1:N1} MB)" -f $Name, ($size / 1MB)) -ForegroundColor Green
}

$ok = 0; $fail = 0
function Step {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:ok++ }
    catch {
        Write-Host ("[FAIL] {0} : {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}

# ---------------------------------------------------------------
# 1. Qwen2-0.5B-Instruct（HF 镜像 hf-mirror.com，国内可达）
# ---------------------------------------------------------------
$qwenDir = Join-Path $Workspace "Qwen2-0.5B-Instruct"
New-Item -ItemType Directory -Path $qwenDir -Force | Out-Null
$qwenBase = "https://hf-mirror.com/Qwen/Qwen2-0.5B-Instruct/resolve/main"

Step "Qwen2-0.5B model.safetensors (~988MB)" {
    Download-File -Name "model.safetensors" -MinBytes 900MB `
        -Url "$qwenBase/model.safetensors" -Dest (Join-Path $qwenDir "model.safetensors")
}
foreach ($f in @("config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt")) {
    Step "Qwen2-0.5B $f" {
        Download-File -Name $f -MinBytes 1KB `
            -Url "$qwenBase/$f" -Dest (Join-Path $qwenDir $f)
    }
}

# tokenizer 小文件同步拷贝到 rawfile/models（应用端 QwenTokenizer 运行时需要）
$rawModels = Join-Path (Split-Path -Parent $PSScriptRoot) "entry\src\main\resources\rawfile\models"
if (-not (Test-Path $rawModels)) { New-Item -ItemType Directory -Path $rawModels -Force | Out-Null }
foreach ($pair in @(@("vocab.json", "qwen_vocab.json"), @("merges.txt", "qwen_merges.txt"))) {
    $src = Join-Path $qwenDir $pair[0]
    $dst = Join-Path $rawModels $pair[1]
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host ("[COPY] {0} -> {1}" -f $pair[0], $pair[1]) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------
# 2. PaddleOCR PP-OCRv3 标准 FP32 推理模型（官方 BOS 源）
#    注意：不用 slim 量化版——其 fake_channel_wise_quantize_dequantize_abs_max
#    等量化算子 paddle2onnx 不支持，转换会 abort；FP32 版由 converter_lite
#    在端侧转换时做训练后权重量化（见 convert_models.sh quant8.cfg）
# ---------------------------------------------------------------
Step "PP-OCRv3 det FP32 (~4MB)" {
    $tar = Join-Path $Workspace "ch_PP-OCRv3_det_infer.tar"
    Download-File -Name "ch_PP-OCRv3_det_infer.tar" -MinBytes 1MB `
        -Url "https://paddleocr.bj.bcebos.com/PP-OCRv3/chinese/ch_PP-OCRv3_det_infer.tar" -Dest $tar
    $dest = Join-Path $Workspace "ch_PP-OCRv3_det_infer"
    if (-not (Test-Path $dest)) { tar -xzf $tar -C $Workspace }
}
Step "PP-OCRv3 rec FP32 (~11MB)" {
    $tar = Join-Path $Workspace "ch_PP-OCRv3_rec_infer.tar"
    Download-File -Name "ch_PP-OCRv3_rec_infer.tar" -MinBytes 5MB `
        -Url "https://paddleocr.bj.bcebos.com/PP-OCRv3/chinese/ch_PP-OCRv3_rec_infer.tar" -Dest $tar
    $dest = Join-Path $Workspace "ch_PP-OCRv3_rec_infer"
    if (-not (Test-Path $dest)) { tar -xzf $tar -C $Workspace }
}
# 识别字符表（CRNN CTC 解码必需，index 0 = blank）
Step "ppocr_keys_v1.txt (~100KB)" {
    Download-File -Name "ppocr_keys_v1.txt" -MinBytes 50KB `
        -Url "https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/ppocr/utils/ppocr_keys_v1.txt" `
        -Dest (Join-Path $Workspace "ppocr_keys_v1.txt")
    # 同步拷贝到 rawfile/models（应用端 LocalOCREngine 运行时需要）
    $dst = Join-Path $rawModels "ppocr_keys_v1.txt"
    if (Test-Path (Join-Path $Workspace "ppocr_keys_v1.txt")) {
        Copy-Item (Join-Path $Workspace "ppocr_keys_v1.txt") $dst -Force
        Write-Host "[COPY] ppocr_keys_v1.txt -> rawfile/models" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
Write-Host "`n=== model_workspace 内容 ===" -ForegroundColor Cyan
Get-ChildItem $Workspace -Recurse -File | ForEach-Object {
    Write-Host ("  {0,-50} {1,10:N1} MB" -f $_.FullName.Substring($Workspace.Length + 1), ($_.Length / 1MB))
}
Write-Host ("`nOK: {0}  FAIL: {1}" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host "存在下载失败项，请重跑本脚本（已下载文件会自动跳过）" -ForegroundColor Yellow
    exit 1
}
Write-Host "`n下一步：在 WSL 中执行  bash scripts/convert_models.sh" -ForegroundColor Green
