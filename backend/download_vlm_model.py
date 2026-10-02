"""从 ModelScope 下载 Qwen2-VL-2B-Instruct 到 backend/models/（仅部署工具，非运行时依赖）。"""
import sys
from modelscope import snapshot_download

local_dir = r"D:\LuminaAssist_main\LuminaAssist-main\backend\models\qwen2-vl-2b-instruct"
path = snapshot_download("Qwen/Qwen2-VL-2B-Instruct", local_dir=local_dir)
print("DONE:", path)
sys.exit(0)
