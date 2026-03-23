#!/bin/bash
set -e

# Start total time tracking
# 开始总时间追踪
START_TIME=$(date +%s)

# Default values
# 默认值
IMAGE_TAG="vllm-node"
REBUILD_FLASHINFER=false
REBUILD_VLLM=false
COPY_HOSTS=()
SSH_USER="$USER"
NO_BUILD=false
VLLM_REF="main"
TMP_IMAGE=""
PARALLEL_COPY=false
EXP_MXFP4=false
VLLM_REF_SET=false
VLLM_PRS=""
PRE_TRANSFORMERS=false
FULL_LOG=false
BUILD_JOBS="16"
GPU_ARCH_LIST="12.1a"
NETWORK_ARG=""
WHEELS_REPO="eugr/spark-vllm-docker"
FLASHINFER_RELEASE_TAG="prebuilt-flashinfer-current"
VLLM_RELEASE_TAG="prebuilt-vllm-current"
# Space-separated list of GPU architectures for which prebuilt wheels are available
# 支持预编译 wheel 的 GPU 架构列表（空格分隔）
PREBUILT_WHEELS_SUPPORTED_ARCHS="12.1a"

cleanup() {
    if [ -n "$TMP_IMAGE" ] && [ -f "$TMP_IMAGE" ]; then
        echo "Cleaning up temporary image $TMP_IMAGE"
echo "清理临时镜像 $TMP_IMAGE"
        rm -f "$TMP_IMAGE"
    fi
}

trap cleanup EXIT

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

copy_to_host() {
    local host="$1"
    echo "Loading image into ${SSH_USER}@${host}..."
echo "正在将镜像加载到 ${SSH_USER}@${host}..."
    local host_copy_start host_copy_end host_copy_time
    host_copy_start=$(date +%s)
    if cat "$TMP_IMAGE" | ssh "${SSH_USER}@${host}" "docker load"; then
        host_copy_end=$(date +%s)
        host_copy_time=$((host_copy_end - host_copy_start))
        printf "Copy to %s completed in %02d:%02d:%02d\n" "$host" $((host_copy_time/3600)) $((host_copy_time%3600/60)) $((host_copy_time%60))
    else
        echo "Copy to $host failed."
echo "复制到 $host 失败。"
        return 1
    fi
}

