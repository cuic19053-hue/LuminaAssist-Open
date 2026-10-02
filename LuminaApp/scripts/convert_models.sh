#!/usr/bin/env bash
# =============================================================================
# 光语助手 - 模型转换脚本（在 WSL / Linux x86_64 中执行）
#
# 前置条件（Windows 侧已执行）：
#   powershell -ExecutionPolicy Bypass -File scripts/get_model_weights.ps1
#   -> 产物位于 build/model_workspace/
#
# 用法（在 LuminaApp 目录下）：
#   bash scripts/convert_models.sh            # 全部转换
#   bash scripts/convert_models.sh ocr        # 仅转换 PaddleOCR
#   bash scripts/convert_models.sh slm        # 仅转换 Qwen2-0.5B
#
# 产物（自动拷贝到 entry/src/main/resources/rawfile/models/）：
#   qwen2_0_5b_int4.ms          指令意图规划模型（INT4 权重量化）
#   paddle_ocr_det_int8.ms      OCR 文本检测模型
#   paddle_ocr_rec_int8.ms      OCR 文本识别模型
#
# 已知集成约束（转换完成后需代码适配，详见 models/README.md）：
#   1. LocalOCREngine 目前只加载单个 paddle_ocr_lite_int8.ms，且解码为模拟实现
#   2. LocalSLMEngine 直接喂 UTF-8 原文字节，缺少 tokenizer 与多输入迭代解码
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
WS="$APP_DIR/build/model_workspace"
RAWFILE="$APP_DIR/entry/src/main/resources/rawfile/models"
TASK="${1:-all}"

mkdir -p "$WS" "$RAWFILE"

log()  { echo -e "\033[36m[转换]\033[0m $*"; }
ok()   { echo -e "\033[32m[完成]\033[0m $*"; }
warn() { echo -e "\033[33m[警告]\033[0m $*"; }
die()  { echo -e "\033[31m[失败]\033[0m $*"; exit 1; }

# ---------------------------------------------------------------
# 0. 环境检查
# ---------------------------------------------------------------
if [[ ! -d /mnt/c && "$(uname -s)" != "Linux" ]]; then
    warn "未检测到 Linux 环境：converter_lite 仅提供 Linux 包，请在 WSL 中运行"
fi

# MindSpore Lite 2.1.0 converter（鸿蒙端侧要求 2.1.0 系列）
MSLITE_VER="2.1.0"
MSLITE_TAR="mindspore-lite-${MSLITE_VER}-linux-x64.tar.gz"
MSLITE_URL="https://ms-release.obs.cn-north-4.myhuaweicloud.com/${MSLITE_VER}/MindSpore/lite/release/linux/x86_64/cloud_fusion/python37/${MSLITE_TAR}"
MSLITE_HOME="$WS/mindspore-lite-${MSLITE_VER}-linux-x64"

setup_converter() {
    if [[ -x "$MSLITE_HOME/tools/converter/converter/converter_lite" ]]; then
        log "converter_lite 已就绪"
    else
        if [[ ! -f "$WS/$MSLITE_TAR" ]]; then
            log "下载 MindSpore Lite converter ${MSLITE_VER} ..."
            wget -q --show-progress -O "$WS/$MSLITE_TAR" "$MSLITE_URL"
        fi
        tar -xzf "$WS/$MSLITE_TAR" -C "$WS"
    fi
    export LITE_HOME="$MSLITE_HOME"
    export PATH="$PATH:${LITE_HOME}/tools/converter/converter"
    export LD_LIBRARY_PATH="${LITE_HOME}/tools/converter/lib:${LD_LIBRARY_PATH:-}"
}

