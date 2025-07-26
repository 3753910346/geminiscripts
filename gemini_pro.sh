#!/bin/bash

# ===== 配置 =====
# 自动生成随机用户名
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=175
MAX_PARALLEL_JOBS=15  # 降低并发数以提高稳定性
MAX_RETRY_ATTEMPTS=3
SECONDS=0

# 文件配置
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"

# 创建临时目录
mkdir -p "$TEMP_DIR"

# ===== 工具函数 =====

# 统一日志函数
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${TEMP_DIR}/script.log"
}

# 改进的JSON解析函数
parse_json() {
    local json="$1"
    local field="$2"
    
    if [ -z "$json" ]; then 
        log "ERROR" "parse_json: 输入JSON为空"
        return 1
    fi

    # 检查是否有有效的JSON结构
    if ! echo "$json" | grep -q '{.*}'; then
        log "ERROR" "parse_json: 输入不是有效的JSON格式"
        return 1
    fi

    local value=""
    case "$field" in
        ".keyString")
            # 更精确的keyString提取
            value=$(echo "$json" | sed -n 's/.*"keyString"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
            ;;
        ".[0].name")
            # 提取第一个name字段
            value=$(echo "$json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
            ;;
        *)
            local field_name=$(echo "$field" | tr -d '.["]')
            # 使用更精确的正则表达式
            value=$(echo "$json" | sed -n "s/.*\"$field_name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1)
            if [ -z "$value" ]; then
                # 尝试提取数字或布尔值（不带引号）
                value=$(echo "$json" | sed -n "s/.*\"$field_name\"[[:space:]]*:[[:space:]]*\([^,}[:space:]]*\).*/\1/p" | head -n1)
            fi
            ;;
    esac

    if [ -n "$value" ] && [ "$value" != "null" ]; then
        echo "$value"
        return 0
    else
        log "WARN" "parse_json: 无法提取字段 '$field' 的值"
        return 1
    fi
}

