#!/bin/bash

# ==============================================================================
#
# 密钥管理器最终融合版 v3.1
#
# - 该脚本完全免费，请勿进行任何商业行为
# - 作者: 1996 & KKTsN
# - 融合与重构: 1996
#
# - v3.1 更新日志:
#   - 实现了完整的配置修改菜单 (功能6)
#   - 补完了清理项目中所有API密钥的功能 (功能5)
#   - 优化了代码结构，所有功能均已可用
#
# ==============================================================================

# ===== 全局配置 =====
# 自动生成随机用户名和临时目录
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="gemini${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-pro"
TOTAL_PROJECTS=75
MAX_PARALLEL_JOBS=25  # 建议根据网络和机器性能调整 (10-40)
GLOBAL_WAIT_SECONDS=75 # 创建项目和启用API之间的全局等待时间 (秒), 建议 60-120
MAX_RETRY_ATTEMPTS=3
SECONDS=0 # 用于计时

# 文件和目录配置
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"

# 心跳进程ID
HEARTBEAT_PID=""

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

# 心跳机制
start_heartbeat() {
    local message="$1"; local interval="${2:-20}"; stop_heartbeat
    ( while true; do log "HEARTBEAT" "${message:-"操作进行中..."}"; sleep "$interval"; done ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "$HEARTBEAT_PID" && -e /proc/$HEARTBEAT_PID ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null; wait "$HEARTBEAT_PID" 2>/dev/null || true
    fi; HEARTBEAT_PID=""
}

# 优化版JSON解析函数
parse_json() {
    local json_input="$1"; local field="$2"; local value=""
    if command -v jq &> /dev/null; then value=$(echo "$json_input" | jq -r "$field // \"\""); else
        local field_name=$(echo "$field" | sed 's/^\.//; s/\[[0-9]*\]//g; s/"//g')
        value=$(echo "$json_input" | grep -o "\"$field_name\": *\"[^\"]*\"" | head -n 1 | cut -d'"' -f4)
    fi
    if [[ -n "$value" && "$value" != "null" ]]; then echo "$value"; return 0; else return 1; fi
}

# 文件写入函数 (带文件锁)
write_keys_to_files() {
    local api_key="$1"; if [[ -z "$api_key" ]]; then return 1; fi
    (
        if flock -w 10 200; then
            echo "$api_key" >> "$PURE_KEY_FILE"
            if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"; fi
            echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        else log "ERROR" "写入文件失败: 获取文件锁超时"; return 1; fi
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# 改进的重试函数
retry_with_backoff() {
    local max_attempts=$1; shift; local cmd=("$@"); local attempt=1; local base_timeout=5
    while (( attempt <= max_attempts )); do
        local error_log="${TEMP_DIR}/error_$$_${attempt}.log"
        local output; output=$(eval "${cmd[@]}" 2> "$error_log"); local exit_code=$?
        local error_msg; error_msg=$(<"$error_log"); rm -f "$error_log"
        if (( exit_code == 0 )); then echo "$output"; return 0; fi
        log "WARN" "命令失败 (尝试 $attempt/$max_attempts): ${cmd[*]} | 错误: $error_msg"
        if [[ "$error_msg" == *"Permission denied"* || "$error_msg" == *"INVALID_ARGUMENT"* || "$error_msg" == *"already exists"* ]]; then
            log "ERROR" "检测到不可重试错误，停止。"; return $exit_code;
        fi
        if [[ "$error_msg" == *"Quota exceeded"* || "$error_msg" == *"RESOURCE_EXHAUSTED"* ]]; then
            local sleep_time=$((base_timeout * attempt * 2)); log "WARN" "配额限制，等待 ${sleep_time}s"; sleep "$sleep_time"
        elif (( attempt < max_attempts )); then
            local sleep_time=$((base_timeout * attempt)); log "INFO" "等待 ${sleep_time}s 后重试..."; sleep "$sleep_time"
        fi
        ((attempt++))
    done; log "ERROR" "命令在 $max_attempts 次尝试后最终失败: ${cmd[*]}"; return 1
}

# 进度条显示函数
show_progress() {
    local completed=$1; local total=$2; local op_name=${3:-"进度"}
    if (( total <= 0 )); then return; fi; if (( completed > total )); then completed=$total; fi
    local percent=$((completed * 100 / total)); local bar_len=40
    local filled_len=$((bar_len * percent / 100)); local bar; printf -v bar '%*s' "$filled_len" ''; bar=${bar// /█}
    local empty; printf -v empty '%*s' "$((bar_len - filled_len))" ''; empty=${empty// /░}
    printf "\r%-80s" " "; printf "\r[%s%s] %d%% (%d/%d) - %s" "$bar" "$empty" "$percent" "$completed" "$total" "$op_name"
}

# ===== 分阶段任务函数 =====

task_create_project() {
    local project_id="$1"; local success_file="$2"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet >/dev/null 2>"${TEMP_DIR}/${project_id}_create_error.log"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else log "ERROR" "创建项目失败: $project_id. 详情见日志"; return 1; fi
}

task_enable_api() {
    local project_id="$1"; local success_file="$2"
    if retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else log "ERROR" "为项目 $project_id 启用API失败"; return 1; fi
}

task_create_key() {
    local project_id="$1"; local success_file="$2"
    local create_output; create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key\" --format=json --quiet")
    if [[ -z "$create_output" ]]; then log "ERROR" "为项目 $project_id 创建密钥失败 (无输出)"; return 1; fi
    if [[ -n $(parse_json "$create_output" ".error.message") ]]; then log "ERROR" "为项目 $project_id 创建密钥时GCP返回错误"; return 1; fi
    local api_key; api_key=$(parse_json "$create_output" ".keyString")
    if [[ -n "$api_key" ]]; then
        write_keys_to_files "$api_key"; (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else log "ERROR" "为项目 $project_id 提取密钥失败"; return 1; fi
}

task_delete_project() {
    local project_id="$1"; local success_file="$2"
    if gcloud projects delete "$project_id" --quiet >/dev/null 2>"${TEMP_DIR}/${project_id}_delete_error.log"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; log "INFO" "已删除项目: $project_id"; return 0
    else log "ERROR" "删除项目失败: $project_id. 详情见日志"; return 1; fi
}

task_cleanup_keys() {
    local project_id="$1"; local success_file="$2"
    local key_names; readarray -t key_names < <(gcloud services api-keys list --project="$project_id" --format="value(name)" --quiet)
    if [ ${#key_names[@]} -eq 0 ]; then
        log "INFO" "项目 $project_id 无密钥可清理，跳过。"; (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0;
    fi
    log "INFO" "项目 $project_id 发现 ${#key_names[@]} 个密钥，开始清理..."
    local success=true
    for key_name in "${key_names[@]}"; do
        if ! gcloud services api-keys delete "$key_name" --quiet >/dev/null 2>&1; then
            log "WARN" "删除密钥 $key_name 失败 (项目: $project_id)"; success=false
        fi
        sleep 0.5 # 避免API速率限制
    done
    if $success; then (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0; else return 1; fi
}


# ===== 并行执行与报告 =====

run_parallel() {
    local task_func="$1"; local description="$2"; local success_file="$3"; shift 3; local items=("$@")
    local total_items=${#items[@]}; if (( total_items == 0 )); then log "INFO" "在 '$description' 阶段无项目处理。"; return; fi
    log "INFO" "开始并行执行 '$description' (最大并发: $MAX_PARALLEL_JOBS)..."
    
    local pids=(); local completed_count=0
    export -f log retry_with_backoff parse_json write_keys_to_files "$task_func" show_progress
    export MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE TEMP_DIR
    
    > "$success_file" # 清理旧的成功文件
    for i in "${!items[@]}"; do
        if (( ${#pids[@]} >= MAX_PARALLEL_JOBS )); then
            wait -n "${pids[@]}";
            for j in "${!pids[@]}"; do if ! kill -0 "${pids[j]}" 2>/dev/null; then unset 'pids[j]'; ((completed_count++)); fi; done
            show_progress "$completed_count" "$total_items" "$description"
        fi
        ( "$task_func" "${items[i]}" "$success_file" ) &; pids+=($!)
    done
    
    for pid in "${pids[@]}"; do wait "$pid"; ((completed_count++)); show_progress "$completed_count" "$total_items" "$description"; done
    wait; show_progress "$total_items" "$total_items" "$description 完成"
    local success_count=$(wc -l < "$success_file" | xargs); local fail_count=$((total_items - success_count))
    echo; log "INFO" "阶段 '$description' 完成。总数: $total_items, 成功: $success_count, 失败: $fail_count"
}

generate_report() {
    local success=$1; local failed=$2; local total=$3; local operation=${4:-"处理"}
    local success_rate=0; if (( total > 0 )); then success_rate=$(awk "BEGIN {printf \"%.2f\", $success * 100 / $total}"); fi
    local duration=$SECONDS; local h=$((duration/3600)); local m=$(((duration%3600)/60)); local s=$((duration%60))
    echo; echo "======================== 执 行 报 告 ========================"
    printf "  操作类型    : %s\n" "$operation"
    printf "  总计尝试    : %d\n" "$total"
    printf "  成功数量    : %d\n" "$success"
    printf "  失败数量    : %d\n" "$failed"
    printf "  成功率      : %.2f%%\n" "$success_rate"
    printf "  总执行时间  : %d小时 %d分钟 %d秒\n" "$h" "$m" "$s"
    if (( success > 0 )) && [[ "$operation" == *"密钥"* ]]; then
        local key_count=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
        echo; echo "  输出文件:";
        echo "  - 纯密钥文件    : $PURE_KEY_FILE ($key_count 个密钥)"
        echo "  - 逗号分隔文件  : $COMMA_SEPARATED_KEY_FILE"
    fi
    echo "================================================================"
}

# ===== 主要功能模块 =====

create_projects_phased() {
    SECONDS=0; log "INFO" "==================== 功能1: 创建项目并获取密钥 (分阶段) ===================="
    log "INFO" "将创建 $TOTAL_PROJECTS 个新项目。用户名: $EMAIL_USERNAME, 项目前缀: $PROJECT_PREFIX"
    read -p "确认开始吗? [y/N]: " confirm; [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    
    > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
    local projects_to_create=(); for i in $(seq 1 $TOTAL_PROJECTS); do
        local p_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-$(printf "%03d" $i)"; p_id=$(echo "$p_id"|tr -cd 'a-z0-9-'|cut -c 1-30|sed 's/-$//'); projects_to_create+=("$p_id"); done

    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created.txt"
    run_parallel task_create_project "阶段1: 创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
    local created_project_ids=(); mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"
    if [ ${#created_project_ids[@]} -eq 0 ]; then log "ERROR" "项目创建阶段完全失败，中止操作。"; return 1; fi

    log "INFO" "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒..."; start_heartbeat "全局等待中..."; sleep ${GLOBAL_WAIT_SECONDS}; stop_heartbeat; echo;

    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/enabled.txt"
    run_parallel task_enable_api "阶段3: 启用API" "$ENABLED_PROJECTS_FILE" "${created_project_ids[@]}"
    local enabled_project_ids=(); mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then log "ERROR" "API启用阶段完全失败，中止操作。"; return 1; fi

    local KEYS_CREATED_FILE="${TEMP_DIR}/keys_created.txt"
    run_parallel task_create_key "阶段4: 创建密钥" "$KEYS_CREATED_FILE" "${enabled_project_ids[@]}"

    local successful_keys=$(wc -l < "$KEYS_CREATED_FILE" 2>/dev/null || echo 0)
    generate_report "$successful_keys" $((TOTAL_PROJECTS - successful_keys)) "$TOTAL_PROJECTS" "创建并获取密钥"
}

extract_keys_from_existing_projects() {
    SECONDS=0; log "INFO" "==================== 功能2: 从现有项目中提取密钥 ===================="
    log "INFO" "正在获取项目列表..."; local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
    if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
    local projects_array; readarray -t projects_array <<< "$project_list"
    
    > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
    local projects_to_process=(); log "INFO" "正在检查 ${#projects_array[@]} 个项目的密钥状态..."
    start_heartbeat "检查密钥状态..." 10
    for project_id in "${projects_array[@]}"; do
        if ! gcloud services api-keys list --project="$project_id" --format="value(name)" --quiet | grep -q "."; then
            projects_to_process+=("$project_id")
        fi; done; stop_heartbeat
    
    if [ ${#projects_to_process[@]} -eq 0 ]; then log "INFO" "所有项目均已有密钥，无需操作。"; return 0; fi
    log "INFO" "将为 ${#projects_to_process[@]} 个没有密钥的项目创建新密钥。"
    read -p "确认继续吗? [y/N]: " confirm; [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    
    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/existing_enabled.txt"
    run_parallel task_enable_api "启用API" "$ENABLED_PROJECTS_FILE" "${projects_to_process[@]}"
    local enabled_project_ids=(); mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then log "ERROR" "API启用阶段失败。"; return 1; fi
    
    local KEYS_CREATED_FILE="${TEMP_DIR}/existing_keys.txt"
    run_parallel task_create_key "创建密钥" "$KEYS_CREATED_FILE" "${enabled_project_ids[@]}"
    
    local successful_keys=$(wc -l < "$KEYS_CREATED_FILE" 2>/dev/null || echo 0)
    generate_report "$successful_keys" $((${#projects_to_process[@]} - successful_keys)) "${#projects_to_process[@]}" "提取现有密钥"
}

create_projects_only() {
    SECONDS=0; log "INFO" "==================== 功能3: 仅创建项目 ===================="
    read -p "请输入要创建的项目数量 (默认: $TOTAL_PROJECTS): " custom_count; custom_count=${custom_count:-$TOTAL_PROJECTS}
    if ! [[ "$custom_count" =~ ^[1-9][0-9]*$ ]]; then log "ERROR" "无效输入"; return 1; fi
    
    local projects_to_create=(); for i in $(seq 1 $custom_count); do
        local p_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-only-$(printf "%03d" $i)"; p_id=$(echo "$p_id"|tr -cd 'a-z0-9-'|cut -c 1-30|sed 's/-$//'); projects_to_create+=("$p_id"); done
    
    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_only.txt"
    run_parallel task_create_project "仅创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
    
    local success_count=$(wc -l < "$CREATED_PROJECTS_FILE" | xargs)
    generate_report "$success_count" $((custom_count - success_count)) "$custom_count" "仅创建项目"
}

delete_all_existing_projects() {
    SECONDS=0; log "INFO" "==================== 功能4: 删除所有项目 ===================="
    local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
    if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
    local projects_array; readarray -t projects_array <<< "$project_list"
    
    log "WARN" "找到 ${#projects_array[@]} 个项目。"; read -p "!!! 危险 !!! 输入 'DELETE-ALL' 确认删除: " confirm
    [[ "$confirm" == "DELETE-ALL" ]] || { log "INFO" "操作取消。"; return 1; }
    
    local DELETED_FILE="${TEMP_DIR}/deleted.txt"
    run_parallel task_delete_project "删除项目" "$DELETED_FILE" "${projects_array[@]}"
    
    local success_count=$(wc -l < "$DELETED_FILE" | xargs)
    generate_report "$success_count" $((${#projects_array[@]} - success_count)) "${#projects_array[@]}" "删除项目"
}

cleanup_project_api_keys() {
    SECONDS=0; log "INFO" "==================== 功能5: 清理API密钥 ===================="
    local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
    if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
    local projects_array; readarray -t projects_array <<< "$project_list"

    log "WARN" "将清理 ${#projects_array[@]} 个项目中所有的API密钥。"
    read -p "确认继续吗? [y/N]: " confirm; [[ "$confirm" =~ ^[Yy]$ ]] || { log "INFO" "操作取消。"; return 1; }

    echo "API密钥清理日志 - $(date)" > "$CLEANUP_LOG"
    local CLEANED_FILE="${TEMP_DIR}/cleaned.txt"
    run_parallel task_cleanup_keys "清理API密钥" "$CLEANED_FILE" "${projects_array[@]}"

    local success_count=$(wc -l < "$CLEANED_FILE" | xargs)
    generate_report "$success_count" $((${#projects_array[@]} - success_count)) "${#projects_array[@]}" "清理API密钥"
}

# ===== 菜单与主程序 =====

configure_settings() {
    while true; do
        clear; echo "======================== 配置参数 ========================"
        echo " 1. 项目创建数量       : $TOTAL_PROJECTS"
        echo " 2. 项目前缀           : $PROJECT_PREFIX"
        echo " 3. 最大并发数         : $MAX_PARALLEL_JOBS"
        echo " 4. 全局等待时间(秒)   : $GLOBAL_WAIT_SECONDS"
        echo " 5. 最大重试次数       : $MAX_RETRY_ATTEMPTS"
        echo; echo " 0. 返回主菜单"
        echo "================================================================"
        read -p "选择要修改的设置 [0-5]: " choice
        case $choice in
            1) read -p "输入新的项目数量 (1-200): " val; if [[ "$val" =~ ^[1-9][0-9]*$ && "$val" -le 200 ]]; then TOTAL_PROJECTS=$val; fi;;
            2) read -p "输入新的项目前缀 (小写字母开头,含小写字母/数字/-): " val; if [[ "$val" =~ ^[a-z][a-z0-9-]{0,20}$ ]]; then PROJECT_PREFIX="$val"; fi;;
            3) read -p "输入最大并发数 (5-50): " val; if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 5 && "$val" -le 50 ]]; then MAX_PARALLEL_JOBS=$val; fi;;
            4) read -p "输入全局等待时间 (建议60-120秒): " val; if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 30 ]]; then GLOBAL_WAIT_SECONDS=$val; fi;;
            5) read -p "输入最大重试次数 (1-5): " val; if [[ "$val" =~ ^[1-5]$ ]]; then MAX_RETRY_ATTEMPTS=$val; fi;;
            0) return;;
            *) echo "无效选项。" && sleep 1;;
        esac
    done
}

show_menu() {
    clear
    local current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
    echo "   ______   ______   ____     __  __           __                        "
    echo "  / ____/  / ____/  / __ \   / / / /  ___     / /  ____     ___     _____"
    echo " / / __   / /      / /_/ /  / /_/ /  / _ \   / /  / __ \   / _ \   / ___/"
    echo "/ /_/ /  / /___   / ____/  / __  /  /  __/  / /  / /_/ /  /  __/  / /    "
    echo "\____/   \____/  /_/      /_/ /_/   \___/  /_/  / .___/   \___/  /_/     "
    echo "                                               /_/                      v3.1"             
    echo "========================================================================"
    echo "  当前账号: ${current_account:-未登录} | 并发数: $MAX_PARALLEL_JOBS | 等待时间: ${GLOBAL_WAIT_SECONDS}s"
    echo "========================================================================"
    echo "  1. 一键创建 ${TOTAL_PROJECTS} 个项目并获取密钥 (推荐, 分阶段执行)"
    echo "  2. 从现有项目中提取密钥 (智能检查)"
    echo "  3. 仅创建项目 (不启用API，不取密钥)"
    echo "  4. 删除所有现有项目 (危险操作)"
    echo "  5. 清理所有项目中的API密钥 (危险操作)"
    echo "  6. 修改配置参数"
    echo; echo "  0. 退出程序"
    echo "========================================================================"
    read -p "请选择功能 [0-6]: " choice
    
    case $choice in
        1) create_projects_phased ;;
        2) extract_keys_from_existing_projects ;;
        3) create_projects_only ;;
        4) delete_all_existing_projects ;;
        5) cleanup_project_api_keys ;;
        6) configure_settings ;;
        0) log "INFO" "程序已退出。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" && sleep 1 ;;
    esac
    read -p "按回车键返回主菜单..."
}

cleanup_resources() {
    log "INFO" "执行退出清理..."; stop_heartbeat
    pkill -P $$ &>/dev/null; rm -rf "$TEMP_DIR"
}

check_prerequisites() {
    log "INFO" "执行前置检查...";
    if ! command -v gcloud &> /dev/null; then log "ERROR" "未找到 'gcloud' 命令。"; return 1; fi
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then
        log "WARN" "未检测到活跃GCP账号，请先登录。"; gcloud auth login || return 1
    fi
    if ! command -v jq &>/dev/null; then log "WARN" "推荐安装 'jq' 以获得更可靠的JSON解析。"; fi
    log "INFO" "前置检查通过。"; return 0
}

# ===== 程序入口 =====
trap cleanup_resources EXIT SIGINT SIGTERM
if ! check_prerequisites; then log "ERROR" "前置检查失败，程序退出。"; exit 1; fi
log "INFO" "密钥管理器 v3.1 已启动！"
sleep 1
while true; do show_menu; done