# try_download_wheels TAG PREFIX
# 函数：try_download_wheels TAG PREFIX
# Downloads wheels matching PREFIX*.whl from a GitHub release.
# 从 GitHub release 下载匹配 PREFIX*.whl 的 wheel 文件。
# Skip conditions (either is sufficient):
# 跳过条件（满足任一即可）：
#   1. Commit hash in release name matches .wheels/.{PREFIX}_commit (primary check).
#   1. release 名称中的 commit hash 匹配 .wheels/.{PREFIX}_commit（主要检查）。
#   2. All local wheels are newer than the latest GitHub asset (freshly built).
#   2. 所有本地 wheel 都比最新的 GitHub 资源更新（ freshly built）。
# Only downloads a file when the remote asset is newer than the local copy AND
# 仅当远程资源比本地副本更新且
# the above skip conditions are not met.
# 不满足上述跳过条件时才下载文件。
# On success, persists the release commit hash to .wheels/.{PREFIX}_commit.
# 成功时，将 release commit hash 持久化到 .wheels/.{PREFIX}_commit。
# Returns 0 if all matching wheels are now available, 1 on any error.
# 如果所有匹配的 wheel 都已就绪则返回 0，任何错误返回 1。
try_download_wheels() {
    local TAG="$1"
    local PREFIX="$2"
    local WHEELS_DIR="./wheels"

    local arch
    for arch in $PREBUILT_WHEELS_SUPPORTED_ARCHS; do
        [ "$arch" = "$GPU_ARCH_LIST" ] && break
        arch=""
    done
    if [ -z "$arch" ]; then
        echo "GPU arch '$GPU_ARCH_LIST' not supported by prebuilt wheels (supported: $PREBUILT_WHEELS_SUPPORTED_ARCHS) — skipping download."
        return 1
    fi

    local RELEASE_JSON
    RELEASE_JSON=$(curl -sf --connect-timeout 10 \
        "https://api.github.com/repos/$WHEELS_REPO/releases/tags/$TAG") || {
        echo "Could not fetch release metadata for '$TAG' — skipping download."
echo "无法获取 '$TAG' 的 release 元数据 — 跳过下载。"
        return 1
    }

    local DOWNLOAD_LIST
    DOWNLOAD_LIST=$(echo "$RELEASE_JSON" | python3 -c '
import json, sys, os, re
from datetime import datetime, timezone

wheels_dir, prefix = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
assets = [a for a in data.get("assets", [])
          if a["name"].startswith(prefix) and a["name"].endswith(".whl")]

if not assets:
    print("No assets found matching prefix: " + prefix, file=sys.stderr)
print("没有找到匹配前缀的资源：" + prefix, file=sys.stderr)
    sys.exit(1)

# Extract commit hash from the release name:
# 从 release 名称中提取 commit hash:
#   FlashInfer: "Prebuilt FlashInfer Wheels (0.6.5-124a2d32-d20260305) - DGX Spark Only"
#   FlashInfer: "预编译 FlashInfer Wheels (0.6.5-124a2d32-d20260305) - 仅限 DGX Spark"
#   vLLM:       "Prebuilt vLLM Wheels (0.16.1rc1.dev296+ga73af584f.d20260305.cu131) - DGX Spark only"
#   vLLM:       "预编译 vLLM Wheels (0.16.1rc1.dev296+ga73af584f.d20260305.cu131) - 仅限 DGX Spark"
release_name = data.get("name", "")
commit_hash = None
if prefix.startswith("flashinfer"):
    m = re.search(r"\([\d.]+\w*-([0-9a-f]{6,})-d\d{8}\)", release_name, re.IGNORECASE)
    if m:
        commit_hash = m.group(1)
else:
    m = re.search(r"\+g([0-9a-f]{6,})\.", release_name, re.IGNORECASE)
    if m:
        commit_hash = m.group(1)

# Compare against the locally stored commit hash
# 与本地存储的 commit hash 比较
commit_file = os.path.join(wheels_dir, "." + prefix + "-commit")
local_commit = None
if os.path.exists(commit_file):
    with open(commit_file) as f:
        local_commit = f.read().strip()

if commit_hash and local_commit and local_commit[:len(commit_hash)] == commit_hash:
    print("Commit hash matches (" + commit_hash + ") — wheels are up to date.", file=sys.stderr)
print("Commit hash 匹配 (" + commit_hash + ") — wheel 已是最新。", file=sys.stderr)
    sys.exit(0)

newest_remote_ts = max(
    datetime.strptime(a["updated_at"], "%Y-%m-%dT%H:%M:%SZ")
            .replace(tzinfo=timezone.utc).timestamp()
    for a in assets
)

# If local wheels (any version matching prefix) are all newer than the
# 如果本地 wheel（任何匹配前缀的版本）都比
# latest GitHub asset, they were freshly built and should not be replaced.
# 最新的 GitHub 资源新，说明是 freshly built，不应替换。
local_wheels = [
    os.path.join(wheels_dir, f) for f in os.listdir(wheels_dir)
    if f.startswith(prefix) and f.endswith(".whl")
]
if local_wheels and all(os.path.getmtime(p) >= newest_remote_ts for p in local_wheels):
    sys.exit(0)

downloads = []
for a in assets:
    local_path = os.path.join(wheels_dir, a["name"])
    remote_ts = datetime.strptime(a["updated_at"], "%Y-%m-%dT%H:%M:%SZ") \
                    .replace(tzinfo=timezone.utc).timestamp()
    if not os.path.exists(local_path) or remote_ts > os.path.getmtime(local_path):
        downloads.append(a["browser_download_url"] + " " + a["name"])

if downloads:
    if commit_hash:
        print("#commit:" + commit_hash)
    for d in downloads:
        print(d)
' "$WHEELS_DIR" "$PREFIX") || return 1

    if [ -z "$DOWNLOAD_LIST" ]; then
        echo "All $PREFIX wheels are up to date — skipping download."
echo "所有 $PREFIX wheel 已是最新 — 跳过下载。"
        return 0
    fi

    # Parse the optional '#commit:HASH' sentinel emitted by the Python script
# 解析 Python 脚本发出的可选 '#commit:HASH' 标记
    local REMOTE_COMMIT=""
    local DOWNLOAD_ENTRIES=""
    while IFS= read -r LINE; do
        if [[ "$LINE" == "#commit:"* ]]; then
            REMOTE_COMMIT="${LINE#"#commit:"}"
        elif [[ -n "$LINE" ]]; then
            DOWNLOAD_ENTRIES+="$LINE"$'\n'
        fi
    done <<< "$DOWNLOAD_LIST"

    if [ -z "$DOWNLOAD_ENTRIES" ]; then
        echo "All $PREFIX wheels are up to date — skipping download."
echo "所有 $PREFIX wheel 已是最新 — 跳过下载。"
        return 0
    fi

    # Back up existing wheels so we never leave a mix of old and new on failure
# 备份现有 wheels，以防失败时混合新旧版本
    local DL_BACKUP="$WHEELS_DIR/.backup-download-${PREFIX}"
    rm -rf "$DL_BACKUP" && mkdir -p "$DL_BACKUP"
    for f in "$WHEELS_DIR/${PREFIX}"*.whl; do
        [ -f "$f" ] && mv "$f" "$DL_BACKUP/"
    done
    for f in "$WHEELS_DIR/.${PREFIX}"*; do
        [ -f "$f" ] && mv "$f" "$DL_BACKUP/"
    done

    local URL NAME TMP_WHL
    local DOWNLOADED=()
    while IFS=' ' read -r URL NAME; do
        [ -z "$URL" ] && continue
        echo "Downloading $NAME..."
echo "正在下载 $NAME..."
        TMP_WHL=$(mktemp "$WHEELS_DIR/${NAME}.XXXXXX")
        if curl -L --progress-bar --connect-timeout 30 "$URL" -o "$TMP_WHL"; then
            mv "$TMP_WHL" "$WHEELS_DIR/$NAME"
            DOWNLOADED+=("$WHEELS_DIR/$NAME")
        else
            rm -f "$TMP_WHL"
            echo "Failed to download $NAME — removing other downloaded files."
echo "下载 $NAME 失败 — 移除其他已下载文件。"
            for f in "${DOWNLOADED[@]}"; do rm -f "$f"; done
            if compgen -G "$DL_BACKUP/${PREFIX}*.whl" > /dev/null 2>&1; then
                echo "Restoring previous $PREFIX wheels..."
echo "恢复之前的 $PREFIX wheels..."
                mv "$DL_BACKUP/${PREFIX}"*.whl "$WHEELS_DIR/"
                mv "$DL_BACKUP/.${PREFIX}"* "$WHEELS_DIR/"
            fi
            rm -rf "$DL_BACKUP"
            return 1
        fi
    done <<< "$DOWNLOAD_ENTRIES"

    rm -rf "$DL_BACKUP"
    if [ -n "$REMOTE_COMMIT" ]; then
        echo "$REMOTE_COMMIT" > "$WHEELS_DIR/.${PREFIX}-commit"
echo "$REMOTE_COMMIT" > "$WHEELS_DIR/.${PREFIX}-commit"
        echo "Recorded $PREFIX commit hash: $REMOTE_COMMIT"
echo "已记录 $PREFIX commit hash: $REMOTE_COMMIT"
    fi
    return 0
}

# Help function
# 帮助函数
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -t, --tag <tag>               : Image tag (default: 'vllm-node')"
    echo "  --gpu-arch <arch>             : GPU architecture (default: '12.1a')"
    echo "  --rebuild-flashinfer          : Force rebuild of FlashInfer wheels (ignore cached wheels)"
    echo "  --rebuild-vllm                : Force rebuild of vLLM wheels (ignore cached wheels)"
    echo "  --vllm-ref <ref>              : vLLM commit SHA, branch or tag (default: 'main')"
    echo "  -c, --copy-to <hosts>         : Host(s) to copy the image to. Accepts comma or space-delimited lists."
    echo "      --copy-to-host            : Alias for --copy-to (backwards compatibility)."
    echo "      --copy-parallel           : Copy to all hosts in parallel instead of serially."
    echo "  -j, --build-jobs <jobs>       : Number of concurrent build jobs (default: ${BUILD_JOBS})"
    echo "  -u, --user <user>             : Username for ssh command (default: \$USER)"
    echo "  --tf5                         : Install transformers>=5 (aliases: --pre-tf, --pre-transformers)"
    echo "  --exp-mxfp4, --experimental-mxfp4 : Build with experimental native MXFP4 support"
    echo "  --apply-vllm-pr <pr-num>      : Apply a specific PR patch to vLLM source. Can be specified multiple times."
    echo "  --full-log                    : Enable full build logging (--progress=plain)"
    echo "  --no-build                    : Skip building, only copy image (requires --copy-to)"
    echo "  --network <network>           : Docker network to use during build"
    echo "  -h, --help                    : Show this help message"
    exit 1
}