# 改进的文件写入函数（增加错误处理）
write_keys_to_files() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        log "ERROR" "write_keys_to_files: API密钥为空"
        return 1
    fi

    # 验证API密钥格式（基本检查）
    if [[ ! "$api_key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log "WARN" "write_keys_to_files: API密钥格式可能不正确: ${api_key:0:20}..."
    fi

    # 使用文件锁确保写入原子性
    (
        if flock -w 10 200; then
            # 写入纯密钥文件
            echo "$api_key" >> "$PURE_KEY_FILE" || {
                log "ERROR" "写入纯密钥文件失败"
                return 1
            }
            
            # 写入逗号分隔文件
            if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
                echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
            fi
            echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE" || {
                log "ERROR" "写入逗号分隔文件失败"
                return 1
            }
            log "DEBUG" "成功写入API密钥到文件"
        else
            log "ERROR" "获取文件锁超时"
            return 1
        fi
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# 改进的重试函数（增加更智能的错误处理）
retry_with_backoff() {
    local max_attempts=$1
    local cmd=$2
    local attempt=1
    local base_timeout=5
    local max_timeout=60
    
    while [ $attempt -le $max_attempts ]; do
        local timeout=$((base_timeout * attempt))
        if [ $timeout -gt $max_timeout ]; then
            timeout=$max_timeout
        fi
        
        log "DEBUG" "执行命令 (尝试 $attempt/$max_attempts): $cmd"
        
        local error_log="${TEMP_DIR}/error_$(date +%s)_$$.log"
        local start_time=$(date +%s)
        
        if timeout 300 bash -c "$cmd" 2>"$error_log"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log "DEBUG" "命令执行成功 (耗时: ${duration}s)"
            rm -f "$error_log"
            return 0
        else
            local error_code=$?
            local error_msg=$(cat "$error_log" 2>/dev/null || echo "无错误信息")
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            log "WARN" "命令执行失败 (尝试 $attempt/$max_attempts, 耗时: ${duration}s, 退出码: $error_code)"
            log "WARN" "错误信息: $error_msg"
            
            # 检查是否为不可重试的错误
            if [[ "$error_msg" == *"Permission denied"* ]] || 
               [[ "$error_msg" == *"Authentication failed"* ]] ||
               [[ "$error_msg" == *"INVALID_ARGUMENT"* ]] ||
               [[ "$error_msg" == *"already exists"* ]]; then
                log "ERROR" "检测到不可重试错误，停止重试"
                rm -f "$error_log"
                return $error_code
            fi
            
            # 配额错误特殊处理
            if [[ "$error_msg" == *"Quota exceeded"* ]] || 
               [[ "$error_msg" == *"RESOURCE_EXHAUSTED"* ]]; then
                log "WARN" "检测到配额限制，增加等待时间"
                timeout=$((timeout * 2))
            fi
            
            rm -f "$error_log"
            
            if [ $attempt -lt $max_attempts ]; then
                log "INFO" "等待 ${timeout}s 后重试..."
                sleep $timeout
            fi
            
            attempt=$((attempt + 1))
        done
    done
    
    log "ERROR" "命令在 $max_attempts 次尝试后最终失败"
    return 1
}

# 改进的进度条显示
show_progress() {
    local completed=$1
    local total=$2
    local prefix=${3:-"进度"}
    
    if [ $total -le 0 ]; then
        printf "\r%-80s\r[%s: 总数无效]" " " "$prefix"
        return
    fi
    
    # 确保completed不超过total
    if [ $completed -gt $total ]; then 
        completed=$total
    fi
    
    local percent=$((completed * 100 / total))
    local bar_length=40
    local completed_chars=$((percent * bar_length / 100))
    
    local progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '█')
    local remaining_bar=$(printf "%$((bar_length - completed_chars))s" "" | tr ' ' '░')
    
    printf "\r%-80s\r[%s%s] %3d%% (%d/%d) %s" \
        " " "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total" "$prefix"
}

# 配额检查函数（改进版）
check_quota() {
    log "INFO" "检查GCP项目创建配额..."
    
    local current_project=$(gcloud config get-value project 2>/dev/null)
    if [ -z "$current_project" ]; then
        log "WARN" "未设置默认项目，跳过配额检查"
        read -p "是否继续执行? [y/N]: " continue_no_quota
        if [[ "$continue_no_quota" =~ ^[Yy]$ ]]; then
            return 0
        else
            return 1
        fi
    fi

    # 尝试获取配额信息
    local quota_output
    local projects_quota=""
    
    # 首先尝试标准命令
    if quota_output=$(gcloud services quota list \
        --service=cloudresourcemanager.googleapis.com \
        --consumer=projects/$current_project \
        --filter='metric=cloudresourcemanager.googleapis.com/project_create_requests' \
        --format=json 2>/dev/null); then
        projects_quota=$(echo "$quota_output" | grep -oP '(?<="effectiveLimit": ")[^"]+' | head -n1)
    fi
    
    # 如果标准命令失败，尝试alpha命令
    if [ -z "$projects_quota" ]; then
        if quota_output=$(gcloud alpha services quota list \
            --service=cloudresourcemanager.googleapis.com \
            --consumer=projects/$current_project \
            --filter='metric(cloudresourcemanager.googleapis.com/project_create_requests)' \
            --format=json 2>/dev/null); then
            projects_quota=$(echo "$quota_output" | grep -oP '(?<="INT64": ")[^"]+' | head -n1)
        fi
    fi

    if [ -z "$projects_quota" ] || ! [[ "$projects_quota" =~ ^[0-9]+$ ]]; then
        log "WARN" "无法获取准确的配额信息，建议手动检查"
        read -p "是否继续执行? [y/N]: " continue_no_quota
        if [[ "$continue_no_quota" =~ ^[Yy]$ ]]; then
            return 0
        else
            return 1
        fi
    fi

    log "INFO" "检测到项目创建配额: $projects_quota"
    
    if [ "$TOTAL_PROJECTS" -gt "$projects_quota" ]; then
        log "WARN" "计划创建项目数($TOTAL_PROJECTS) > 配额限制($projects_quota)"
        echo "建议选项:"
        echo "1. 调整为配额限制内的数量 ($projects_quota)"
        echo "2. 继续尝试（可能部分失败）"
        echo "3. 取消操作"
        
        read -p "请选择 [1/2/3]: " quota_choice
        case $quota_choice in
            1) 
                TOTAL_PROJECTS=$projects_quota
                log "INFO" "已调整项目数为: $TOTAL_PROJECTS"
                ;;
            2) 
                log "WARN" "将尝试创建 $TOTAL_PROJECTS 个项目，可能遇到配额限制"
                ;;
            3|*) 
                log "INFO" "操作已取消"
                return 1
                ;;
        esac
    fi
    
    return 0
}

