<#
.SYNOPSIS
  Download complete on-device model assets for LuminaAssist.
.DESCRIPTION
  Complete local backup set (all downloadable):
  - mobilenetv2.ms (~11MB) — image classify + vision fallback
  - imagenet_labels.json — labels (generated if missing; committed in repo)

  [NEW in 1.5B Upgrade]
  - To upgrade to Qwen2-1.5B INT4, you must manually convert HuggingFace weights
    using MindSpore Lite converter and place 'qwen2_1_5b_int4.ms' in the models directory.
  
  Text planning fallback uses OfflinePlanner (no weight file).
  TTS/ASR use HarmonyOS system engines (no weight file).
.NOTES
  powershell -ExecutionPolicy Bypass -File setup_local_models.ps1
#>

param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$rawfileDir = Join-Path $ProjectRoot "entry\src\main\resources\rawfile\models"

if (-not (Test-Path $rawfileDir)) {
    New-Item -ItemType Directory -Path $rawfileDir -Force | Out-Null
    Write-Host "Created: $rawfileDir" -ForegroundColor Green
}

function Download-File {
    param([string]$Name, [string]$Url, [long]$MinBytes, [string]$Dest)
    if (Test-Path $Dest) {
        $size = (Get-Item $Dest).Length
        if ($size -ge $MinBytes) {
            Write-Host ("[SKIP] {0} exists ({1:N2} MB)" -f $Name, ($size / 1MB)) -ForegroundColor Yellow
            return $true
        }
        Remove-Item $Dest -Force
    }
    Write-Host ("Downloading {0} ..." -f $Name) -ForegroundColor Cyan
    try {
        $tmp = "$Dest.download"
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
        $size = (Get-Item $tmp).Length
        if ($size -lt $MinBytes) {
            Remove-Item $tmp -Force
            throw ("incomplete: {0:N2} MB" -f ($size / 1MB))
        }
        Move-Item $tmp $Dest -Force
        Write-Host ("[OK] {0} ({1:N2} MB)" -f $Name, ($size / 1MB)) -ForegroundColor Green
        return $true
    } catch {
        Write-Host ("[FAIL] {0} : {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        Write-Host ("  URL: {0}" -f $Url) -ForegroundColor Yellow
        return $false
    }
}

$ok = 0
$fail = 0

$mDest = Join-Path $rawfileDir "mobilenetv2.ms"
if (Download-File -Name "mobilenetv2.ms" `
    -Url "https://download.mindspore.cn/model_zoo/official/lite/mobilenetv2_openimage_lite/1.5/mobilenetv2.ms" `
    -MinBytes 10MB -Dest $mDest) { $ok++ } else { $fail++ }

$labels = Join-Path $rawfileDir "imagenet_labels.json"
if (Test-Path $labels) {
    Write-Host "[SKIP] imagenet_labels.json exists" -ForegroundColor Yellow
    $ok++
} else {
    Write-Host "[WARN] imagenet_labels.json missing — run scripts/setup_models.ps1 or restore from git" -ForegroundColor Yellow
    $fail++
}

# Remove obsolete incomplete assets if present (older int8 tests)
foreach ($obsolete in @("qwen2-1.5b-instruct-int8.ms", "minicpm-v-2b-int8.ms", "qwen_tokenizer.json", "minicpm_tokenizer.json")) {
    $p = Join-Path $rawfileDir $obsolete
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host ("[CLEAN] removed obsolete {0}" -f $obsolete) -ForegroundColor Yellow
    }
}

Write-Host "`n[UPGRADE NOTICE]" -ForegroundColor Yellow
Write-Host "This version is configured to use Qwen2-1.5B INT4 (qwen2_1_5b_int4.ms) for SLM Engine." -ForegroundColor Yellow
Write-Host "Please ensure you have generated this file via 'convert_models.sh'!" -ForegroundColor Yellow

Write-Host "`n=== Complete local model set ===" -ForegroundColor Cyan
Get-ChildItem $rawfileDir | ForEach-Object {
    Write-Host ("  {0,-32} {1,12:N1} KB" -f $_.Name, ($_.Length / 1KB))
}
Write-Host "`nCoverage: OfflinePlanner(text) + MobileNetV2(vision) + System TTS/ASR" -ForegroundColor Green
$summaryColor = if ($fail -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ("OK: {0}  FAIL: {1}" -f $ok, $fail) -ForegroundColor $summaryColor
if ($fail -gt 0) { exit 1 }
