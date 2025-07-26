#!/bin/bash

# ==============================================================================
#
# 密钥管理器最终版 v2.0
#
# - 该脚本完全免费，请勿进行任何商业行为
# - 作者: 1996
# 
#
# ==============================================================================

# ===== 全局配置 =====
# 自动生成随机用户名和临时目录
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=175
MAX_PARALLEL_JOBS=15  # 建议根据网络和机器性能调整 (5-30)
MAX_RETRY_ATTEMPTS=3
SECONDS=0 # 用于计时

# 文件和目录配置
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"

# 启动时创建临时目录
mkdir -p "$TEMP_DIR"

# ===== 工具函数 =====

# 统一日志函数
log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${TEMP_DIR}/script.log"
}

# 优化版JSON解析函数 (优先使用jq, 失败则回退到sed)
parse_json() {
    local json_input="$1"
    local field="$2"
    local value=""

    if command -v jq &> /dev/null; then
        # 使用 jq 进行解析，更健壮
        value=$(echo "$json_input" | jq -r "$field // \"\"")
    else
        # jq 未安装，使用 sed 作为后备
        # 这是一个简化的sed实现，适用于简单JSON
        local field_name
        field_name=$(echo "$field" | sed 's/^\.//; s/\[[0-9]*\]//g; s/"//g') # 简化字段名
        value=$(echo "$json_input" | grep -o "\"$field_name\": *\"[^\"]*\"" | head -n 1 | cut -d'"' -f4)
    fi
    
    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"
        return 0
    else
        log "WARN" "parse_json: 无法从JSON中提取字段 '$field'"
        return 1
    fi
}