# 项目处理函数（改进版）
process_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    
    log "INFO" "[$project_num/$total] 开始处理项目: $project_id"
    
    # 1. 创建项目
    log "DEBUG" "[$project_num] 创建项目: $project_id"
    local create_cmd="gcloud projects create \"$project_id\" --name=\"$project_id\" --no-set-as-default --quiet"
    
    if ! retry_with_backoff $MAX_RETRY_ATTEMPTS "$create_cmd"; then
        log "ERROR" "[$project_num] 项目创建失败: $project_id"
        return 1
    fi
    
    log "INFO" "[$project_num] 项目创建成功，等待传播..."
    sleep 8  # 减少等待时间但保持稳定性
    
    # 2. 启用API
    log "DEBUG" "[$project_num] 启用Generative Language API"
    local enable_cmd="gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"
    
    if ! retry_with_backoff $MAX_RETRY_ATTEMPTS "$enable_cmd"; then
        log "ERROR" "[$project_num] API启用失败: $project_id"
        return 1
    fi
    
    # 等待API启用完成
    sleep 3
    
    # 3. 创建API密钥
    log "DEBUG" "[$project_num] 创建API密钥"
    local key_cmd="gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key-$project_id\" --format=json --quiet"
    local create_output
    
    if ! create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "$key_cmd"); then
        log "ERROR" "[$project_num] API密钥创建失败: $project_id"
        return 1
    fi
    
    # 解析API密钥
    local api_key
    if api_key=$(parse_json "$create_output" ".keyString"); then
        log "SUCCESS" "[$project_num] 成功获取API密钥: $project_id"
        if write_keys_to_files "$api_key"; then
            log "DEBUG" "[$project_num] API密钥已保存到文件"
            return 0
        else
            log "ERROR" "[$project_num] API密钥保存失败: $project_id"
            return 1
        fi
    else
        log "ERROR" "[$project_num] API密钥解析失败: $project_id"
        return 1
    fi
}