# Argument parsing
# 参数解析
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--tag) IMAGE_TAG="$2"; shift ;;
        --gpu-arch) GPU_ARCH_LIST="$2"; shift ;;
        --rebuild-flashinfer) REBUILD_FLASHINFER=true ;;
        --rebuild-vllm) REBUILD_VLLM=true ;;
        --vllm-ref) VLLM_REF="$2"; VLLM_REF_SET=true; shift ;;
        -c|--copy-to|--copy-to-host|--copy-to-hosts)
            shift
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                add_copy_hosts "$1"
                shift
            done

            if [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
                echo "No hosts specified. Using autodiscovery..."
                source "$(dirname "$0")/autodiscover.sh"

                detect_nodes
                if [ $? -ne 0 ]; then
                    echo "Error: Autodiscovery failed."
echo "错误：自动发现失败。"
                    exit 1
                fi

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
        -j|--build-jobs) BUILD_JOBS="$2"; shift ;;
        -u|--user) SSH_USER="$2"; shift ;;
        --copy-parallel) PARALLEL_COPY=true ;;
        --tf5|--pre-tf|--pre-transformers) PRE_TRANSFORMERS=true ;;
        --exp-mxfp4|--experimental-mxfp4) EXP_MXFP4=true ;;
        --apply-vllm-pr)
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
               if [ -n "$VLLM_PRS" ]; then
                   VLLM_PRS="$VLLM_PRS $2"
               else
                   VLLM_PRS="$2"
               fi
               shift
            else
               echo "Error: --apply-vllm-pr requires a PR number."