# ---------------------------------------------------------------
# 1. PaddleOCR: paddle inference -> ONNX -> .ms (INT8 权重量化)
# ---------------------------------------------------------------
convert_ocr() {
    local det_dir="$WS/ch_PP-OCRv3_det_infer"
    local rec_dir="$WS/ch_PP-OCRv3_rec_infer"
    [[ -d "$det_dir" && -d "$rec_dir" ]] || die "缺少 PaddleOCR 权重，请先在 Windows 侧运行 scripts/get_model_weights.ps1（FP32 标准版，非 slim 量化版）"

    setup_converter
    command -v python3 >/dev/null || die "需要 python3"
    python3 -c "import paddle2onnx" 2>/dev/null && python3 -c "import paddle" 2>/dev/null || {
        # 官方标准链路（MindOCR 教程）：paddlepaddle CPU + 最新 paddle2onnx
        # 注意：paddle2onnx 1.0.5 独立版无法解析 PP-OCRv3 的 pdmodel（会产出空 ONNX），
        # 必须使用新版（其 import 依赖 paddlepaddle 包，约 800MB）
        # pip 默认走清华镜像（pypi 官方源在国内常超时），可用环境变量 PIP_INDEX 覆盖
        local PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
        # 版本组合经验证（PP-OCRv3 slim 为 paddle 2.x 时代模型）：
        #   paddlepaddle 3.x 的 PIR 解析旧 pdmodel 报 round_type 属性错误 -> 必须用 2.6.x
        #   paddle2onnx 用 1.2.x（1.0.5 产出空 ONNX；2.x 需 paddle3）
        log "安装 paddlepaddle 2.6.2 + paddle2onnx 1.2.4（镜像: $PIP_INDEX）..."
        pip3 install --quiet -i "$PIP_INDEX" "paddlepaddle==2.6.2" "paddle2onnx==1.2.4" packaging \
            || pip3 install --quiet "paddlepaddle==2.6.2" "paddle2onnx==1.2.4" packaging
    }

    for part in det rec; do
        # 使用 FP32 标准版目录（slim 量化版的 fake_quantize 算子 paddle2onnx 不支持）
        local dir="$WS/ch_PP-OCRv3_${part}_infer"
        local onnx="$WS/ppocrv3_${part}.onnx"

        # 固定输入形状：det [1,3,320,320]（与 LocalOCREngine INPUT_SIZE=320 一致）
        #              rec [1,3,48,320]（NCHW 4 维；3 维会导致 Conv infershape 失败）
        local input_shape
        if [[ "$part" == "det" ]]; then
            local input_shape="x:1,3,320,320"
        else
            local input_shape="x:1,3,48,320"
        fi

        log "转换 PP-OCRv3 ${part} -> ONNX (paddle2onnx CLI) ..."
        # 新版 paddle2onnx 提供两种 CLI：
        #   paddle2onnx 命令            -> --model_dir/--model_filename/--params_filename
        #   python -m paddle2onnx.optimize -> --input_model/--input_shape_dict
        # det/rec 为 pdmodel+pdiparams 分离文件，使用前者
        paddle2onnx \
            --model_dir "$dir" \
            --model_filename inference.pdmodel \
            --params_filename inference.pdiparams \
            --save_file "$onnx" \
            --opset_version 13 \
            --enable_onnx_checker True

        log "转换 ${part}.onnx -> .ms (FP16, 已验证路径) ..."
        # 注意（2026-08-31 实测教训）：
        #   1. INT8 训练后权重量化（--configFile WeightQuant）对本模型失败：
        #      GetConvChannel not find node: conv2d_x.w_0 + InferShape failed(Conv2DFusion)
        #   2. FP16 直转成功，benchmark 验证通过（det/rec 均 ~6.7ms @x86 2线程）
        #   3. 输入形状必须是 4 维 NCHW：det [1,3,320,320] / rec [1,3,48,320]
        #      （rec 若设 3 维会导致 Conv infershape 失败）
        converter_lite \
            --fmk=ONNX \
            --modelFile="$onnx" \
            --outputFile="$RAWFILE/paddle_ocr_${part}_fp16" \
            --inputShape="$input_shape" \
            --fp16=on \
            --saveType=MINDIR_LITE \
            || die "converter_lite 转换 ${part} 失败"

        ok "paddle_ocr_${part}_fp16.ms"
    done
}