# 文件写入函数 (带文件锁)
write_keys_to_files() {
    local api_key="$1"
    
    if [[ -z "$api_key" ]]; then
        log "ERROR" "write_keys_to_files: 尝试写入空的API密钥"
        return 1
    fi

    # 使用文件锁(flock)确保并发写入时的数据一致性
    (
        if flock -w 10 200; then
            echo "$api_key" >> "$PURE_KEY_FILE"
            if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
                echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
            fi
            echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
            log "DEBUG" "成功写入API密钥到文件"
        else
            log "ERROR" "写入文件失败: 获取文件锁超时"
            return 1
        fi
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# 改进的重试函数 (带指数退避和智能错误识别)
retry_with_backoff() {
    local max_attempts=$1
    shift
    local cmd=("$@") # 将命令及其参数作为数组接收
    local attempt=1
    local base_timeout=5

    while (( attempt <= max_attempts )); do
        log "DEBUG" "执行命令 (尝试 $attempt/$max_attempts): ${cmd[*]}"
        
        local error_log="${TEMP_DIR}/error_$$_${attempt}.log"
        local output
        
        # 执行命令，将标准输出存入变量，标准错误重定向到日志文件
        output=$(eval "${cmd[@]}" 2> "$error_log")
        local exit_code=$?
        local error_msg
        error_msg=$(<"$error_log")
        rm -f "$error_log"

        if (( exit_code == 0 )); then
            log "DEBUG" "命令执行成功"
            echo "$output" # 将成功时的标准输出返回
            return 0
        fi
        
        log "WARN" "命令执行失败 (尝试 $attempt/$max_attempts, 退出码: $exit_code)"
        log "WARN" "错误详情: $error_msg"
        
        # 检查不可重试的错误
        if [[ "$error_msg" == *"Permission denied"* || "$error_msg" == *"Authentication failed"* || "$error_msg" == *"INVALID_ARGUMENT"* || "$error_msg" == *"already exists"* ]]; then
            log "ERROR" "检测到不可重试错误，停止重试。"
            return $exit_code
        fi
        
        # 配额错误特殊处理，加倍等待时间
        if [[ "$error_msg" == *"Quota exceeded"* || "$error_msg" == *"RESOURCE_EXHAUSTED"* ]]; then
            local sleep_time=$((base_timeout * attempt * 2))
            log "WARN" "检测到配额限制，增加等待时间至 ${sleep_time}s"
            sleep "$sleep_time"
        elif (( attempt < max_attempts )); then
            local sleep_time=$((base_timeout * attempt))
            log "INFO" "等待 ${sleep_time}s 后重试..."
            sleep "$sleep_time"
        fi
        
        ((attempt++))
    done
    
    log "ERROR" "命令在 $max_attempts 次尝试后最终失败: ${cmd[*]}"
    return 1
}


# 进度条显示函数
show_progress() {
    local completed=$1
    local total=$2
    local operation_name=${3:-"进度"}
    
    if (( total <= 0 )); then return; fi
    if (( completed > total )); then completed=$total; fi
    
    local percent=$((completed * 100 / total))
    local bar_len=40
    local filled_len=$((bar_len * percent / 100))
    
    local bar
    printf -v bar '%*s' "$filled_len" ''
    bar=${bar// /█}
    
    local empty
    printf -v empty '%*s' "$((bar_len - filled_len))" ''
    empty=${empty// /░}

    printf "\r%-80s" " " # 清除行
    printf "\r[%s%s] %d%% (%d/%d) - %s" "$bar" "$empty" "$percent" "$completed" "$total" "$operation_name"
}

# 配额检查函数
check_quota() {
    log "INFO" "检查GCP项目创建配额..."
    local projects_quota
    projects_quota=$(gcloud services quota list --service=cloudresourcemanager.googleapis.com --filter="metric.value(name.format())='cloudresourcemanager.googleapis.com/project_create_requests'" --format="value(consumerQuotaLimits.value.effectiveLimit)" 2>/dev/null)
    
    if [[ ! "$projects_quota" =~ ^[0-9]+$ ]]; then
        log "WARN" "无法自动获取配额信息，将跳过检查。请自行确保有足够配额。"
        read -p "是否继续执行? [y/N]: " continue_anyway
        [[ "$continue_anyway" =~ ^[Yy]$ ]] || return 1
        return 0
    fi
    
    log "INFO" "当前项目创建配额限制为: $projects_quota"
    if (( TOTAL_PROJECTS > projects_quota )); then
        log "WARN" "计划创建的项目数 ($TOTAL_PROJECTS) 超出配额 ($projects_quota)!"
        read -p "是否自动将创建数量调整为配额允许的最大值 ($projects_quota)? [Y/n]: " adjust_total
        if [[ ! "$adjust_total" =~ ^[Nn]$ ]]; then
            TOTAL_PROJECTS=$projects_quota
            log "INFO" "项目创建数量已调整为: $TOTAL_PROJECTS"
        else
            log "WARN" "将按原计划 ($TOTAL_PROJECTS) 继续，可能会因配额问题而失败。"
        fi
    fi
    return 0
}

# ===== 核心处理函数 =====

# 项目处理函数 (创建项目 -> 启用API -> 创建密钥)
process_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    
    log "INFO" "[$project_num/$total] 开始处理项目: $project_id"
    
    # 1. 创建项目
    if ! retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud projects create \"$project_id\" --name=\"$project_id\" --no-set-as-default --quiet"; then
        log "ERROR" "[$project_num] 项目创建失败: $project_id"
        return 1
    fi
    log "INFO" "[$project_num] 项目创建成功，等待传播 (8s)..."
    sleep 8
    
    # 2. 启用API
    if ! retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"; then
        log "ERROR" "[$project_num] API启用失败: $project_id"
        return 1
    fi
    sleep 3
    
    # 3. 创建API密钥
    local create_output
    create_output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key-$project_id\" --format=json --quiet")
    if [[ -z "$create_output" ]]; then
        log "ERROR" "[$project_num] API密钥创建失败: $project_id"
        return 1
    fi
    
    # 解析并保存密钥
    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    if [[ -n "$api_key" ]]; then
        log "SUCCESS" "[$project_num] 成功获取API密钥: $project_id"
        write_keys_to_files "$api_key"
        return 0
    else
        log "ERROR" "[$project_num] API密钥解析失败: $project_id"
        log "DEBUG" "原始输出: $create_output"
        return 1
    fi
}

# 删除项目函数
delete_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    log "INFO" "[$project_num/$total] 删除项目: $project_id"
    if retry_with_backoff 2 "gcloud projects delete \"$project_id\" --quiet"; then
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
    
    # 启用API
    retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet" || return 1
    
    # 尝试创建新密钥
    local create_output
    create_output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key-Extract\" --format=json --quiet")
    if [[ -z "$create_output" ]]; then
        log "ERROR" "[$project_num] 无法为项目创建密钥: $project_id"
        return 1
    fi

    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    if [[ -n "$api_key" ]]; then
        log "SUCCESS" "[$project_num] 成功创建并获取密钥: $project_id"
        write_keys_to_files "$api_key"
        return 0
    fi

    log "ERROR" "[$project_num] 无法获取或创建密钥: $project_id"
    return 1
}

