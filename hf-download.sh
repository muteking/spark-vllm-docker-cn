#!/bin/bash
# Bash script for multi-source model download
# Bash 脚本：多源模型下载

set -e

# HuggingFace cache directory path
# HuggingFace 缓存目录路径
HUB_PATH="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# Default values
# 默认值
COPY_HOSTS=()
SSH_USER="$USER"
PARALLEL_COPY=false

# Help function
# 帮助函数
usage() {
    echo "Usage: $0 [OPTIONS] <model-name>"
    echo "用法：$0 [选项] <模型名称>"
    echo "  <model-name>                : HuggingFace model name (e.g., 'QuantTrio/MiniMax-M2-AWQ')"
    echo "  <模型名称>                  : HuggingFace 模型名称（例如：'QuantTrio/MiniMax-M2-AWQ'）"
    echo "  -c, --copy-to <hosts>       : Host(s) to copy the model to. Accepts comma or space-delimited lists after the flag."
    echo "  -c, --copy-to <主机>        : 将模型复制到哪些主机。支持逗号或空格分隔的列表"
    echo "      --copy-to-host          : Alias for --copy-to (backwards compatibility)."
    echo "      --copy-to-host          : --copy-to 的别名（向后兼容）"
    echo "      --copy-parallel         : Copy to all hosts in parallel instead of serially."
    echo "      --copy-parallel         : 并行复制到所有主机，而不是串行"
    echo "  -u, --user <user>           : Username for ssh commands (default: \$USER)"
    echo "  -u, --user <用户>           : SSH 命令使用的用户名（默认：\$USER）"
    echo "  -h, --help                  : Show this help message"
    echo "  -h, --help                  : 显示此帮助信息"
    exit 1
}

add_copy_hosts() {
    local token part
    for token in "$@"; do
        IFS=',' read -ra PARTS <<< "$token"
        for part in "${PARTS[@]}"; do
            part="${part//[[:space:]]/}"
            if [ -n "$part" ]; then
                COPY_HOSTS+=("$part")
            fi
        done
    done
}

copy_model_to_host() {
    local host="$1"
    local model_name="$2"
    local model_dir="$3"
    
    echo "Copying model '$model_name' to ${SSH_USER}@${host}..."
    echo "正在将模型 '$model_name' 复制到 ${SSH_USER}@${host}..."
    local host_copy_start host_copy_end host_copy_time
    host_copy_start=$(date +%s)
    
    if rsync -av --mkpath --progress "$model_dir" "${SSH_USER}@${host}:$HUB_PATH/"; then
        host_copy_end=$(date +%s)
        host_copy_time=$((host_copy_end - host_copy_start))
        printf "Copy to %s completed in %02d:%02d:%02d\n" "$host" $((host_copy_time/3600)) $((host_copy_time%3600/60)) $((host_copy_time%60))
        printf "复制到 %s 完成，耗时 %02d:%02d:%02d\n" "$host" $((host_copy_time/3600)) $((host_copy_time%3600/60)) $((host_copy_time%60))
    else
        echo "Copy to $host failed."
        echo "复制到 $host 失败。"
        return 1
    fi
}

# Argument parsing
# 参数解析
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--copy-to|--copy-to-host|--copy-to-hosts)
            shift
            # Consume arguments until the next flag or end of args
            # 消耗参数直到下一个标志或参数结束
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                add_copy_hosts "$1"
                shift
            done

            # If no hosts specified, use autodiscovery
            # 如果没有指定主机，使用自动发现
            if [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
                echo "No hosts specified. Using autodiscovery..."
                echo "未指定主机。使用自动发现..."
                source "$(dirname "$0")/autodiscover.sh"
                
                detect_nodes
                if [ $? -ne 0 ]; then
                    echo "Error: Autodiscovery failed."
                    echo "错误：自动发现失败。"
                    exit 1
                fi
                
                # Use PEER_NODES directly
                # 直接使用 PEER_NODES
                if [ ${#PEER_NODES[@]} -gt 0 ]; then
                    COPY_HOSTS=("${PEER_NODES[@]}")
                fi
                
                if [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
                     echo "Error: Autodiscovery found no other nodes."
                     echo "错误：自动发现没有找到其他节点。"
                     exit 1
                fi
                echo "Autodiscovered hosts: ${COPY_HOSTS[*]}"
                echo "自动发现的主机：${COPY_HOSTS[*]}"
            fi
            continue
            ;;
        --copy-parallel) PARALLEL_COPY=true ;;
        -u|--user) SSH_USER="$2"; shift ;;
        -h|--help) usage ;;
        *) 
            # If positional argument is provided
            # 如果提供了位置参数
            if [ -z "${MODEL_NAME:-}" ]; then
                MODEL_NAME="$1"
            else
                echo "Error: Unknown parameter: $1"
                echo "错误：未知参数：$1"
                usage
            fi
            ;;
    esac
    shift
