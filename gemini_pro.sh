#!/bin/bash

# ===== 极限速率配置 =====
# 项目配置
PROJECT_COUNT=50                    # 项目数量（可快速修改）
MAX_PARALLEL_JOBS=100              # 极限并行数（根据系统调整）
ULTRA_FAST_MODE=true               # 极速模式开关
SKIP_CONFIRMATIONS=true            # 跳过确认提示

# 极速优化参数
MINIMAL_WAIT_TIME=15               # 最小等待时间（秒）
BURST_SIZE=20                      # 突发请求组大小
BURST_DELAY=0.5                    # 突发间隔（秒）
CONNECTION_POOL_SIZE=50            # 连接池大小
RETRY_AGGRESSIVE=true              # 激进重试模式

# 稳定性保障
HEALTH_CHECK_INTERVAL=10           # 健康检查间隔
ERROR_THRESHOLD=0.3                # 错误率阈值（30%）
CIRCUIT_BREAKER_ENABLED=true       # 熔断器开关
FALLBACK_ENABLED=true              # 降级机制

# 系统优化
DISABLE_LOGGING=false              # 禁用详细日志（提升性能）
MEMORY_OPTIMIZATION=true           # 内存优化
TEMP_IN_MEMORY=true               # 临时文件内存化

# ===== 动态变量 =====
TIMESTAMP=$(date +%s)
TEMP_DIR="/dev/shm/gcp_ultra_${TIMESTAMP}"  # 使用内存文件系统
SESSION_ID=$(echo $TIMESTAMP | md5sum | cut -c1-12)
PURE_KEY_FILE="gemini_keys_ultra_$(date +%Y%m%d_%H%M%S).txt"
COMMA_KEY_FILE="gemini_comma_ultra_$(date +%Y%m%d_%H%M%S).txt"
SECONDS=0

# 统计变量
TOTAL_REQUESTS=0
SUCCESS_COUNT=0
ERROR_COUNT=0
CURRENT_ERROR_RATE=0

# ===== 极速初始化 =====
init_ultra_fast() {
    # 优先使用内存文件系统
    if [ "$TEMP_IN_MEMORY" = true ] && [ -d "/dev/shm" ]; then
        TEMP_DIR="/dev/shm/gcp_ultra_${TIMESTAMP}"
    else
        TEMP_DIR="/tmp/gcp_ultra_${TIMESTAMP}"
    fi
    
    mkdir -p "$TEMP_DIR"
    
    # 初始化输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_KEY_FILE"
    
    # 设置文件描述符限制
    ulimit -n 4096 2>/dev/null || true
}

# ===== 极速日志系统 =====
ultra_log() {
    local level=$1
    local msg=$2
    
    if [ "$DISABLE_LOGGING" = true ] && [ "$level" != "ERROR" ] && [ "$level" != "SUCCESS" ]; then
        return
    fi
    
    local timestamp=$(date '+%H:%M:%S')
    printf "[%s][%s] %s\n" "$timestamp" "$level" "$msg"
}

