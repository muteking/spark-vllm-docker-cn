#!/bin/bash
#
# run-recipe.sh - Wrapper for run-recipe.py
# run-recipe.sh - run-recipe.py 的包装脚本
#
# Ensures Python dependencies are available and runs the recipe runner.
# 确保 Python 依赖已安装并运行 recipe 运行器。
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_SCRIPT="$SCRIPT_DIR/run-recipe.py"
RECIPES_DIR="$SCRIPT_DIR/recipes"

# Interactive recipe selection - outputs menu to stderr, result to stdout
# 交互式配方选择 - 菜单输出到 stderr，结果输出到 stdout
select_recipe() {
    # Get all .yaml files
    mapfile -t recipes < <(find "$RECIPES_DIR" -name "*.yaml" -type f 2>/dev/null | sort)
    
    if [[ ${#recipes[@]} -eq 0 ]]; then
        echo "Error: No recipes found in $RECIPES_DIR" >&2
        return 1
    fi
    
    # Display menu to stderr
    # 显示菜单到 stderr
    echo "" >&2
    echo "=========================================" >&2
    echo "       Available Recipes / 可用配方" >&2
    echo "=========================================" >&2
    echo "" >&2
    echo "Total: ${#recipes[@]} recipe(s) found" >&2
    echo "共找到 ${#recipes[@]} 个配方" >&2
    echo "" >&2
    echo "Legend / 图例:" >&2
    echo "  【4x 集群模式】 - 4 台 DGX SPark 通过 200G 交换机连接配置后运行" >&2
    echo "  【集群模式】 - 需要两台或以上 DGX Spark 通过 QSFP 互联后运行 (cluster_only: true)" >&2
    echo "  【单机模式】 - 单机可运行 (其他所有情况)" >&2
    echo "" >&2
    
    # Display recipes to stderr
    # 显示配方到 stderr
    for i in "${!recipes[@]}"; do
        recipe_path="${recipes[$i]}"
        recipe_name=$(basename "$recipe_path" .yaml)
        
        # Determine mode: 4x cluster > standard cluster > single
        # 判断模式：4x 集群 > 标准集群 > 单机
        local mode_tag="【单机模式】"
        
        # 优先检查是否在 4x-spark-cluster 目录下
        if [[ "$recipe_path" == */4x-spark-cluster/* ]]; then
            mode_tag="【4x 集群模式】"
        elif [[ -f "$recipe_path" ]]; then
            # 检查 cluster_only: true
            local cluster_only=$(python3 -c "
import yaml
try:
    with open('$recipe_path', 'r') as f:
        recipe = yaml.safe_load(f)
    print('true' if recipe.get('cluster_only', False) else '')
except:
    pass
" 2>/dev/null)
            
            if [[ "$cluster_only" == "true" ]]; then
                mode_tag="【集群模式】"
            fi
        fi
        
        echo "  [$((i+1))] $recipe_name $mode_tag" >&2
    done
    echo "" >&2
    echo "Enter number (1-${#recipes[@]}) or 'q' to quit: / 输入数字 (1-${#recipes[@]}) 或 'q' 退出:" >&2
    
    # Read input
    # 读取输入
    local choice=""
    if read -t 30 -r choice 2>/dev/null; then
        if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            echo "Cancelled / 已取消" >&2
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#recipes[@]} ]]; then
            # Success - output ONLY the recipe path to stdout
            # 成功 - 只输出配方路径到 stdout
            echo "${recipes[$((choice-1))]}"
            return 0
        else
            echo "Invalid selection / 无效选择" >&2
            return 1
        fi
    else
        echo "Timeout waiting for input / 输入超时" >&2
        return 1
    fi
}

# Check for Python 3.10+
if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    echo "Error: Python 3 not found. Please install Python 3.10 or later." >&2
    exit 1
fi

# Verify version
PY_VERSION=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$($PYTHON -c 'import sys; print(sys.version_info.major)')
PY_MINOR=$($PYTHON -c 'import sys; print(sys.version_info.minor)')

if [[ "$PY_MAJOR" -lt 3 ]] || [[ "$PY_MAJOR" -eq 3 && "$PY_MINOR" -lt 10 ]]; then
    echo "Error: Python 3.10+ required, found $PY_VERSION" >&2
    exit 1
fi

# Check for PyYAML
if ! $PYTHON -c "import yaml" 2>/dev/null; then
    echo "Installing PyYAML..." >&2
    $PYTHON -m pip install --quiet pyyaml
fi

# Parse arguments
INTERACTIVE_MODE=false
if [[ $# -eq 0 ]]; then
    INTERACTIVE_MODE=true
elif [[ "$1" == "--interactive" || "$1" == "-i" ]]; then
    INTERACTIVE_MODE=true
    shift
elif [[ "$1" == "--list" || "$1" == "-l" ]]; then
    # Show list
    echo "Available recipes:" >&2
    for recipe in "$RECIPES_DIR"/*.yaml; do
        [[ -f "$recipe" ]] && echo "  $(basename "$recipe" .yaml)" >&2
    done
    exit 0
fi

# Run selection if interactive
if $INTERACTIVE_MODE; then
    selected_recipe=$(select_recipe)
    if [[ -z "$selected_recipe" ]]; then
        echo "No recipe selected. Exiting.未选择配方，退出中！" >&2
        exit 1
    fi
    set -- "$selected_recipe" "$@"
fi

# Run the recipe
exec $PYTHON "$RECIPE_SCRIPT" "$@"