# 改进的并行执行函数
run_parallel() {
    local task_func="$1"
    shift
    local items=("$@")
    local total_items=${#items[@]}
    
    if [ $total_items -eq 0 ]; then
        log "INFO" "没有项目需要处理"
        return 0
    fi
    
    log "INFO" "开始并行执行 $task_func (最大并发: $MAX_PARALLEL_JOBS)"
    
    local pids=()
    local active_jobs=0
    local completed=0
    local success=0
    local failed=0
    
    # 创建结果文件
    local result_file="${TEMP_DIR}/parallel_results.txt"
    > "$result_file"
    
    for i in "${!items[@]}"; do
        local item="${items[i]}"
        local item_num=$((i + 1))
        
        # 等待直到有空闲槽位
        while [ $active_jobs -ge $MAX_PARALLEL_JOBS ]; do
            # 检查是否有进程完成
            for j in "${!pids[@]}"; do
                local pid="${pids[j]}"
                if ! kill -0 "$pid" 2>/dev/null; then
                    # 进程已完成
                    wait "$pid"
                    local exit_code=$?
                    
                    if [ $exit_code -eq 0 ]; then
                        ((success++))
                        echo "SUCCESS:$pid" >> "$result_file"
                    else
                        ((failed++))
                        echo "FAILED:$pid" >> "$result_file"
                    fi
                    
                    ((completed++))
                    ((active_jobs--))
                    
                    # 从数组中移除已完成的PID
                    unset pids[j]
                    pids=("${pids[@]}")  # 重新索引数组
                    
                    show_progress $completed $total_items "$task_func"
                    break
                fi
            done
            
            if [ $active_jobs -ge $MAX_PARALLEL_JOBS ]; then
                sleep 0.5
            fi
        done
        
        # 启动新任务
        "$task_func" "$item" "$item_num" "$total_items" &
        local new_pid=$!
        pids+=("$new_pid")
        ((active_jobs++))
        
        # 短暂延时避免API限制
        sleep 0.2
    done
    
    # 等待所有剩余任务完成
    log "INFO" ""
    log "INFO" "等待剩余 $active_jobs 个任务完成..."
    
    for pid in "${pids[@]}"; do
        wait "$pid"
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            ((success++))
        else
            ((failed++))
        fi
        
        ((completed++))
        show_progress $completed $total_items "$task_func"
    done
    
    echo ""
    log "INFO" "并行执行完成 - 成功: $success, 失败: $failed"
    
    # 清理结果文件
    rm -f "$result_file"
    
    return $([ $failed -eq 0 ] && echo 0 || echo 1)
}

# 生成报告函数（改进版）
generate_report() {
    local success=$1
    local failed=$2
    local total=$3
    local operation=${4:-"处理"}
    
    local success_rate=0
    if [ $total -gt 0 ]; then
        success_rate=$(awk "BEGIN {printf \"%.2f\", $success * 100 / $total}")
    fi
    
    local duration=$SECONDS
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    echo ""
    echo "=========================================="
    echo "           执行报告"
    echo "=========================================="
    echo "操作类型: $operation"
    echo "总计尝试: $total"
    echo "成功数量: $success"
    echo "失败数量: $failed"
    echo "成功率: $success_rate%"
    
    if [ $success -gt 0 ]; then
        local avg_time=$(awk "BEGIN {printf \"%.1f\", $duration / $success}")
        echo "平均处理时间: ${avg_time}秒/项目"
    fi
    
    printf "总执行时间: "
    if [ $hours -gt 0 ]; then
        printf "%d小时 " $hours
    fi
    if [ $minutes -gt 0 ]; then
        printf "%d分钟 " $minutes
    fi
    printf "%d秒\n" $seconds
    
    if [ $success -gt 0 ]; then
        echo ""
        echo "输出文件:"
        echo "- 纯密钥文件: $PURE_KEY_FILE"
        echo "- 逗号分隔文件: $COMMA_SEPARATED_KEY_FILE"
        
        local key_count=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
        echo "- 实际密钥数量: $key_count"
    fi
    
    echo "=========================================="
}

# 删除项目函数
delete_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    
    log "INFO" "[$project_num/$total] 删除项目: $project_id"
    
    local delete_cmd="gcloud projects delete \"$project_id\" --quiet"
    
    if retry_with_backoff 2 "$delete_cmd"; then
        log "SUCCESS" "[$project_num] 项目删除成功: $project_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已删除: $project_id" >> "$DELETION_LOG"
        return 0
    else
        log "ERROR" "[$project_num] 项目删除失败: $project_id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除失败: $project_id" >> "$DELETION_LOG"
        return 1
    fi
}

# 从现有项目提取密钥
extract_key_from_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    
    log "INFO" "[$project_num/$total] 处理现有项目: $project_id"
    
    # 1. 确保API已启用
    local enable_cmd="gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"
    if ! retry_with_backoff $MAX_RETRY_ATTEMPTS "$enable_cmd"; then
        log "ERROR" "[$project_num] API启用失败: $project_id"
        return 1
    fi
    
    # 2. 检查现有密钥
    local existing_keys
    local list_cmd="gcloud services api-keys list --project=\"$project_id\" --format=json"
    
    if existing_keys=$(retry_with_backoff 2 "$list_cmd"); then
        if [ -n "$existing_keys" ] && [ "$existing_keys" != "[]" ]; then
            # 尝试获取第一个现有密钥
            local key_name
            if key_name=$(parse_json "$existing_keys" ".[0].name"); then
                log "DEBUG" "[$project_num] 找到现有密钥: $key_name"
                
                local get_key_cmd="gcloud services api-keys get-key-string \"$key_name\" --format=json"
                local key_details
                
                if key_details=$(retry_with_backoff 2 "$get_key_cmd"); then
                    local api_key
                    if api_key=$(parse_json "$key_details" ".keyString"); then
                        log "SUCCESS" "[$project_num] 获取现有密钥成功: $project_id"
                        write_keys_to_files "$api_key"
                        return 0
                    fi
                fi
            fi
        fi
    fi
    
    # 3. 创建新密钥
    log "DEBUG" "[$project_num] 创建新API密钥"
    local create_cmd="gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key-Extract\" --format=json --quiet"
    local create_output
    
    if create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "$create_cmd"); then
        local api_key
        if api_key=$(parse_json "$create_output" ".keyString"); then
            log "SUCCESS" "[$project_num] 创建新密钥成功: $project_id"
            write_keys_to_files "$api_key"
            return 0
        fi
    fi
    
    log "ERROR" "[$project_num] 无法获取或创建密钥: $project_id"
    return 1
}