echo "错误：--apply-vllm-pr 需要 PR 编号。"
               exit 1
            fi
            ;;
        --full-log) FULL_LOG=true ;;
        --no-build) NO_BUILD=true ;;
        --network)
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                NETWORK_ARG="$2"
                shift
            else
                echo "Error: --network requires a network name."
echo "错误：--network 需要网络名称。"
                exit 1
            fi
            ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate flag combinations
# 验证参数组合
if [ -n "$VLLM_PRS" ]; then
    if [ "$EXP_MXFP4" = true ]; then echo "Error: --apply-vllm-pr is incompatible with --exp-mxfp4"; exit 1; fi
fi

if [ "$EXP_MXFP4" = true ]; then
    if [ "$VLLM_REF_SET" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --vllm-ref"; exit 1; fi
    if [ "$PRE_TRANSFORMERS" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --tf5"; exit 1; fi
    if [ "$REBUILD_FLASHINFER" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --rebuild-flashinfer"; exit 1; fi
    if [ "$REBUILD_VLLM" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --rebuild-vllm"; exit 1; fi
fi

# Validate --no-build usage
# 验证 --no-build 的用法
if [ "$NO_BUILD" = true ] && [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
    echo "Error: --no-build requires --copy-to to be specified"
echo "错误：--no-build 需要指定 --copy-to"
    exit 1
fi

# Ensure wheels directory exists
# 确保 wheels 目录存在
mkdir -p ./wheels

# Common build flags used across all non-mxfp4 sub-builds
# 所有非 mxfp4 子构建共用的构建标志
COMMON_BUILD_FLAGS=()
if [ "$FULL_LOG" = true ]; then
    COMMON_BUILD_FLAGS+=("--progress=plain")
fi
COMMON_BUILD_FLAGS+=("--build-arg" "BUILD_JOBS=$BUILD_JOBS")
COMMON_BUILD_FLAGS+=("--build-arg" "TORCH_CUDA_ARCH_LIST=$GPU_ARCH_LIST")
COMMON_BUILD_FLAGS+=("--build-arg" "FLASHINFER_CUDA_ARCH_LIST=$GPU_ARCH_LIST")
if [ -n "$NETWORK_ARG" ]; then
    COMMON_BUILD_FLAGS+=("--network" "$NETWORK_ARG")
fi

# =====================================================
# =========================================
# Build image (unless --no-build or --exp-mxfp4)
# 构建镜像（除非 --no-build 或 --exp-mxfp4）
# =====================================================
# =========================================
FLASHINFER_BUILD_TIME=0
VLLM_BUILD_TIME=0
RUNNER_BUILD_TIME=0

if [ "$NO_BUILD" = false ]; then
    if [ "$EXP_MXFP4" = true ]; then
        echo "Building with experimental MXFP4 support..."
echo "正在使用实验性 MXFP4 支持构建..."
        CMD=("docker" "build" "-t" "$IMAGE_TAG" "${COMMON_BUILD_FLAGS[@]}" "-f" "Dockerfile.mxfp4" ".")
        echo "Building image with command: ${CMD[*]}"
echo "使用以下命令构建镜像：${CMD[*]}"
        BUILD_START=$(date +%s)
        "${CMD[@]}"
        BUILD_END=$(date +%s)
        RUNNER_BUILD_TIME=$((BUILD_END - BUILD_START))
    else
        # ----------------------------------------------------------
# ------------------------------------------------
        # Phase 1: FlashInfer wheels
# 阶段 1: FlashInfer wheels
        # ----------------------------------------------------------
# ------------------------------------------------
        BUILD_FLASHINFER=false
        if [ "$REBUILD_FLASHINFER" = true ]; then
            echo "Rebuilding FlashInfer wheels (--rebuild-flashinfer specified)..."
echo "正在重建 FlashInfer wheel (--rebuild-flashinfer 指定)..."
            BUILD_FLASHINFER=true
        elif try_download_wheels "$FLASHINFER_RELEASE_TAG" "flashinfer"; then
            echo "FlashInfer wheels ready."
echo "FlashInfer wheel 就绪。"
        elif compgen -G "./wheels/flashinfer*.whl" > /dev/null 2>&1; then
            echo "Download failed — using existing local FlashInfer wheels."
echo "下载失败 — 使用本地现有的 FlashInfer wheel。"
        else
            echo "No FlashInfer wheels available (download failed) — building..."
echo "没有可用的 FlashInfer wheel（下载失败）— 构建中..."
            BUILD_FLASHINFER=true
        fi

        if [ "$BUILD_FLASHINFER" = true ]; then
            # Back up existing flashinfer wheels; restore them if the build fails
# 备份现有的 flashinfer wheels; 如果构建失败则恢复
# 备份现有的 flashinfer wheels; 如果构建失败则恢复
            FI_BACKUP="./wheels/.backup-flashinfer"
            rm -rf "$FI_BACKUP" && mkdir -p "$FI_BACKUP"
            for f in ./wheels/flashinfer*.whl; do
                [ -f "$f" ] && mv "$f" "$FI_BACKUP/"
            done

            FI_CMD=("docker" "build"
                "--target" "flashinfer-export"
                "--output" "type=local,dest=./wheels"
                "${COMMON_BUILD_FLAGS[@]}")

            if [ "$REBUILD_FLASHINFER" = true ]; then
                FI_CMD+=("--build-arg" "CACHEBUST_FLASHINFER=$(date +%s)")
            fi

            FI_CMD+=(".")

            echo "FlashInfer build command: ${FI_CMD[*]}"
echo "FlashInfer 构建命令：${FI_CMD[*]}"
            FI_START=$(date +%s)
            if "${FI_CMD[@]}"; then
                FI_END=$(date +%s)
                FLASHINFER_BUILD_TIME=$((FI_END - FI_START))
                rm -rf "$FI_BACKUP"
            else
                echo "FlashInfer build failed — restoring previous wheels..."
echo "FlashInfer 构建失败 — 恢复之前的 wheel..."
                mv "$FI_BACKUP"/flashinfer*.whl ./wheels/ 2>/dev/null || true
                rm -rf "$FI_BACKUP"
                exit 1
            fi
        fi

        # ----------------------------------------------------------
# ------------------------------------------------
        # Phase 2: vLLM wheels
# 阶段 2: vLLM wheels
        # ----------------------------------------------------------
# ------------------------------------------------
        if [ "$VLLM_REF_SET" = true ] || [ -n "$VLLM_PRS" ]; then
            REBUILD_VLLM=true
        fi

        BUILD_VLLM=false
        if [ "$REBUILD_VLLM" = true ]; then
            if [ "$VLLM_REF_SET" = true ] && [ -n "$VLLM_PRS" ]; then
                echo "Rebuilding vLLM wheels (--vllm-ref and --apply-vllm-pr specified)..."
echo "正在重建 vLLM wheel (--vllm-ref 和 --apply-vllm-pr 指定)..."
            elif [ "$VLLM_REF_SET" = true ]; then
                echo "Rebuilding vLLM wheels (--vllm-ref specified)..."
echo "正在重建 vLLM wheel (--vllm-ref 指定)..."
            elif [ -n "$VLLM_PRS" ]; then
                echo "Rebuilding vLLM wheels (--apply-vllm-pr specified)..."
echo "正在重建 vLLM wheel (--apply-vllm-pr 指定)..."
            else
                echo "Rebuilding vLLM wheels (--rebuild-vllm specified)..."
echo "正在重建 vLLM wheel (--rebuild-vllm 指定)..."
            fi
            BUILD_VLLM=true
        elif try_download_wheels "$VLLM_RELEASE_TAG" "vllm"; then
            echo "vLLM wheels ready."
echo "vLLM wheel 就绪。"
        elif compgen -G "./wheels/vllm*.whl" > /dev/null 2>&1; then
            echo "Download failed — using existing local vLLM wheels."
echo "下载失败 — 使用本地现有的 vLLM wheel。"
        else
            echo "No vLLM wheels available (download failed) — building..."
echo "没有可用的 vLLM wheel（下载失败）— 构建中..."
            BUILD_VLLM=true
        fi

        if [ "$BUILD_VLLM" = true ]; then
            # Back up existing vllm wheels; restore them if the build fails
# 备份现有的 vllm wheels; 如果构建失败则恢复
# 备份现有的 vllm wheels; 如果构建失败则恢复
            VLLM_BACKUP="./wheels/.backup-vllm"
            rm -rf "$VLLM_BACKUP" && mkdir -p "$VLLM_BACKUP"
            for f in ./wheels/vllm*.whl; do
                [ -f "$f" ] && mv "$f" "$VLLM_BACKUP/"
            done

            VLLM_CMD=("docker" "build"
                "--target" "vllm-export"
                "--output" "type=local,dest=./wheels"
                "${COMMON_BUILD_FLAGS[@]}"
                "--build-arg" "VLLM_REF=$VLLM_REF")

            if [ "$REBUILD_VLLM" = true ]; then
                VLLM_CMD+=("--build-arg" "CACHEBUST_VLLM=$(date +%s)")
            fi

            if [ -n "$VLLM_PRS" ]; then
                echo "Applying vLLM PRs: $VLLM_PRS"
echo "应用 vLLM PR: $VLLM_PRS"
                VLLM_CMD+=("--build-arg" "VLLM_PRS=$VLLM_PRS")
            fi

            VLLM_CMD+=(".")

            echo "vLLM build command: ${VLLM_CMD[*]}"
echo "vLLM 构建命令：${VLLM_CMD[*]}"
            VLLM_START=$(date +%s)
            if "${VLLM_CMD[@]}"; then
                VLLM_END=$(date +%s)
                VLLM_BUILD_TIME=$((VLLM_END - VLLM_START))
                rm -rf "$VLLM_BACKUP"
            else
                echo "vLLM build failed — restoring previous wheels..."
echo "vLLM 构建失败 — 恢复之前的 wheel..."
                mv "$VLLM_BACKUP"/vllm*.whl ./wheels/ 2>/dev/null || true
                rm -rf "$VLLM_BACKUP"
                exit 1
            fi
        fi

        # ----------------------------------------------------------
# ------------------------------------------------
        # Phase 3: Runner image
# 阶段 3: Runner 镜像
        # ----------------------------------------------------------
# ------------------------------------------------
        if ! compgen -G "./wheels/*.whl" > /dev/null 2>&1; then
            echo "Error: No wheel files found in ./wheels/ — cannot build runner image."
echo "错误：在 ./wheels/ 中未找到 wheel 文件 — 无法构建 runner 镜像。"
            exit 1
        fi

        RUNNER_CMD=("docker" "build"
            "-t" "$IMAGE_TAG"
            "${COMMON_BUILD_FLAGS[@]}")

        if [ "$PRE_TRANSFORMERS" = true ]; then
            echo "Using transformers>=5.0.0..."
echo "使用 transformers>=5.0.0..."
            RUNNER_CMD+=("--build-arg" "PRE_TRANSFORMERS=1")
        fi

        RUNNER_CMD+=(".")

        echo "Building runner image with command: ${RUNNER_CMD[*]}"
echo "使用以下命令构建 runner 镜像：${RUNNER_CMD[*]}"
        RUNNER_START=$(date +%s)
        "${RUNNER_CMD[@]}"
        RUNNER_END=$(date +%s)
        RUNNER_BUILD_TIME=$((RUNNER_END - RUNNER_START))
    fi
else
    echo "Skipping build (--no-build specified)"
echo "跳过构建 (--no-build 指定)"
fi

# =====================================================
# =========================================
# Copy to host(s) if requested
# 如果请求则复制到主机
# =====================================================
# =========================================
COPY_TIME=0
if [ "${#COPY_HOSTS[@]}" -gt 0 ]; then
    echo "Copying image '$IMAGE_TAG' to ${#COPY_HOSTS[@]} host(s): ${COPY_HOSTS[*]}"
echo "正在将镜像 '$IMAGE_TAG' 复制到 ${#COPY_HOSTS[@]} 个主机：${COPY_HOSTS[*]}"
    if [ "$PARALLEL_COPY" = true ]; then
        echo "Parallel copy enabled."
echo "已启用并行复制。"
    fi
    COPY_START=$(date +%s)

    TMP_IMAGE=$(mktemp -t vllm_image.XXXXXX)
    echo "Saving image locally to $TMP_IMAGE..."
echo "正在将镜像保存到本地 $TMP_IMAGE..."
    docker save -o "$TMP_IMAGE" "$IMAGE_TAG"

    if [ "$PARALLEL_COPY" = true ]; then
        PIDS=()
        for host in "${COPY_HOSTS[@]}"; do
            copy_to_host "$host" &
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
            copy_to_host "$host"
        done
    fi

    COPY_END=$(date +%s)
    COPY_TIME=$((COPY_END - COPY_START))
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
echo "========================================="
if [ "$FLASHINFER_BUILD_TIME" -gt 0 ]; then
    echo "FlashInfer Build: $(printf '%02d:%02d:%02d' $((FLASHINFER_BUILD_TIME/3600)) $((FLASHINFER_BUILD_TIME%3600/60)) $((FLASHINFER_BUILD_TIME%60)))"
fi
if [ "$VLLM_BUILD_TIME" -gt 0 ]; then
    echo "vLLM Build:       $(printf '%02d:%02d:%02d' $((VLLM_BUILD_TIME/3600)) $((VLLM_BUILD_TIME%3600/60)) $((VLLM_BUILD_TIME%60)))"
fi
if [ "$RUNNER_BUILD_TIME" -gt 0 ]; then
    echo "Runner Build:     $(printf '%02d:%02d:%02d' $((RUNNER_BUILD_TIME/3600)) $((RUNNER_BUILD_TIME%3600/60)) $((RUNNER_BUILD_TIME%60)))"
fi
if [ "$COPY_TIME" -gt 0 ]; then
    echo "Image Copy:       $(printf '%02d:%02d:%02d' $((COPY_TIME/3600)) $((COPY_TIME%3600/60)) $((COPY_TIME%60)))"
fi
echo "Total Time:       $(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))"
echo "========================================="
echo "Done building $IMAGE_TAG."
echo "已完成构建 $IMAGE_TAG。"