# ---------------------------------------------------------------
# 2. Qwen2-0.5B: HF 权重 -> ONNX -> .ms（qwen-mindspore-lite-llm 管线）
# ---------------------------------------------------------------
convert_slm() {
    local hf_dir="$WS/Qwen2-0.5B-Instruct"
    [[ -f "$hf_dir/model.safetensors" ]] || die "缺少 Qwen2-0.5B-Instruct 权重，请先在 Windows 侧运行 scripts/get_model_weights.ps1"

    setup_converter

    # 2.1 获取转换管线仓库
    local pipeline="$WS/qwen-mindspore-lite-llm"
    if [[ ! -d "$pipeline" ]]; then
        log "克隆 qwen-mindspore-lite-llm 转换管线 ..."
        git clone --depth 1 https://github.com/Tlntin/qwen-mindspore-lite-llm.git "$pipeline"
    fi

    # 2.2 Python 环境：mindspore_lite 2.1.1 wheel 覆盖 cp39/cp310（cp311 无）
    #     优先 python3.9，否则用系统 python3（>=3.10）
    local venv="$WS/venv39"
    if [[ ! -x "$venv/bin/python" ]]; then
        local py
        if command -v python3.9 >/dev/null; then
            py="python3.9"
        else
            local major minor
            major=$(python3 -c 'import sys; print(sys.version_info[0])')
            minor=$(python3 -c 'import sys; print(sys.version_info[1])')
            [[ "$major" == "3" && "$minor" -ge 9 && "$minor" -le 10 ]] \
                || die "需要 python3.9/3.10（mindspore_lite 2.1.1 wheel 仅提供 cp39/cp310）"
            py="python3"
        fi
        log "创建虚拟环境（$py）..."
        "$py" -m venv "$venv"
    fi
    # shellcheck disable=SC1091
    source "$venv/bin/activate"

    log "安装 python 依赖（torch/transformers/onnx/mindspore_lite 2.1.1，约 10-20 分钟）..."
    # pip 默认走清华镜像（PyPI 官方源在国内下载 torch 670MB 极慢且易断），可用 PIP_INDEX 覆盖
    local PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
    pip install --quiet --upgrade pip
    # torch 大 wheel 本地优先（WSL 内 pip 下载大文件易断；用 curl -C - 预先下载到 $WS/wheels/）
    # 注意：必须 --no-deps——PyPI 版 torch 2.1.0 的依赖含 2-3GB nvidia CUDA 运行时，
    #       CPU 导出场景完全用不到（torch CPU 路径不加载 CUDA 库），跳过可省大量时间
    if ls "$WS"/wheels/torch-*.whl >/dev/null 2>&1; then
        log "检测到本地 torch wheel，优先安装（--no-deps 跳过 nvidia 依赖链）..."
        pip install --quiet --no-deps "$WS"/wheels/torch-*.whl \
            || warn "本地 torch wheel 安装失败，回退在线安装"
    fi
    pip install --quiet -i "$PIP_INDEX" -r "$pipeline/requirements.txt" \
        || pip install --quiet -r "$pipeline/requirements.txt"
    # mindspore_lite wheel 按当前 python 版本选择（cp39 / cp310）
    local pytag
    pytag=$(python3 -c 'import sys; print(f"cp{sys.version_info[0]}{sys.version_info[1]}")')
    pip install --quiet \
        "https://ms-release.obs.cn-north-4.myhuaweicloud.com/2.1.1/MindSpore/lite/release/linux/x86_64/cloud_fusion/python${pytag#cp}/mindspore_lite-2.1.1-${pytag}-${pytag}-linux_x86_64.whl"

    # 2.3 权重放入管线约定目录
    ln -sfn "$hf_dir" "$pipeline/download/Qwen2-0.5B-Instruct"
    mkdir -p "$pipeline/output/onnx" "$pipeline/output/model"

    # 2.4 导出 ONNX（CPU fp32 导出即可，kv-cache 1024）
    if [[ ! -f "$pipeline/output/onnx/qwen2_0_5b_chat.onnx" ]]; then
        log "导出 ONNX（CPU，约 10-30 分钟，视机器性能）..."
        python3 "$pipeline/export/export_onnx.py" \
            --device_str="cpu" \
            --model_dtype="float32" \
            --input_dtype="float32" \
            --hf_model_dir="$hf_dir" \
            --onnx_model_path="$pipeline/output/onnx/qwen2_0_5b_chat.onnx" \
            --kv_cache_length=1024
    fi

    # 2.5 ONNX -> .ms（FP16 单文件版，已验证路径）
    # 注意（2026-09-01 实测教训）：
    #   1. onnx2ms_v2.py 产物（.ms 小图 + 外挂权重）为 MindSpore 主机侧格式，端侧不可用，
    #      仅可作转换链路中间验证；
    #   2. converter_lite INT4 权重量化（configFile WeightQuant）对本模型静默不生效（权重仍 fp32）；
    #   3. >2GB 模型 converter_lite 自动权重外挂（.ms 图 + .msw 权重）——
    #      flatbuffer 32 位 offset 有 2GB 内联上限，HarmonyOS loadModelFromFile 无法加载 .msw；
    #   4. FP16 存储（--fp16=on）把权重减半至 ~1.27GB < 2GB，可产出端侧单文件 .ms（已验证）。
    #   WSL 内存需求：转换峰值 ~8GB，需 .wslconfig memory>=12GB，否则 OOM。
    log "转换 ONNX -> .ms（FP16 单文件，约 5-10 分钟）..."
    converter_lite \
        --fmk=ONNX \
        --modelFile="$pipeline/output/onnx/qwen2_0_5b_chat.onnx" \
        --outputFile="$RAWFILE/qwen2_0_5b_fp16" \
        --fp16=on \
        --saveType=MINDIR_LITE \
        || die "converter_lite FP16 转换失败"

    ok "qwen2_0_5b_fp16.ms（FP16 单文件，~1.27GB）"
    warn "注意：模型 >100MB，调试期可内置 rawfile（HAP 上限 2GB）；上架前建议改为沙箱下发"
}

# ---------------------------------------------------------------
# 入口
# ---------------------------------------------------------------
case "$TASK" in
    ocr) convert_ocr ;;
    slm) convert_slm ;;
    all) convert_ocr; convert_slm ;;
    *) die "用法: bash scripts/convert_models.sh [all|ocr|slm]" ;;
esac

echo
log "=== rawfile/models 当前内容 ==="
ls -lh "$RAWFILE" | awk '{print "  " $9 " " $5}'
echo
warn "集成提醒（见 models/README.md）："
warn "  1. LocalOCREngine 需改造为加载 det+rec 两个模型并实现 CTC 解码"
warn "  2. LocalSLMEngine 需接入 Qwen tokenizer 与多输入迭代解码"
warn "  3. qwen2 模型若 >100MB，建议 HAP 内置改为应用沙箱下发，避免安装包超限"