# 清理项目API密钥
cleanup_api_keys() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    log "INFO" "[$project_num/$total] 开始清理项目API密钥: $project_id"
    
    local keys_json
    keys_json=$(retry_with_backoff 2 "gcloud services api-keys list --project=\"$project_id\" --format=json")
    if [[ -z "$keys_json" || "$keys_json" == "[]" ]]; then
        log "INFO" "[$project_num] 项目无API密钥可清理: $project_id"
        return 0
    fi
    
    local key_names
    # 使用jq或sed提取所有密钥的name
    if command -v jq &>/dev/null; then
        readarray -t key_names < <(echo "$keys_json" | jq -r '.[].name')
    else
        readarray -t key_names < <(echo "$keys_json" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4)
    fi

    if (( ${#key_names[@]} == 0 )); then
        log "INFO" "[$project_num] 未找到可解析的密钥名称: $project_id"
        return 0
    fi
    
    local deleted_count=0
    for key_name in "${key_names[@]}"; do
        if [[ -n "$key_name" ]]; then
            log "DEBUG" "[$project_num] 删除密钥: $key_name"
            if retry_with_backoff 2 "gcloud services api-keys delete \"$key_name\" --quiet"; then
                ((deleted_count++))
            fi
            sleep 0.5 # 避免API速率限制
        fi
    done
    log "INFO" "[$project_num] 清理完成: $project_id (删除了 $deleted_count/${#key_names[@]} 个密钥)"
    echo "[$(date)] 项目 $project_id: 删除了 $deleted_count 个密钥" >> "$CLEANUP_LOG"
    return 0
}

# 获取项目列表
get_project_list() {
    log "INFO" "正在获取项目列表..."
    local project_list
    project_list=$(retry_with_backoff 2 "gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet")
    if [[ -z "$project_list" ]]; then
        log "WARN" "未能获取项目列表或当前无项目。"
        return 1
    fi
    echo "$project_list"
    return 0
}

# 并行执行框架
run_parallel() {
    local task_func="$1"
    shift
    local items=("$@")
    local total_items=${#items[@]}
    
    if (( total_items == 0 )); then
        log "INFO" "没有项目需要处理。"
        return 0
    fi
    
    log "INFO" "开始并行执行 '$task_func' 任务 (最大并发数: $MAX_PARALLEL_JOBS)"
    
    local pids=()
    local completed_count=0
    
    # 导出所需函数和变量，以便在子shell中可用
    export -f log retry_with_backoff parse_json write_keys_to_files "$task_func"
    export MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE DELETION_LOG CLEANUP_LOG TEMP_DIR
    
    for i in "${!items[@]}"; do
        if (( ${#pids[@]} >= MAX_PARALLEL_JOBS )); then
            # 等待任何一个任务完成
            wait -n "${pids[@]}"
            # 清理已完成的PID
            for j in "${!pids[@]}"; do
                if ! kill -0 "${pids[j]}" 2>/dev/null; then
                    unset 'pids[j]'
                    ((completed_count++))
                    show_progress "$completed_count" "$total_items" "$task_func"
                fi
            done
        fi
        
        # 启动新任务
        (
            "$task_func" "${items[i]}" "$((i + 1))" "$total_items"
        ) &
        pids+=($!)
    done
    
    # 等待所有剩余的任务
    wait "${pids[@]}"
    show_progress "$total_items" "$total_items" "$task_func 完成"
    echo # 换行
    log "INFO" "所有并行任务已执行完毕。"
}

# 生成报告函数
generate_report() {
    local success=$1
    local failed=$2
    local total=$3
    local operation=${4:-"处理"}
    
    local success_rate=0
    if (( total > 0 )); then
        success_rate=$(awk "BEGIN {printf \"%.2f\", $success * 100 / $total}")
    fi
    
    local duration=$SECONDS
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds_rem=$((duration % 60))
    
    echo
    echo "================================================================"
    echo "                       执 行 报 告"
    echo "================================================================"
    echo "  操作类型    : $operation"
    echo "  总计尝试    : $total"
    echo "  成功数量    : $success"
    echo "  失败数量    : $failed"
    echo "  成功率      : $success_rate%"
    printf "  总执行时间  : %d小时 %d分钟 %d秒\n" "$hours" "$minutes" "$seconds_rem"
    
    if (( success > 0 )); then
        local key_count
        key_count=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
        echo
        echo "  输出文件:"
        echo "  - 纯密钥文件    : $PURE_KEY_FILE ($key_count 个密钥)"
        echo "  - 逗号分隔文件  : $COMMA_SEPARATED_KEY_FILE"
    fi
    echo "================================================================"
}


# ===== 主要功能模块 (由菜单调用) =====

# 功能1：删除并重建
delete_and_rebuild() {
    log "INFO" "==================== 功能1：删除并重建 ===================="
    delete_all_existing_projects "confirm" || return 1
    create_projects_and_get_keys
}

# 功能2：创建新项目
create_projects_and_get_keys() {
    log "INFO" "==================== 功能2：创建新项目 ===================="
    check_quota || return 1
    
    log "INFO" "将创建 $TOTAL_PROJECTS 个新项目。用户名: $EMAIL_USERNAME, 项目前缀: $PROJECT_PREFIX"
    read -p "确认开始创建吗? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    
    > "$PURE_KEY_FILE" && > "$COMMA_SEPARATED_KEY_FILE"
    
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-$(printf "%03d" $i)"
        project_id=$(echo "$project_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        projects_to_create+=("$project_id")
    done
    
    SECONDS=0
    run_parallel process_project "${projects_to_create[@]}"
    
    local successful_keys
    successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
    local failed_entries=$((TOTAL_PROJECTS - successful_keys))
    generate_report "$successful_keys" "$failed_entries" "$TOTAL_PROJECTS" "创建项目"
}

# 功能3：获取现有项目密钥
get_keys_from_existing_projects() {
    log "INFO" "==================== 功能3：获取现有项目密钥 ===================="
    local project_list
    project_list=$(get_project_list) || return 1
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目。将为它们启用API并创建新密钥。"
    read -p "确认继续吗? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    
    > "$PURE_KEY_FILE" && > "$COMMA_SEPARATED_KEY_FILE"
    
    SECONDS=0
    run_parallel extract_key_from_project "${projects_array[@]}"
    
    local successful_keys
    successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
    local failed_entries=$((project_count - successful_keys))
    generate_report "$successful_keys" "$failed_entries" "$project_count" "获取现有密钥"
}

# 功能4：删除所有项目
delete_all_existing_projects() {
    log "INFO" "==================== 功能4：删除所有项目 ===================="
    local project_list
    project_list=$(get_project_list) || return 0 # 没有项目不算失败
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目需要删除。"
    
    # 如果是由其他函数调用，则跳过确认
    if [[ "$1" != "confirm" ]]; then
        echo "将要删除的项目示例:"
        printf " - %s\n" "${projects_array[@]:0:5}"
        [[ $project_count -gt 5 ]] && echo " - ...等等"
        echo
        read -p "!!! 危险操作 !!! 确认删除所有 $project_count 个项目? 请输入 'DELETE-ALL' 确认: " confirm_text
        [[ "$confirm_text" == "DELETE-ALL" ]] || { log "INFO" "操作已取消。"; return 1; }
    fi
    
    echo "项目删除日志 - $(date)" > "$DELETION_LOG"
    
    SECONDS=0
    run_parallel delete_project "${projects_array[@]}"
    
    local successful_deletions
    successful_deletions=$(grep -c "已删除:" "$DELETION_LOG" 2>/dev/null || echo 0)
    local failed_deletions=$((project_count - successful_deletions))
    generate_report "$successful_deletions" "$failed_deletions" "$project_count" "删除项目"
    log "INFO" "详细删除日志见: $DELETION_LOG"
}

# 功能5：清理API密钥
cleanup_project_api_keys() {
    log "INFO" "==================== 功能5：清理API密钥 ===================="
    local project_list
    project_list=$(get_project_list) || return 1
    
    local projects_array
    readarray -t projects_array <<< "$project_list"
    local project_count=${#projects_array[@]}
    
    log "INFO" "发现 $project_count 个项目。将删除这些项目中所有的API密钥。"
    read -p "确认继续吗? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    
    echo "API密钥清理日志 - $(date)" > "$CLEANUP_LOG"
    
    SECONDS=0
    run_parallel cleanup_api_keys "${projects_array[@]}"
    generate_report "$project_count" 0 "$project_count" "清理API密钥"
    log "INFO" "详细清理日志见: $CLEANUP_LOG"
}


# ===== 菜单和主程序入口 =====

# 配置设置函数
configure_settings() {
    while true; do
        clear
        echo "================================================================"
        echo "                         配置设置"
        echo "================================================================"
        echo " 1. 项目前缀       : $PROJECT_PREFIX"
        echo " 2. 项目数量       : $TOTAL_PROJECTS"
        echo " 3. 最大并发数     : $MAX_PARALLEL_JOBS"
        echo " 4. 重试次数       : $MAX_RETRY_ATTEMPTS"
        echo
        echo " 0. 返回主菜单"
        echo "================================================================"
        
        read -p "选择要修改的设置 [0-4]: " choice
        
        case $choice in
            1)
                read -p "输入新的项目前缀 (当前: $PROJECT_PREFIX): " new_prefix
                if [[ -n "$new_prefix" && "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
                    PROJECT_PREFIX="$new_prefix"
                    log "INFO" "项目前缀已更新为: $PROJECT_PREFIX"
                else
                    echo "错误: 前缀必须以小写字母开头，只能包含小写字母、数字和连字符，长度不超过20。"
                    sleep 2
                fi
                ;;
            2)
                read -p "输入项目数量 (当前: $TOTAL_PROJECTS): " new_total
                if [[ "$new_total" =~ ^[1-9][0-9]*$ ]]; then
                    TOTAL_PROJECTS=$new_total
                    log "INFO" "项目数量已更新为: $TOTAL_PROJECTS"
                else
                    echo "错误: 请输入大于0的整数。"
                    sleep 2
                fi
                ;;
            3)
                read -p "输入最大并发数 (当前: $MAX_PARALLEL_JOBS, 建议5-30): " new_parallel
                if [[ "$new_parallel" =~ ^[1-9][0-9]*$ && "$new_parallel" -le 50 ]]; then
                    MAX_PARALLEL_JOBS=$new_parallel
                    log "INFO" "最大并发数已更新为: $MAX_PARALLEL_JOBS"
                else
                    echo "错误: 请输入1-50之间的整数。"
                    sleep 2
                fi
                ;;
            4)
                read -p "输入重试次数 (当前: $MAX_RETRY_ATTEMPTS, 建议1-5): " new_retries
                if [[ "$new_retries" =~ ^[1-5]$ ]]; then
                    MAX_RETRY_ATTEMPTS=$new_retries
                    log "INFO" "重试次数已更新为: $MAX_RETRY_ATTEMPTS"
                else
                    echo "错误: 请输入1-5之间的整数。"
                    sleep 2
                fi
                ;;
            0) return ;;
            *) echo "无效选项，请重新选择。" && sleep 1 ;;
        esac
        [[ $choice != 0 ]] && sleep 1
    done
}

# 显示主菜单
show_menu() {
    clear
    local current_account
    current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null)
    
    echo "================================================================"
    echo "     密钥管理器最终版《该脚本完全免费，请勿进行任何商业行为》"
    echo "                            作者《1996》"
    echo "================================================================"
    echo
    echo "  当前状态:"
    echo "  - 登录账号: ${current_account:-未登录}"
    echo "  - 默认项目: ${current_project:-未设置}"
    echo "  - 并发/重试: $MAX_PARALLEL_JOBS / $MAX_RETRY_ATTEMPTS"
    echo
    echo "  功能菜单:"
    echo "  1. 删除所有项目并重建 (获取API密钥)"
    echo "  2. 创建新项目并获取API密钥"
    echo "  3. 从现有项目获取API密钥"
    echo "  4. 删除所有现有项目"
    echo "  5. 清理项目中的API密钥"
    echo "  6. 修改配置设置"
    echo
    echo "  0. 退出程序"
    echo "================================================================"
    
    read -p "请选择功能 [0-6]: " choice
    
    case $choice in
        1) delete_and_rebuild ;;
        2) create_projects_and_get_keys ;;
        3) get_keys_from_existing_projects ;;
        4) delete_all_existing_projects ;;
        5) cleanup_project_api_keys ;;
        6) configure_settings ;;
        0) 
            log "INFO" "程序已退出。"
            exit 0
            ;;
        *)
            echo "无效选项: $choice"
            sleep 1
            return
            ;;
    esac
    
    echo
    read -p "按回车键返回主菜单..."
}