# 清理项目API密钥
cleanup_api_keys() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    
    log "INFO" "[$project_num/$total] 清理项目API密钥: $project_id"
    
    local list_cmd="gcloud services api-keys list --project=\"$project_id\" --format=json"
    local existing_keys
    
    if ! existing_keys=$(retry_with_backoff 2 "$list_cmd"); then
        log "WARN" "[$project_num] 无法获取密钥列表: $project_id"
        return 1
    fi
    
    if [ -z "$existing_keys" ] || [ "$existing_keys" = "[]" ]; then
        log "INFO" "[$project_num] 项目无API密钥: $project_id"
        return 0
    fi
    
    # 解析所有密钥名称
    local key_names
    readarray -t key_names < <(echo "$existing_keys" | grep -o '"name": *"[^"]*"' | sed 's/"name": *"\([^"]*\)"/\1/')
    
    local deleted_count=0
    local total_keys=${#key_names[@]}
    
    for key_name in "${key_names[@]}"; do
        if [ -n "$key_name" ]; then
            local delete_cmd="gcloud services api-keys delete \"$key_name\" --quiet"
            if retry_with_backoff 2 "$delete_cmd"; then
                ((deleted_count++))
                log "DEBUG" "[$project_num] 删除密钥成功: $key_name"
            else
                log "WARN" "[$project_num] 删除密钥失败: $key_name"
            fi
            sleep 0.5  # 避免API限制
        fi
    done
    
    log "INFO" "[$project_num] 清理完成: $project_id (删除 $deleted_count/$total_keys 个密钥)"
    return 0
}

# 获取项目列表
get_project_list() {
    local project_list
    local list_cmd="gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet"
    
    if project_list=$(retry_with_backoff 2 "$list_cmd"); then
        echo "$project_list"
        return 0
    else
        log "ERROR" "无法获取项目列表"
        return 1
    fi
}

# ===== 主要功能函数 =====