done

# Validate model name is provided
# 验证是否提供了模型名称
if [ -z "${MODEL_NAME:-}" ]; then
    echo "Error: Model name is required."
    echo "错误：需要提供模型名称。"
    usage
fi

# Check if uvx is installed
# 检查 uvx 是否已安装
if ! command -v uvx &> /dev/null; then
    echo "Error: 'uvx' command not found."
    echo "错误：未找到 'uvx' 命令。"
    echo ""
    echo "Please install uvx first by running:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "  # or"
    echo "  pip install uvx"
    echo ""
    echo "请先运行以下命令安装 uvx:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "  # 或"
    echo "  pip install uvx"
    echo ""
    exit 1
fi

# Function to check/prompt for HF_TOKEN
# 函数：检查/提示 HF_TOKEN
check_or_prompt_token() {
    local source_name="$1"
    
    # ModelScope doesn't need token
    # ModelScope 不需要 token
    if [ "$source_name" = "modelscope" ]; then
        return 0
    fi
    
    # Check if HF_TOKEN is already set
    # 检查 HF_TOKEN 是否已设置
    if [ -n "$HF_TOKEN" ]; then
        echo "✓ Using HF_TOKEN from environment"
        echo "✓ 使用环境变量中的 HF_TOKEN"
        return 0
    fi
    
    # Check if HUGGING_FACE_HUB_TOKEN is set (alternative env var)
    # 检查 HUGGING_FACE_HUB_TOKEN 是否已设置（备用环境变量）
    if [ -n "$HUGGING_FACE_HUB_TOKEN" ]; then
        HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
        echo "✓ Using HUGGING_FACE_HUB_TOKEN from environment"
        echo "✓ 使用环境变量中的 HUGGING_FACE_HUB_TOKEN"
        return 0
    fi
    
    # For HF mirrors and official, prompt for token
    # 对于 HF mirror 和官方源，提示输入 token
    if [ "$source_name" = "hf-mirror" ] || [ "$source_name" = "official" ]; then
        echo ""
        echo "⚠️  HuggingFace token not found!"
        echo "⚠️  未找到 HuggingFace token!"
        echo "-----------------------------------------"
        echo "To download from HF Mirror or Official, you need a HuggingFace token."
        echo "从 HF Mirror 或官方源下载需要一个 HuggingFace token。"
        echo ""
        echo "📝 Options:"
        echo "📝 选项:"
        echo "  1. Get a free token at: https://huggingface.co/settings/tokens"
        echo "  2. Set HF_TOKEN environment variable and retry"
        echo ""
        echo "💡 Tip: You can skip this by using ModelScope (first priority source)"
        echo "💡 提示：你可以使用 ModelScope（第一优先级的源）来跳过此步骤"
        echo ""
        read -p "Do you want to continue without token? (需要HuggingFace Token下载，没有token可能无法下载或速度受限) [Y/n]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo ""
            read -s -p "Enter your HuggingFace token请输入你的HuggingFace tooken: " HF_TOKEN
            echo ""
            if [ -z "$HF_TOKEN" ]; then
                echo "Error: No token provided."
                echo "错误：未提供 token。"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Start time tracking
# 开始时间追踪
START_TIME=$(date +%s)

# ============================================================
# Multi-source download with fallback support
# 多源下载并支持自动回退
# Source priority: ModelScope > HF Mirror > Official HF
# 下载源优先级：ModelScope > HF Mirror > Official HF
# ============================================================

# Define mirror sources (in priority order)
# 定义镜像源（按优先级顺序）
declare -A HF_MIRRORS=(
    ["modelscope"]="https://www.modelscope.cn"
    ["hf-mirror"]="https://hf-mirror.com"
    ["official"]="https://huggingface.co"
)

# Download from a specific source
# 从特定源下载
download_from_source() {
    local model="$1"
    local source_name="$2"
    local source_url="${HF_MIRRORS[$source_name]}"
    
    echo ""
    echo "========================================="
    echo "  Attempting download from: $source_name"
    echo "  尝试从以下来源下载：$source_name"
    echo "  URL: $source_url"
    echo "  URL: $source_url"
    echo "========================================="
    
    # Check/prompt for HF_TOKEN before HF downloads
    # 在 HF 下载之前检查/提示 HF_TOKEN
    check_or_prompt_token "$source_name"
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # 国内源提示
    if [ "$source_name" = "hf-mirror" ]; then
        echo "🇨🇳 国内源下载中，无需梯子"
        echo "🇨🇳 Downloading from domestic source, no VPN needed"
        echo "-----------------------------------------"
    elif [ "$source_name" = "modelscope" ]; then
        echo "🇨🇳 魔塔源下载中，无需梯子"
        echo "🇨🇳 Downloading from ModelScope, no VPN needed"
        echo "-----------------------------------------"
        
        # 检测 ModelScope 是否已安装
        # 检测 ModelScope 是否已安装
        if ! python3 -c "import modelscope" 2>/dev/null; then
            echo ""
            echo "⚠️  ModelScope 未安装，正在自动安装..."
            echo "⚠️  ModelScope not installed, installing automatically..."
            echo "-----------------------------------------"
            
            # 尝试使用国内源安装
            # 尝试使用国内源安装
            if pip3 install modelscope -i https://mirrors.aliyun.com/pypi/simple/ 2>/dev/null; then
                echo "✓ ModelScope 安装成功"
                echo "✓ ModelScope installed successfully"
                echo "-----------------------------------------"
            elif pip install modelscope -i https://mirrors.aliyun.com/pypi/simple/ 2>/dev/null; then
                echo "✓ ModelScope 安装成功"
                echo "✓ ModelScope installed successfully"
                echo "-----------------------------------------"
            else
                echo "✗ ModelScope 安装失败，跳过魔塔源，尝试下一个源..."
                echo "✗ ModelScope installation failed, skipping ModelScope, trying next source..."
                echo "-----------------------------------------"
                return 1
            fi
        else
            echo "✓ ModelScope 已安装"
            echo "✓ ModelScope is already installed"
            echo "-----------------------------------------"
        fi
    elif [ "$source_name" = "official" ]; then
        echo "🌐 官方镜像海外通道，速度可能较慢或需梯子"
        echo "🌐 Official mirror overseas channel, speed may be slower or requires VPN"
        echo "-----------------------------------------"
    fi
    
    # For ModelScope, use a different approach
    # 对于 ModelScope，使用不同的方法
    if [ "$source_name" = "modelscope" ]; then
        # Try using Python modelscope library (most reliable)
        # 尝试使用 Python modelscope 库（最可靠）
        if python3 -c "
from modelscope import snapshot_download
import os
os.makedirs('$HUB_PATH', exist_ok=True)
snapshot_download('$model', cache_dir='$HUB_PATH')
" 2>/dev/null; then
            return 0
        fi
        return 1
    else
        # For HF mirrors, use HF_ENDPOINT environment variable
        # 对于 HF mirror，使用 HF_ENDPOINT 环境变量
        # Use HF_TOKEN for authentication
        # 使用 HF_TOKEN 进行认证
        if [ -n "$HF_TOKEN" ]; then
            if HF_ENDPOINT="$source_url" HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" uvx hf download "$model"; then
                return 0
            fi
        else
            if HF_ENDPOINT="$source_url" uvx hf download "$model"; then
                return 0
            fi
        fi
        return 1
    fi
}

# Download with automatic fallback
# 自动回退下载
download_with_fallback() {
    local model="$1"
    local sources=("modelscope" "hf-mirror" "official")
    local i=0
    local total=${#sources[@]}
    
    echo ""
    echo "========================================="
    echo "  MULTI-SOURCE MODEL DOWNLOAD"
    echo "  多源模型下载"
    echo "========================================="
    echo "Model: $model"
    echo "模型：$model"
    echo "Source priority:"
    echo "下载源优先级:"
    for src in "${sources[@]}"; do
        echo "  $((++i)). ${HF_MIRRORS[$src]}"
        echo "  $((i)). ${HF_MIRRORS[$src]}"
    done
    echo "========================================="
    
    i=0
    for source in "${sources[@]}"; do
        echo ""
        echo ">>> Attempt $((++i))/${total}: $source"
        echo ">>> 尝试 $i/$total: $source"
        
        if download_from_source "$model" "$source"; then
            echo ""
            echo "✓ Download successful from: $source"
            echo "✓ 从 $source 下载成功"
            echo "========================================="
            return 0
        fi
        
        echo "✗ Failed to download from $source, trying next source..."
        echo "✗ 从 $source 下载失败，尝试下一个源..."
    done
    
    echo ""
    echo "========================================="
    echo "  ERROR: All download sources failed!"
    echo "  错误：所有下载源都失败！"
    echo "========================================="
    echo "Please check:"
    echo "请检查:"
    echo "  1. Model name is correct: $model"
    echo "  1. 模型名称正确：$model"
    echo "  2. Network connectivity"
    echo "  2. 网络连接"
    echo "  3. HuggingFace token (for private models)"
    echo "  3. HuggingFace token（用于私有模型）"
    echo "  4. Disk space in: $HUB_PATH"
    echo "  4. $HUB_PATH 中的磁盘空间"
    echo "========================================="
    return 1
}

# Download model with multi-source fallback
# 使用多源回退下载模型
echo "Downloading model '$MODEL_NAME'..."
echo "正在下载模型 '$MODEL_NAME'..."
DOWNLOAD_START=$(date +%s)

if download_with_fallback "$MODEL_NAME"; then
    DOWNLOAD_END=$(date +%s)
    DOWNLOAD_TIME=$((DOWNLOAD_END - DOWNLOAD_START))
    printf "Download completed in %02d:%02d:%02d\n" $((DOWNLOAD_TIME/3600)) $((DOWNLOAD_TIME%3600/60)) $((DOWNLOAD_TIME%60))
    printf "下载完成，耗时 %02d:%02d:%02d\n" $((DOWNLOAD_TIME/3600)) $((DOWNLOAD_TIME%3600/60)) $((DOWNLOAD_TIME%60))
else
    echo ""
    echo "Error: Failed to download model '$MODEL_NAME' from all sources."
    echo "错误：无法从所有源下载模型 '$MODEL_NAME'。"
    exit 1
fi

# Determine model directory path
# 确定模型目录路径
# uvx hf download stores models in ~/.cache/huggingface/hub with the pattern: models--<org>--<model>-<suffix>
# uvx hf download 将模型存储在 ~/.cache/huggingface/hub，格式为：models--<org>--<model>-<后缀>
MODEL_DIR=""

# Try to find the model directory
# 尝试找到模型目录
# The pattern for model directories is: ~/.cache/huggingface/hub/models--ORG--MODEL-VARIATION (or similar)
# 模型目录的模式是：~/.cache/huggingface/hub/models--ORG--MODEL-VARIATION（或类似）
# Model names like "QuantTrio/MiniMax-M2-AWQ" become "models--QuantTrio--MiniMax-M2-AQW" or similar
# 模型名称如 "QuantTrio/MiniMax-M2-AWQ" 变为 "models--QuantTrio--MiniMax-M2-AQW" 或类似
# Parse org and model name from MODEL_NAME
# 从 MODEL_NAME 解析 org 和模型名称
if [[ "$MODEL_NAME" == */* ]]; then
    ORG="${MODEL_NAME%%/*}"
    MODEL="${MODEL_NAME##*/}"
else
    ORG=""
    MODEL="$MODEL_NAME"
fi

# Convert to the directory pattern used by HuggingFace
# 转换为 HuggingFace 使用的目录模式

if [ -d "$HUB_PATH" ]; then
    if [ -n "$ORG" ]; then
        MODEL_DIR="$HUB_PATH/models--${ORG}--${MODEL}"
    else
        # For models without org, check both patterns
        # 对于没有 org 的模型，检查两种模式
        if [ -d "$HUB_PATH/models--${MODEL}" ]; then
            MODEL_DIR="$HUB_PATH/models--${MODEL}"
        else
            MODEL_DIR="$HUB_PATH/${MODEL}"
        fi
    fi
fi

if [ -z "$MODEL_DIR" ]; then
    echo "Error: Could not find downloaded model directory in $HUB_PATH"
    echo "错误：在 $HUB_PATH 中找不到下载的模型目录"
    echo "Please check the ~/.cache/huggingface/hub directory manually."
    echo "请手动检查 ~/.cache/huggingface/hub 目录。"
    exit 1
fi

echo "Model directory: $MODEL_DIR"
echo "模型目录：$MODEL_DIR"

# Copy to host if requested
# 如果请求则复制到主机
COPY_TIME=0
if [ "${#COPY_HOSTS[@]}" -gt 0 ]; then
    echo ""
    echo "Copying model to ${#COPY_HOSTS[@]} host(s): ${COPY_HOSTS[*]}"
    echo "正在将模型复制到 ${#COPY_HOSTS[@]} 个主机：${COPY_HOSTS[*]}"
    if [ "$PARALLEL_COPY" = true ]; then
        echo "Parallel copy enabled."
        echo "已启用并行复制。"
    fi
    COPY_START=$(date +%s)

    if [ "$PARALLEL_COPY" = true ]; then
        PIDS=()
        for host in "${COPY_HOSTS[@]}"; do
            copy_model_to_host "$host" "$MODEL_NAME" "$MODEL_DIR" &
            PIDS+=($!)
        done
        COPY_FAILURE=0
        for pid in "${PIDS[@]}"; do
            if ! wait "$pid"; then
                COPY_FAILURE=1
            fi
        done
        if [ "$COPY_FAILURE" -ne 0 ]; then
            echo "One or more copies failed."
            echo "一个或多个复制失败。"
            exit 1
        fi
    else
        for host in "${COPY_HOSTS[@]}"; do
            copy_model_to_host "$host" "$MODEL_NAME" "$MODEL_DIR"
        done
    fi

    COPY_END=$(date +%s)
    COPY_TIME=$((COPY_END - COPY_START))
    echo ""
    echo "Copy complete."
    echo "复制完成。"
else
    echo "No host specified, skipping copy."
    echo "未指定主机，跳过复制。"
fi

# Calculate total time
# 计算总时间
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Display timing statistics
# 显示时间统计
echo ""
echo "========================================="
echo "         TIMING STATISTICS"
echo "         时间统计"
echo "========================================="
echo "Download:   $(printf '%02d:%02d:%02d' $((DOWNLOAD_TIME/3600)) $((DOWNLOAD_TIME%3600/60)) $((DOWNLOAD_TIME%60)))"
echo "下载：     $(printf '%02d:%02d:%02d' $((DOWNLOAD_TIME/3600)) $((DOWNLOAD_TIME%3600/60)) $((DOWNLOAD_TIME%60)))"
if [ "$COPY_TIME" -gt 0 ]; then
    echo "Copy:      $(printf '%02d:%02d:%02d' $((COPY_TIME/3600)) $((COPY_TIME%3600/60)) $((COPY_TIME%60)))"
    echo "复制：     $(printf '%02d:%02d:%02d' $((COPY_TIME/3600)) $((COPY_TIME%3600/60)) $((COPY_TIME%60)))"
fi
echo "Total:     $(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))"
echo "总计：     $(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))"
echo "========================================="
echo "Done downloading $MODEL_NAME."
echo "已完成下载 $MODEL_NAME。"
