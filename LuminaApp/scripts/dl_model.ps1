$ErrorActionPreference = 'Stop'
$dir = 'd:\c4.ai.huawei\LuminaApp\entry\src\main\resources\rawfile\models'
if (-not (Test-Path $dir)) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$modelPath = Join-Path $dir 'mobilenetv2.ms'
$modelUrl = 'https://download.mindspore.cn/model_zoo/official/lite/mobilenetv2_openimage_lite/1.5/mobilenetv2.ms'

Write-Host "Downloading model from $modelUrl"
curl.exe -L -s -o $modelPath $modelUrl
$size = (Get-Item $modelPath).Length
Write-Host "MODEL_SIZE=$size"
if ($size -lt 1000000) {
  Write-Host "MODEL_TOO_SMALL"
  exit 1
}
Write-Host "MODEL_OK"