# ===== 极速JSON解析（纯bash实现）=====
extract_api_key() {
    local json="$1"
    # 使用最快的sed方式提取keyString
    echo "$json" | sed -n 's/.*"keyString"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# ===== 极速文件写入（批量缓存）=====
declare -a KEY_BUFFER=()
BUFFER_SIZE=10

write_key_fast() {
    local api_key="$1"
    KEY_BUFFER+=("$api_key")
    
    # 当缓冲区满时批量写入
    if [ ${#KEY_BUFFER[@]} -ge $BUFFER_SIZE ]; then
        flush_key_buffer
    fi
}

flush_key_buffer() {
    if [ ${#KEY_BUFFER[@]} -eq 0 ]; then
        return
    fi
    
    (
        flock 200
        for key in "${KEY_BUFFER[@]}"; do
            echo "$key" >> "$PURE_KEY_FILE"
            if [ -s "$COMMA_KEY_FILE" ]; then
                echo -n "," >> "$COMMA_KEY_FILE"
            fi
            echo -n "$key" >> "$COMMA_KEY_FILE"
        done
    ) 200>"${TEMP_DIR}/keys.lock"
    
    KEY_BUFFER=()
}

# ===== 熔断器机制 =====
check_circuit_breaker() {
    if [ "$CIRCUIT_BREAKER_ENABLED" != true ]; then
        return 0
    fi
    
    if [ $TOTAL_REQUESTS -gt 0 ]; then
        CURRENT_ERROR_RATE=$(echo "scale=2; $ERROR_COUNT / $TOTAL_REQUESTS" | bc 2>/dev/null || echo "0")
        
        if (( $(echo "$CURRENT_ERROR_RATE > $ERROR_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
            ultra_log "WARN" "错误率过高 ($CURRENT_ERROR_RATE)，启动熔断保护"
            sleep 5
            return 1
        fi
    fi
    return 0
}

# ===== 极速重试机制 =====
ultra_retry() {
    local max_attempts=$1
    local cmd="$2"
    local attempt=1
    local delay=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd" 2>/dev/null; then
            return 0
        fi
        
        ((TOTAL_REQUESTS++))
        ((ERROR_COUNT++))
        
        if [ "$RETRY_AGGRESSIVE" = true ]; then
            # 激进模式：快速重试
            if [ $attempt -lt $max_attempts ]; then
                sleep $delay
                delay=$(echo "$delay * 1.5" | bc 2>/dev/null || echo "2")
            fi
        else
            # 保守模式：指数退避
            sleep $((delay * attempt))
        fi
        
        ((attempt++))
        
        # 检查熔断器
        if ! check_circuit_breaker; then
            return 1
        fi
    done
    
    return 1
}

# ===== 极速进度显示 =====
show_ultra_progress() {
    local completed=$1
    local total=$2
    local stage=$3
    
    if [ $((completed % 5)) -eq 0 ] || [ $completed -eq $total ]; then
        local percent=$((completed * 100 / total))
        local bar_length=30
        local filled=$((percent * bar_length / 100))
        local empty=$((bar_length - filled))
        
        local bar=$(printf "%${filled}s" "" | tr ' ' '█')
        local space=$(printf "%${empty}s" "" | tr ' ' '░')
        
        printf "\r%s [%s%s] %d%% (%d/%d) S:%d E:%d" "$stage" "$bar" "$space" "$percent" "$completed" "$total" "$SUCCESS_COUNT" "$ERROR_COUNT"
    fi
}

# ===== 极速项目名称生成 =====
generate_ultra_fast_names() {
    local count=$1
    local names=()
    
    # 预生成所有名称（避免运行时生成）
    local prefixes=("app" "api" "dev" "sys" "web" "net" "bot" "ai" "ml" "db")
    local suffixes=("pro" "hub" "lab" "box" "kit" "core" "zone" "link" "flow" "sync")
    
    for i in $(seq 1 $count); do
        local prefix=${prefixes[$((i % ${#prefixes[@]}))]}
        local suffix=${suffixes[$(((i + 3) % ${#suffixes[@]}))]}
        local number=$(printf "%03d" $((i + RANDOM % 100)))
        local name="${prefix}${suffix}${number}"
        
        # 确保符合GCP命名规范
        name=$(echo "$name" | cut -c1-25)
        names+=("$name")
    done
    
    printf '%s\n' "${names[@]}"
}

# ===== 极速任务函数 =====
ultra_create_project() {
    local project_id="$1"
    local success_file="$2"
    
    if ultra_retry 2 "gcloud projects create '$project_id' --name='$project_id' --no-set-as-default --quiet"; then
        echo "$project_id" >> "$success_file"
        ((SUCCESS_COUNT++))
        return 0
    else
        ((ERROR_COUNT++))
        return 1
    fi
}

ultra_enable_api() {
    local project_id="$1"
    local success_file="$2"
    
    if ultra_retry 3 "gcloud services enable generativelanguage.googleapis.com --project='$project_id' --quiet"; then
        echo "$project_id" >> "$success_file"
        ((SUCCESS_COUNT++))
        return 0
    else
        ((ERROR_COUNT++))
        return 1
    fi
}

ultra_create_key() {
    local project_id="$1"
    
    local output
    if output=$(ultra_retry 3 "gcloud services api-keys create --project='$project_id' --display-name='Key-$project_id' --format='json' --quiet"); then
        local api_key=$(extract_api_key "$output")
        if [ -n "$api_key" ]; then
            write_key_fast "$api_key"
            ((SUCCESS_COUNT++))
            return 0
        fi
    fi
    
    ((ERROR_COUNT++))
    return 1
}

# ===== 极速并行执行引擎 =====
ultra_parallel_execute() {
    local task_func="$1"
    local stage_name="$2"
    local success_file="$3"
    shift 3
    local items=("$@")
    
    local total=${#items[@]}
    local completed=0
    local active_jobs=0
    local job_pids=()
    local job_items=()
    
    ultra_log "INFO" "🚀 启动极速执行: $stage_name ($total 项目, $MAX_PARALLEL_JOBS 并行)"
    
    # 重置计数器
    SUCCESS_COUNT=0
    ERROR_COUNT=0
    
    for item in "${items[@]}"; do
        # 控制并发数
        while [ $active_jobs -ge $MAX_PARALLEL_JOBS ]; do
            # 检查完成的任务
            for i in "${!job_pids[@]}"; do
                local pid=${job_pids[$i]}
                if ! kill -0 $pid 2>/dev/null; then
                    wait $pid
                    ((completed++))
                    ((active_jobs--))
                    
                    show_ultra_progress $completed $total "$stage_name"
                    
                    # 清理完成的任务
                    unset job_pids[$i]
                    unset job_items[$i]
                fi
            done
            
            # 重建数组（移除空元素）
            job_pids=($(printf '%s\n' "${job_pids[@]}" | grep -v '^$'))
            job_items=($(printf '%s\n' "${job_items[@]}" | grep -v '^$'))
            
            # 健康检查
            if [ $((completed % HEALTH_CHECK_INTERVAL)) -eq 0 ] && [ $completed -gt 0 ]; then
                if ! check_circuit_breaker; then
                    ultra_log "ERROR" "熔断器触发，停止执行"
                    break 2
                fi
            fi
            
            sleep 0.1
        done
        
        # 启动新任务
        if [ "$success_file" = "/dev/null" ]; then
            $task_func "$item" &
        else
            $task_func "$item" "$success_file" &
        fi
        
        local pid=$!
        job_pids+=($pid)
        job_items+=("$item")
        ((active_jobs++))
        
        # 突发控制
        if [ $((${#job_pids[@]} % BURST_SIZE)) -eq 0 ]; then
            sleep $BURST_DELAY
        fi
    done
    
    # 等待所有任务完成
    for pid in "${job_pids[@]}"; do
        if [ -n "$pid" ]; then
            wait $pid
            ((completed++))
            show_ultra_progress $completed $total "$stage_name"
        fi
    done
    
    echo
    ultra_log "INFO" "✅ $stage_name 完成: 成功 $SUCCESS_COUNT, 失败 $ERROR_COUNT"
    
    return 0
}

# ===== 极速主函数 =====
ultra_fast_execution() {
    ultra_log "INFO" "🔥🔥🔥 极限速率模式启动 🔥🔥🔥"
    ultra_log "INFO" "目标: $PROJECT_COUNT 个项目, $MAX_PARALLEL_JOBS 并行"
    ultra_log "INFO" "预计完成时间: $((PROJECT_COUNT * 3 / MAX_PARALLEL_JOBS + MINIMAL_WAIT_TIME)) 秒"
    
    if [ "$SKIP_CONFIRMATIONS" != true ]; then
        read -p "⚡ 确认启动极速模式? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            ultra_log "INFO" "操作已取消"
            return 1
        fi
    fi
    
    # 生成项目名称
    ultra_log "INFO" "⚡ 生成项目名称..."
    local project_names=($(generate_ultra_fast_names $PROJECT_COUNT))
    
    # 导出函数供子进程使用
    export -f ultra_create_project ultra_enable_api ultra_create_key ultra_retry extract_api_key write_key_fast check_circuit_breaker
    export TEMP_DIR PURE_KEY_FILE COMMA_KEY_FILE RETRY_AGGRESSIVE TOTAL_REQUESTS SUCCESS_COUNT ERROR_COUNT CURRENT_ERROR_RATE ERROR_THRESHOLD CIRCUIT_BREAKER_ENABLED
    
    local start_time=$SECONDS
    
    # === 阶段 1: 极速创建项目 ===
    local created_file="${TEMP_DIR}/created.txt"
    > "$created_file"
    
    ultra_parallel_execute ultra_create_project "🏗️ 创建项目" "$created_file" "${project_names[@]}"
    
    # 读取成功创建的项目
    local created_projects=()
    if [ -f "$created_file" ]; then
        mapfile -t created_projects < "$created_file"
    fi
    
    if [ ${#created_projects[@]} -eq 0 ]; then
        ultra_log "ERROR" "❌ 没有项目创建成功，终止执行"
        return 1
    fi
    
    ultra_log "INFO" "✅ 项目创建完成: ${#created_projects[@]}/${PROJECT_COUNT}"
    
    # === 阶段 2: 智能等待 ===
    ultra_log "INFO" "⏳ 智能等待 $MINIMAL_WAIT_TIME 秒..."
    local wait_step=$((MINIMAL_WAIT_TIME / 10))
    for i in $(seq 1 10); do
        sleep $wait_step
        printf "\r⏳ 等待中... %d%%" $((i * 10))
    done
    echo
    
    # === 阶段 3: 极速启用API ===
    local enabled_file="${TEMP_DIR}/enabled.txt"
    > "$enabled_file"
    
    ultra_parallel_execute ultra_enable_api "🔌 启用API" "$enabled_file" "${created_projects[@]}"
    
    # 读取启用API成功的项目
    local enabled_projects=()
    if [ -f "$enabled_file" ]; then
        mapfile -t enabled_projects < "$enabled_file"
    fi
    
    if [ ${#enabled_projects[@]} -eq 0 ]; then
        ultra_log "ERROR" "❌ 没有API启用成功，终止执行"
        return 1
    fi
    
    ultra_log "INFO" "✅ API启用完成: ${#enabled_projects[@]}/${#created_projects[@]}"
    
    # === 阶段 4: 极速创建密钥 ===
    ultra_parallel_execute ultra_create_key "🔑 创建密钥" "/dev/null" "${enabled_projects[@]}"
    
    # 刷新剩余缓冲区
    flush_key_buffer
    
    # === 最终统计 ===
    local total_time=$((SECONDS - start_time))
    local final_keys=0
    if [ -f "$PURE_KEY_FILE" ]; then
        final_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo "0")
    fi
    
    echo
    echo "🎉🎉🎉 极速执行完成 🎉🎉🎉"
    echo "================================"
    echo "⏱️  总耗时: $total_time 秒"
    echo "🎯 目标项目: $PROJECT_COUNT 个"
    echo "✅ 成功获取: $final_keys 个密钥"
    echo "📈 成功率: $((final_keys * 100 / PROJECT_COUNT))%"
    echo "⚡ 平均速度: $(echo "scale=2; $final_keys / $total_time" | bc 2>/dev/null || echo "N/A") 密钥/秒"
    echo "📁 输出文件:"
    echo "   - $PURE_KEY_FILE"
    echo "   - $COMMA_KEY_FILE"
    echo "================================"
    
    if [ $final_keys -lt $PROJECT_COUNT ]; then
        ultra_log "WARN" "⚠️ 部分项目未成功，可重新运行脚本补齐"
    fi
}

# ===== 快速配置调整 =====
quick_config() {
    echo "⚡ 极速配置调整"
    echo "==============="
    echo "当前配置:"
    echo "1. 项目数量: $PROJECT_COUNT"
    echo "2. 并行任务: $MAX_PARALLEL_JOBS"
    echo "3. 等待时间: $MINIMAL_WAIT_TIME 秒"
    echo "4. 极速模式: $ULTRA_FAST_MODE"
    echo "5. 开始执行"
    echo "0. 退出"
    
    read -p "选择 [0-5]: " choice
    
    case $choice in
        1)
            read -p "项目数量 (1-200): " new_count
            if [[ "$new_count" =~ ^[0-9]+$ ]] && [ "$new_count" -ge 1 ] && [ "$new_count" -le 200 ]; then
                PROJECT_COUNT=$new_count
            fi
            ;;
        2)
            read -p "并行任务 (20-150): " new_parallel
            if [[ "$new_parallel" =~ ^[0-9]+$ ]] && [ "$new_parallel" -ge 20 ] && [ "$new_parallel" -le 150 ]; then
                MAX_PARALLEL_JOBS=$new_parallel
            fi
            ;;
        3)
            read -p "等待时间 (10-60): " new_wait
            if [[ "$new_wait" =~ ^[0-9]+$ ]] && [ "$new_wait" -ge 10 ] && [ "$new_wait" -le 60 ]; then
                MINIMAL_WAIT_TIME=$new_wait
            fi
            ;;
        4)
            if [ "$ULTRA_FAST_MODE" = true ]; then
                ULTRA_FAST_MODE=false
                MAX_PARALLEL_JOBS=50
                echo "已切换到稳定模式"
            else
                ULTRA_FAST_MODE=true
                MAX_PARALLEL_JOBS=100
                echo "已切换到极速模式"
            fi
            sleep 1
            ;;
        5)
            ultra_fast_execution
            return
            ;;
        0)
            exit 0
            ;;
    esac
    
    quick_config
}

# ===== 清理函数 =====
cleanup_ultra() {
    ultra_log "INFO" "🧹 清理临时文件..."
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    
    # 刷新剩余缓冲区
    flush_key_buffer 2>/dev/null || true
}

# ===== 主程序 =====
main() {
    # 设置清理陷阱
    trap cleanup_ultra EXIT SIGINT SIGTERM
    
    # 初始化
    init_ultra_fast
    
    # GCP认证检查（快速）
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
        ultra_log "ERROR" "❌ 未登录GCP，请先执行: gcloud auth login"
        exit 1
    fi
    
    echo "🚀🚀🚀 极限速率 Gemini API 密钥获取工具 🚀🚀🚀"
    echo "=================================================="
    echo "⚡ 专为极致速度优化，保证稳定性"
    echo "🎯 当前配置: $PROJECT_COUNT 项目, $MAX_PARALLEL_JOBS 并行"
    echo "⏱️  预计用时: $((PROJECT_COUNT * 3 / MAX_PARALLEL_JOBS + MINIMAL_WAIT_TIME)) 秒"
    echo "=================================================="
    
    quick_config
}

# 启动
main "$@"