# 资源清理函数
cleanup_resources() {
    log "INFO" "检测到脚本退出，正在执行资源清理..."
    # 查找并终止由本脚本启动的gcloud后台进程
    pkill -P $$
    # 清理临时目录
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "临时目录已清理: $TEMP_DIR"
    fi
}

# 前置检查
check_prerequisites() {
    log "INFO" "执行前置检查..."
    local all_ok=true
    
    if ! command -v gcloud &> /dev/null; then
        log "ERROR" "未找到 'gcloud' 命令。请安装 Google Cloud SDK 并确保其在您的 PATH 中。"
        all_ok=false
    fi
    
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then
        log "WARN" "未检测到活跃的GCP账号。请先使用 'gcloud auth login' 和 'gcloud config set project [PROJECT_ID]' 登录并设置项目。"
        all_ok=false
    fi

    if ! command -v jq &> /dev/null; then
        log "WARN" "推荐安装 'jq' 以获得更可靠的JSON解析能力。脚本将使用内置方法，但在复杂情况下可能出错。"
    fi
    
    if ! $all_ok; then
        return 1
    fi

    log "INFO" "前置检查通过。"
    return 0
}

# ===== 主程序入口 =====

# 设置退出信号处理，确保临时文件和子进程被清理
trap cleanup_resources EXIT SIGINT SIGTERM

# 执行前置检查
if ! check_prerequisites; then
    log "ERROR" "前置检查失败，程序无法继续。请解决上述问题后重试。"
    exit 1
fi

# 显示欢迎信息
log "INFO" "1996提醒您：密钥管理工具已经启动成功！"
log "INFO" "临时目录: $TEMP_DIR"
log "INFO" "本次运行生成的用户名: $EMAIL_USERNAME"
sleep 2

# 主循环
while true; do
    show_menu
done