# 功能1：删除并重建
delete_and_rebuild() {
    log "INFO" "==================== 功能1：删除并重建 ===================="
    
    # 获取现有项目
    local project_list
    if ! project_list=$(get_project_list); then
        return 1
    fi
    
    if [ -n "$project_list" ]; then
        local projects_array
        readarray -t projects_array <<< "$project_list"
        local project_count=${#projects_array[@]}
        
        log "INFO" "发现 $project_count 个现有项目"
        
        # 显示前几个项目作为示例
        echo "项目示例:"
        for i in "${!projects_array[@]}"; do
            if [ $i -lt 5 ]; then
                echo "  - ${projects_array[i]}"
            elif [ $i -eq 5 ]; then
                echo "  - ... 还有 $((project_count - 5)) 个项目"
                break
            fi
        done
        
        echo ""
        read -p "!!! 警告 !!! 将删除所有 $project_count 个项目并重建。确认请输入 'DELETE-ALL': " confirm
        
        if [ "$confirm" != "DELETE-ALL" ]; then
            log "INFO" "操作已取消"
            return 1
        fi
        
        # 删除现有项目
        log "INFO" "开始删除现有项目..."
        echo "项目删除日志 - $(date)" > "$DELETION_LOG"
        
        export -f delete_project retry_with_backoff log
        export DELETION_LOG TEMP_DIR MAX_RETRY_ATTEMPTS
        
        run_parallel delete_project "${projects_array[@]}"
        
        log "INFO" "等待删除操作传播..."
        sleep 10
    else
        log "INFO" "未发现现有项目，直接开始创建"
    fi
    
    # 检查配额并创建新项目
    if ! check_quota; then
        return 1
    fi
    
    log "INFO" "开始创建 $TOTAL_PROJECTS 个新项目..."
    
    # 初始化输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"
    
    # 生成项目ID列表
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local project_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        
        # 确保项目ID符合GCP规范
        project_id=$(echo "$project_id" | tr -cd 'a-z0-9-' | cut -c 1-30)
        project_id=$(echo "$project_id" | sed 's/-$//')
        
        # 确保以字母开头
        if [[ ! "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
        fi
        
        projects_to_create+=("$project_id")
    done
    
    # 导出必要的函数和变量
    export -f process_project retry_with_backoff log parse_json write_keys_to_files
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE
    
    SECONDS=0
    run_parallel process_project "${projects_to_create[@]}"
    local create_status=$?
    
    # 统计结果
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
    local failed_entries=$((TOTAL_PROJECTS - successful_keys))
    
    generate_report $successful_keys $failed_entries $TOTAL_PROJECTS "删除并重建"
    
    return $create_status
}

# 功能2：创建新项目
create_projects_and_get_keys() {
    log "INFO" "==================== 功能2：创建新项目 ===================="
    
    if ! check_quota; then
        return 1
    fi
    
    log "INFO" "将创建 $TOTAL_PROJECTS 个新项目"
    log "INFO" "用户名前缀: $EMAIL_USERNAME"
    log "INFO" "项目前缀: $PROJECT_PREFIX"
    
    read -p "确认开始创建? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 初始化输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"
    
    # 生成项目ID列表
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local project_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        
        # 规范化项目ID
        project_id=$(echo "$project_id" | tr -cd 'a-z0-9-' | cut -c 1-30)
        project_id=$(echo "$project_id" | sed 's/-$//')
        
        if [[ ! "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
        fi
        
        projects_to_create+=("$project_id")
    done
    
    export -f process_project retry_with_backoff log parse_json write_keys_to_files
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE
    
    SECONDS=0
    run_parallel process_project "${projects_to_create[@]}"
    local create_status=$?
    
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
    local failed_entries=$((TOTAL_PROJECTS - successful_keys))
    
    generate_report $successful_keys $failed_entries $TOTAL_PROJECTS "创建项目"
    
    return $create_status
}

# 功能3：获取现有项目密钥
get_keys_from_existing_projects() {
    log "INFO" "==================== 功能3：获取现有项目密钥 ===================="
    
    local project_list
    if ! project_list=$(get_project_list); then
        return 1
    fi
    
    if [ -z "$project_list" ]; then
        log "INFO" "未发现任何项目"
        return 0
    fi
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目"
    
    # 显示项目示例
    echo "项目示例:"
    for i in "${!projects_array[@]}"; do
        if [ $i -lt 5 ]; then
            echo "  - ${projects_array[i]}"
        elif [ $i -eq 5 ]; then
            echo "  - ... 还有 $((project_count - 5)) 个项目"
            break
        fi
    done
    
    read -p "确认为这些项目获取API密钥? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    # 初始化输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"
    
    export -f extract_key_from_project retry_with_backoff log parse_json write_keys_to_files
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE
    
    SECONDS=0
    run_parallel extract_key_from_project "${projects_array[@]}"
    local extract_status=$?
    
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
    local failed_entries=$((project_count - successful_keys))
    
    generate_report $successful_keys $failed_entries $project_count "获取现有密钥"
    
    return $extract_status
}

# 功能4：删除所有项目
delete_all_existing_projects() {
    log "INFO" "==================== 功能4：删除所有项目 ===================="
    
    local project_list
    if ! project_list=$(get_project_list); then
        return 1
    fi
    
    if [ -z "$project_list" ]; then
        log "INFO" "未发现任何项目"
        return 0
    fi
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目需要删除"
    
    # 显示项目示例
    echo "将要删除的项目示例:"
    for i in "${!projects_array[@]}"; do
        if [ $i -lt 5 ]; then
            echo "  - ${projects_array[i]}"
        elif [ $i -eq 5 ]; then
            echo "  - ... 还有 $((project_count - 5)) 个项目"
            break
        fi
    done
    
    echo ""
    read -p "!!! 危险操作 !!! 确认删除所有 $project_count 个项目? 输入 'DELETE-ALL' 确认: " confirm
    
    if [ "$confirm" != "DELETE-ALL" ]; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    echo "项目删除日志 - $(date)" > "$DELETION_LOG"
    
    export -f delete_project retry_with_backoff log
    export DELETION_LOG TEMP_DIR MAX_RETRY_ATTEMPTS
    
    SECONDS=0
    run_parallel delete_project "${projects_array[@]}"
    local delete_status=$?
    
    # 统计删除结果
    local successful_deletions=$(grep -c "已删除:" "$DELETION_LOG" 2>/dev/null || echo 0)
    local failed_deletions=$((project_count - successful_deletions))
    
    generate_report $successful_deletions $failed_deletions $project_count "删除项目"
    
    log "INFO" "详细删除日志: $DELETION_LOG"
    
    return $delete_status
}

# 功能5：清理API密钥
cleanup_project_api_keys() {
    log "INFO" "==================== 功能5：清理API密钥 ===================="
    
    local project_list
    if ! project_list=$(get_project_list); then
        return 1
    fi
    
    if [ -z "$project_list" ]; then
        log "INFO" "未发现任何项目"
        return 0
    fi
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目"
    
    read -p "确认清理这些项目的API密钥? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    echo "API密钥清理日志 - $(date)" > "$CLEANUP_LOG"
    
    export -f cleanup_api_keys retry_with_backoff log parse_json
    export CLEANUP_LOG TEMP_DIR MAX_RETRY_ATTEMPTS
    
    SECONDS=0
    run_parallel cleanup_api_keys "${projects_array[@]}"
    local cleanup_status=$?
    
    generate_report 0 0 $project_count "清理API密钥"
    
    log "INFO" "详细清理日志: $CLEANUP_LOG"
    
    return $cleanup_status
}

# 配置设置
configure_settings() {
    while true; do
        clear
        echo "=========================================="
        echo "           配置设置"
        echo "=========================================="
        echo "当前配置:"
        echo "1. 项目前缀: $PROJECT_PREFIX"
        echo "2. 项目数量: $TOTAL_PROJECTS"
        echo "3. 最大并发数: $MAX_PARALLEL_JOBS"
        echo "4. 重试次数: $MAX_RETRY_ATTEMPTS"
        echo ""
        echo "0. 返回主菜单"
        echo "=========================================="
        
        read -p "选择要修改的设置 [0-4]: " choice
        
        case $choice in
            1)
                read -p "输入新的项目前缀 (当前: $PROJECT_PREFIX): " new_prefix
                if [ -n "$new_prefix" ] && [[ "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
                    PROJECT_PREFIX="$new_prefix"
                    log "INFO" "项目前缀已更新为: $PROJECT_PREFIX"
                    sleep 1
                elif [ -n "$new_prefix" ]; then
                    echo "错误: 前缀必须以小写字母开头，只能包含小写字母、数字和连字符"
                    sleep 2
                fi
                ;;
            2)
                read -p "输入项目数量 (当前: $TOTAL_PROJECTS): " new_total
                if [[ "$new_total" =~ ^[1-9][0-9]*$ ]]; then
                    TOTAL_PROJECTS=$new_total
                    log "INFO" "项目数量已更新为: $TOTAL_PROJECTS"
                    sleep 1
                elif [ -n "$new_total" ]; then
                    echo "错误: 请输入大于0的整数"
                    sleep 2
                fi
                ;;
            3)
                read -p "输入最大并发数 (当前: $MAX_PARALLEL_JOBS, 建议5-30): " new_parallel
                if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]] && [ "$new_parallel" -le 50 ]; then
                    MAX_PARALLEL_JOBS=$new_parallel
                    log "INFO" "最大并发数已更新为: $MAX_PARALLEL_JOBS"
                    sleep 1
                elif [ -n "$new_parallel" ]; then
                    echo "错误: 请输入1-50之间的整数"
                    sleep 2
                fi
                ;;
            4)
                read -p "输入重试次数 (当前: $MAX_RETRY_ATTEMPTS, 建议1-5): " new_retries
                if [[ "$new_retries" =~ ^[1-5]$ ]]; then
                    MAX_RETRY_ATTEMPTS=$new_retries
                    log "INFO" "重试次数已更新为: $MAX_RETRY_ATTEMPTS"
                    sleep 1
                elif [ -n "$new_retries" ]; then
                    echo "错误: 请输入1-5之间的整数"
                    sleep 2
                fi
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项，请重新选择"
                sleep 1
                ;;
        esac
    done
}

# 显示主菜单
show_menu() {
    clear
    echo "=========================================="
    echo "GCP管理器最终版"
    echo "《本脚本完全免费，禁止任何有关商业行为》"
    echo "请适量创建，推荐50以内，风险自负"
    echo "作者1996ddd留言"
    echo "=========================================="
    
    # 显示当前状态
    local current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
    local current_project=$(gcloud config get-value project 2>/dev/null)
    
    echo "当前状态:"
    echo "  账号: ${current_account:-未登录}"
    echo "  项目: ${current_project:-未设置}"
    echo "  并发: $MAX_PARALLEL_JOBS"
    echo "  重试: $MAX_RETRY_ATTEMPTS"
    echo ""
    
    echo "功能菜单:"
    echo "1. 删除所有项目并重建 (获取API密钥)"
    echo "2. 创建新项目并获取API密钥"
    echo "3. 从现有项目获取API密钥"
    echo "4. 删除所有现有项目"
    echo "5. 清理项目中的API密钥"
    echo "6. 修改配置设置"
    echo ""
    echo "0. 退出程序"
    echo "=========================================="
    
    read -p "请选择功能 [0-6]: " choice
    
    case $choice in
        1) delete_and_rebuild ;;
        2) create_projects_and_get_keys ;;
        3) get_keys_from_existing_projects ;;
        4) delete_all_existing_projects ;;
        5) cleanup_project_api_keys ;;
        6) configure_settings ;;
        0) 
            log "INFO" "程序退出"
            exit 0
            ;;
        *)
            echo "无效选项: $choice"
            sleep 1
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回主菜单..." 
}

