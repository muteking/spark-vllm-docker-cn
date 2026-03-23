#!/bin/bash

# 测试使用下面：
# bash -c 'source autodiscover.sh && detect_interfaces && detect_local_ip'
# Function to detect IB and Ethernet interfaces
# 检测 InfiniBand 和以太网接口的函数

detect_interfaces() {
    # If both interfaces are already set, nothing to do
# 如果两个接口都已设置，无需操作

    if [[ -n "$ETH_IF" && -n "$IB_IF" ]]; then
        return 0
    fi

    # Check for required tools
# 检查所需的工具

    if ! command -v ibdev2netdev &> /dev/null; then
        echo "Error: ibdev2netdev not found. Cannot auto-detect interfaces."
        echo "错误：未找到 ibdev2netdev。无法自动检测接口。"
        return 1
    fi

    echo "Auto-detecting interfaces..."
    echo "正在自动检测接口..."
    
    # Get all Up interfaces: "rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)"
# 获取所有 Up 接口："rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)"

    # We capture: IB_DEV, NET_DEV
# 我们捕获：IB_DEV、NET_DEV

    mapfile -t IB_NET_PAIRS < <(ibdev2netdev | awk '/Up\)/ {print $1 " " $5}')
    
    if [ ${#IB_NET_PAIRS[@]} -eq 0 ]; then
        echo "Error: No active IB interfaces found."
        echo "错误：未找到活动的 IB 接口。"
        return 1
    fi

    DETECTED_IB_IFS=()
    CANDIDATE_ETH_IFS=()

    for pair in "${IB_NET_PAIRS[@]}"; do
        ib_dev=$(echo "$pair" | awk '{print $1}')
        net_dev=$(echo "$pair" | awk '{print $2}')
        
        DETECTED_IB_IFS+=("$ib_dev")
        
        # Check if interface has an IP address
# 检查接口是否有 IP 地址

        if ip addr show "$net_dev" | grep -q "inet "; then
            CANDIDATE_ETH_IFS+=("$net_dev")
        fi
    done

    # Set IB_IF if not provided
# 如果未提供，设置 IB_IF

    if [[ -z "$IB_IF" ]]; then
        IB_IF=$(IFS=,; echo "${DETECTED_IB_IFS[*]}")
        echo "  Detected IB_IF: $IB_IF"
        echo "  检测到的 IB_IF: $IB_IF"
    fi

    # Set ETH_IF if not provided
# 如果未提供，设置 ETH_IF

    if [[ -z "$ETH_IF" ]]; then
        if [ ${#CANDIDATE_ETH_IFS[@]} -eq 0 ]; then
            echo "Error: No active IB-associated interfaces have IP addresses."
            echo "错误：没有活动的 IB 关联接口具有 IP 地址。"
            return 1
        fi
        
        # Selection logic: Prefer interface without capital 'P'
        SELECTED_ETH=""
        for iface in "${CANDIDATE_ETH_IFS[@]}"; do
            if [[ "$iface" != *"P"* ]]; then
                SELECTED_ETH="$iface"
                break
            fi
        done
        
        # Fallback: Use the first one if all have 'P' or none found yet
        if [[ -z "$SELECTED_ETH" ]]; then
            SELECTED_ETH="${CANDIDATE_ETH_IFS[0]}"
        fi
        
        ETH_IF="$SELECTED_ETH"
        echo "  Detected ETH_IF: $ETH_IF"
        echo "  检测到的 ETH_IF: $ETH_IF"
    fi
}

# Function to detect local IP
# 检测本地 IP 的函数

detect_local_ip() {
    if [[ -n "$LOCAL_IP" ]]; then
        return 0
    fi

    # Ensure interface is detected if not provided
# 如果未提供，确保接口已被检测

    if [[ -z "$ETH_IF" ]]; then
        detect_interfaces || return 1
    fi

    # Get CIDR of the selected ETH_IF
# 获取所选 ETH_IF 的 CIDR

    CIDR=$(ip -o -f inet addr show "$ETH_IF" | awk '{print $4}' | head -n 1)
    
    if [[ -z "$CIDR" ]]; then
        echo "Error: Could not determine IP/CIDR for interface $ETH_IF"
        echo "错误：无法确定接口 $ETH_IF 的 IP/CIDR"
        return 1
    fi
    
    LOCAL_IP=${CIDR%/*}
    echo "  Detected Local IP: $LOCAL_IP ($CIDR)"
    echo "  检测到的本地 IP: $LOCAL_IP ($CIDR)"
}

# Function to detect cluster nodes
# 检测集群节点的函数

detect_nodes() {
    detect_local_ip || return 1

    # If nodes are already set, populate PEER_NODES and return
# 如果节点已设置，填充 PEER_NODES 并返回

    if [[ -n "$NODES_ARG" ]]; then
        PEER_NODES=()
        IFS=',' read -ra ALL_NODES <<< "$NODES_ARG"
        for node in "${ALL_NODES[@]}"; do
            node=$(echo "$node" | xargs)
            if [[ "$node" != "$LOCAL_IP" ]]; then
                PEER_NODES+=("$node")
            fi
        done
        return 0
    fi

    echo "Auto-detecting nodes..."
    echo "正在自动检测节点..."
    
    if ! command -v nc &> /dev/null; then
        echo "Error: nc (netcat) not found. Please install netcat."
        echo "错误：未找到 nc (netcat)。请安装 netcat。"
        return 1
    fi
    
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 not found. Please install python3."
        echo "错误：未找到 python3。请安装 python3。"
        return 1
    fi

    DETECTED_IPS=("$LOCAL_IP")
    PEER_NODES=()
    
    echo "  Scanning for SSH peers on $CIDR..."
    echo "  正在扫描 $CIDR 上的 SSH 对等节点..."
    
    # Generate list of IPs using python
# 使用 Python 生成 IP 列表

    ALL_IPS=$(python3 -c "import ipaddress, sys; [print(ip) for ip in ipaddress.ip_network(sys.argv[1], strict=False).hosts()]" "$CIDR")
    
    TEMP_IPS_FILE=$(mktemp)
    
    # Scan in parallel
# 并行扫描

    for ip in $ALL_IPS; do
        # Skip own IP
# 跳过自己的 IP

        if [[ "$ip" == "$LOCAL_IP" ]]; then continue; fi
        
        (
            # Check port 22 with 1 second timeout
# 使用 1 秒超时检查 22 端口

            if nc -z -w 1 "$ip" 22 &>/dev/null; then
                echo "$ip" >> "$TEMP_IPS_FILE"
            fi
        ) &
    done
    
    # Wait for all background scans to complete
# 等待所有后台扫描完成

    wait
    
    # Read found IPs
# 读取找到的 IP

    if [[ -f "$TEMP_IPS_FILE" ]]; then
        while read -r ip; do
             DETECTED_IPS+=("$ip")
             PEER_NODES+=("$ip")
             echo "  Found peer: $ip"
             echo "  找到对等节点：$ip"
        done < "$TEMP_IPS_FILE"
        rm -f "$TEMP_IPS_FILE"
    fi
    
    # Sort IPs
# 排序 IP

    IFS=$'\n' SORTED_IPS=($(sort <<<"${DETECTED_IPS[*]}"))
    unset IFS
    
    NODES_ARG=$(IFS=,; echo "${SORTED_IPS[*]}")
    echo "  Cluster Nodes: $NODES_ARG"
    echo "  集群节点：$NODES_ARG"
}