# 资源清理函数
cleanup_resources() {
    log "INFO" "执行资源清理..."
    
    # 终止所有子进程
    jobs -p | xargs -r kill 2>/dev/null
    
    # 清理临时目录
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "临时目录已清理: $TEMP_DIR"
    fi
    
    log "INFO" "资源清理完成"
}

# 前置检查
check_prerequisites() {
    log "INFO" "执行前置检查..."
    
    # 检查gcloud命令
    if ! command -v gcloud >/dev/null 2>&1; then
        log "ERROR" "未找到gcloud命令，请安装Google Cloud SDK"
        return 1
    fi
    
    # 检查登录状态
    local current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
    if [ -z "$current_account" ]; then
        log "WARN" "未检测到活跃的GCP账号"
        read -p "是否现在登录? [y/N]: " login_choice
        if [[ "$login_choice" =~ ^[Yy]$ ]]; then
            if ! gcloud auth login; then
                log "ERROR" "登录失败"
                return 1
            fi
        else
            log "WARN" "未登录状态下某些功能可能无法使用"
        fi
    else
        log "INFO" "当前账号: $current_account"
    fi
    
    # 检查必要工具
    for tool in awk sed grep; do
        if ! command -v $tool >/dev/null 2>&1; then
            log "ERROR" "未找到必要工具: $tool"
            return 1
        fi
    done
    
    log "INFO" "前置检查完成"
    return 0
}

# ===== 主程序入口 =====

# 设置退出处理
trap cleanup_resources EXIT SIGINT SIGTERM

# 执行前置检查
if ! check_prerequisites; then
    log "ERROR" "前置检查失败，程序退出"
    exit 1
fi

# 显示欢迎信息
log "INFO" "GCP 1996ddddd开始发动"
log "INFO" "临时目录: $TEMP_DIR"
log "INFO" "生成的用户名: $EMAIL_USERNAME"

# 主循环
while true; do
    show_menu
done
