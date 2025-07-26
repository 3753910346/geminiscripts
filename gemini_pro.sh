#!/bin/bash

# ===== 配置 =====
# 自动生成随机用户名
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"  # 可自定义
TOTAL_PROJECTS=50           # 可自定义，默认50个项目
MAX_PARALLEL_JOBS=60        # 可自定义，默认60个并行任务
GLOBAL_WAIT_SECONDS=30      # 优化：减少等待时间到30秒
MAX_RETRY_ATTEMPTS=5        # 增加重试次数到5次
BATCH_SIZE=10               # 新增：批处理大小，用于分批处理
API_ENABLE_TIMEOUT=120      # 新增：API启用超时时间
KEY_CREATE_TIMEOUT=60       # 新增：密钥创建超时时间

# 文件配置
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
JSON_KEY_FILE="keys_detailed_${EMAIL_USERNAME}.json"  # 新增：详细JSON格式
SECONDS=0
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
PERFORMANCE_LOG="${TEMP_DIR}/performance.log"  # 新增：性能日志
# ===== 配置结束 =====

# ===== 初始化 =====
mkdir -p "$TEMP_DIR"
touch "$PERFORMANCE_LOG"
_log_internal() {
  local level=$1; local msg=$2; local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $msg"
  echo "[$timestamp] [$level] $msg" >> "$PERFORMANCE_LOG"
}
_log_internal "INFO" "脚本初始化完成，性能优化版本 v4.0"
# ===== 初始化结束 =====

# ===== 工具函数 =====
log() { _log_internal "$1" "$2"; }

# 优化的JSON解析函数
parse_json() {
  local json="$1"; local field="$2"; local value=""
  if [ -z "$json" ]; then return 1; fi
  case "$field" in
    ".keyString") 
      # 多种解析方法，提高成功率
      value=$(echo "$json" | jq -r '.keyString' 2>/dev/null) ||
      value=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('keyString',''))" 2>/dev/null) ||
      value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p')
      ;;
    ".name")
      value=$(echo "$json" | jq -r '.name' 2>/dev/null) ||
      value=$(echo "$json" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p')
      ;;
    *) 
      local field_name=$(echo "$field" | tr -d '.["]')
      value=$(echo "$json" | jq -r ".$field_name" 2>/dev/null) ||
      value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*")
      ;;
  esac
  if [ -n "$value" ] && [ "$value" != "null" ]; then echo "$value"; return 0; else return 1; fi
}

# 优化的密钥写入函数
write_keys_to_files() {
    local api_key="$1"; local project_id="$2"; local key_name="$3"
    if [ -z "$api_key" ]; then return; fi
    
    local lock_file="${TEMP_DIR}/key_files.lock"
    (
        flock -x 200
        # 纯密钥文件
        echo "$api_key" >> "$PURE_KEY_FILE"
        
        # 逗号分隔文件
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then 
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        
        # JSON详细信息文件
        local json_entry="{\"project\":\"$project_id\",\"key\":\"$api_key\",\"name\":\"$key_name\",\"created\":\"$(date -Iseconds)\"}"
        if [[ ! -s "$JSON_KEY_FILE" ]]; then
            echo "[$json_entry" >> "$JSON_KEY_FILE"
        else
            echo ",$json_entry" >> "$JSON_KEY_FILE"
        fi
    ) 200>"$lock_file"
}

# 增强的重试函数，支持指数退避和更智能的错误处理
retry_with_backoff() {
  local max_attempts=$1; local cmd=$2; local attempt=1; local base_timeout=2
  local error_log="${TEMP_DIR}/error_$$_$RANDOM.log"
  
  while [ $attempt -le $max_attempts ]; do
    local timeout=$((base_timeout * (2 ** (attempt - 1))))  # 指数退避
    if [ $timeout -gt 60 ]; then timeout=60; fi  # 最大60秒
    
    if timeout ${API_ENABLE_TIMEOUT} bash -c "$cmd" 2>"$error_log"; then 
      rm -f "$error_log"; return 0
    fi
    
    local error_msg=$(cat "$error_log" 2>/dev/null || echo "未知错误")
    
    # 智能错误分析
    if [[ "$error_msg" == *"Permission denied"* ]] || [[ "$error_msg" == *"Authentication failed"* ]]; then
        log "ERROR" "权限或认证错误，停止重试: $error_msg"
        rm -f "$error_log"; return 2  # 特殊返回码表示不应重试
    elif [[ "$error_msg" == *"Quota exceeded"* ]] || [[ "$error_msg" == *"Rate limit"* ]]; then
        log "WARN" "配额或速率限制，延长等待时间"
        timeout=$((timeout * 2))
    elif [[ "$error_msg" == *"already exists"* ]]; then
        log "INFO" "资源已存在，视为成功"
        rm -f "$error_log"; return 0
    fi
    
    if [ $attempt -lt $max_attempts ]; then 
      log "WARN" "尝试 $attempt/$max_attempts 失败，${timeout}秒后重试: $error_msg"
      sleep $timeout
    fi
    attempt=$((attempt + 1))
  done
  
  log "ERROR" "命令在 $max_attempts 次尝试后最终失败: $(cat "$error_log" 2>/dev/null)"
  rm -f "$error_log"; return 1
}

# 增强的进度显示
show_progress() {
    local completed=$1; local total=$2; local phase="$3"; local success="$4"; local failed="$5"
    if [ $total -le 0 ]; then return; fi
    if [ $completed -gt $total ]; then completed=$total; fi
    
    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 40 / 100))  # 缩短进度条
    local remaining_chars=$((40 - completed_chars))
    local progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '█')
    local remaining_bar=$(printf "%${remaining_chars}s" "" | tr ' ' '░')
    
    local rate=""
    if [ $SECONDS -gt 0 ] && [ $completed -gt 0 ]; then
        local rate_val=$((completed * 60 / SECONDS))  # 每分钟速率
        rate=" (${rate_val}/min)"
    fi
    
    printf "\r[%s%s] %d%% (%d/%d) %s S:%d F:%d%s" \
           "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total" \
           "$phase" "${success:-0}" "${failed:-0}" "$rate"
}

# 生成详细报告
generate_report() {
  local success=$1; local attempted=$2; local phase_times="$3"
  local success_rate=0
  if [ "$attempted" -gt 0 ]; then 
    success_rate=$(echo "scale=2; $success * 100 / $attempted" | bc 2>/dev/null || echo "0")
  fi
  
  local failed=$((attempted - success))
  local duration=$SECONDS
  local minutes=$((duration / 60))
  local seconds_rem=$((duration % 60))
  
  echo ""; echo "========== 详细执行报告 =========="
  echo "项目配置: 前缀='$PROJECT_PREFIX', 用户='$EMAIL_USERNAME'"
  echo "计划目标: $attempted 个项目"
  echo "成功获取密钥: $success 个"
  echo "失败项目: $failed 个"
  echo "总体成功率: $success_rate%"
  echo "并行配置: $MAX_PARALLEL_JOBS 个任务"
  
  if [ $success -gt 0 ]; then 
    local avg_time=$((duration / success))
    local projects_per_min=$((success * 60 / duration))
    echo "平均处理时间: $avg_time 秒/项目"
    echo "处理速率: $projects_per_min 项目/分钟"
  fi
  
  echo "总执行时间: $minutes 分 $seconds_rem 秒"
  echo ""
  echo "输出文件:"
  echo "- 纯API密钥 (每行一个): $PURE_KEY_FILE"
  echo "- 逗号分隔密钥 (单行): $COMMA_SEPARATED_KEY_FILE"
  echo "- JSON格式详细信息: $JSON_KEY_FILE"
  echo "- 性能日志: $PERFORMANCE_LOG"
  
  if [ -n "$phase_times" ]; then
    echo ""; echo "各阶段用时:"; echo "$phase_times"
  fi
  echo "=========================="
}

# 优化的项目创建任务
task_create_project() {
    local project_id="$1"; local success_file="$2"
    local error_log="${TEMP_DIR}/create_${project_id}_error.log"
    local start_time=$(date +%s)
    
    if gcloud projects create "$project_id" \
       --name="$project_id" \
       --no-set-as-default \
       --quiet \
       --format="value(projectId)" >/dev/null 2>"$error_log"; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        (
            flock -x 200
            echo "$project_id" >> "$success_file"
            echo "CREATE,$project_id,$duration,SUCCESS" >> "$PERFORMANCE_LOG"
        ) 200>"${success_file}.lock"
        
        rm -f "$error_log"
        return 0
    else
        local error_msg=$(cat "$error_log" 2>/dev/null || echo "未知错误")
        echo "CREATE,$project_id,0,FAILED:$error_msg" >> "$PERFORMANCE_LOG"
        log "ERROR" "创建项目失败: $project_id: $error_msg"
        rm -f "$error_log"
        return 1
    fi
}

# 优化的API启用任务
task_enable_api() {
    local project_id="$1"; local success_file="$2"
    local error_log="${TEMP_DIR}/enable_${project_id}_error.log"
    local start_time=$(date +%s)
    
    # 使用更高效的API启用命令
    local cmd="gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet --no-user-output-enabled"
    
    if retry_with_backoff $MAX_RETRY_ATTEMPTS "$cmd" 2>"$error_log"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        (
            flock -x 200
            echo "$project_id" >> "$success_file"
            echo "ENABLE,$project_id,$duration,SUCCESS" >> "$PERFORMANCE_LOG"
        ) 200>"${success_file}.lock"
        
        rm -f "$error_log"
        return 0
    else
        local error_msg=$(cat "$error_log" 2>/dev/null || echo "未知错误")
        echo "ENABLE,$project_id,0,FAILED:$error_msg" >> "$PERFORMANCE_LOG"
        log "ERROR" "启用API失败: $project_id: $error_msg"
        rm -f "$error_log"
        return 1
    fi
}

# 优化的密钥创建任务
task_create_key() {
    local project_id="$1"
    local error_log="${TEMP_DIR}/key_${project_id}_error.log"
    local start_time=$(date +%s)
    local create_output
    
    # 使用更详细的密钥创建命令
    local cmd="gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key-$project_id\" --format=\"json\" --quiet"
    
    if ! create_output=$(timeout ${KEY_CREATE_TIMEOUT} bash -c "$cmd" 2>"$error_log"); then
        local error_msg=$(cat "$error_log" 2>/dev/null || echo "超时或未知错误")
        echo "KEY,$project_id,0,FAILED:$error_msg" >> "$PERFORMANCE_LOG"
        log "ERROR" "创建密钥失败: $project_id: $error_msg"
        rm -f "$error_log"
        return 1
    fi
    
    local api_key; api_key=$(parse_json "$create_output" ".keyString")
    local key_name; key_name=$(parse_json "$create_output" ".name")
    
    if [ -n "$api_key" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "成功提取密钥: $project_id (${duration}s)"
        write_keys_to_files "$api_key" "$project_id" "$key_name"
        echo "KEY,$project_id,$duration,SUCCESS" >> "$PERFORMANCE_LOG"
        rm -f "$error_log"
        return 0
    else
        echo "KEY,$project_id,0,FAILED:无法解析keyString" >> "$PERFORMANCE_LOG"
        log "ERROR" "提取密钥失败: $project_id (无法从输出解析keyString)"
        rm -f "$error_log"
        return 1
    fi
}

# 智能批处理并行执行
run_parallel_batched() {
    local task_func="$1"; local description="$2"; local success_file="$3"
    shift 3; local items=("$@")
    local total_items=${#items[@]}
    
    if [ $total_items -eq 0 ]; then 
      log "INFO" "$description: 没有项目需要处理"
      return 0
    fi
    
    local phase_start=$SECONDS
    local completed_count=0; local success_count=0; local fail_count=0
    
    log "INFO" "开始 $description (总数: $total_items, 并行: $MAX_PARALLEL_JOBS, 批大小: $BATCH_SIZE)"
    
    # 分批处理以避免系统过载
    for ((batch_start=0; batch_start<total_items; batch_start+=BATCH_SIZE)); do
        local batch_end=$((batch_start + BATCH_SIZE))
        if [ $batch_end -gt $total_items ]; then batch_end=$total_items; fi
        
        local batch_items=("${items[@]:$batch_start:$BATCH_SIZE}")
        local pids=(); local active_jobs=0
        
        # 并行执行当前批次
        for item in "${batch_items[@]}"; do
            "$task_func" "$item" "$success_file" &
            local pid=$!; pids+=($pid); ((active_jobs++))
            
            # 控制并发数
            if [[ "$active_jobs" -ge "$MAX_PARALLEL_JOBS" ]]; then
                wait -n; ((active_jobs--))
            fi
        done
        
        # 等待当前批次完成
        for pid in "${pids[@]}"; do
            wait "$pid"; local exit_status=$?; ((completed_count++))
            if [ $exit_status -eq 0 ]; then ((success_count++)); else ((fail_count++)); fi
            show_progress $completed_count $total_items "$description" $success_count $fail_count
        done
        
        # 批次间短暂休息，避免API限制
        if [ $batch_end -lt $total_items ]; then sleep 1; fi
    done
    
    local phase_duration=$((SECONDS - phase_start))
    echo; log "INFO" "$description 完成 - 成功: $success_count, 失败: $fail_count, 用时: ${phase_duration}s"
    
    return $([ $fail_count -eq 0 ] && echo 0 || echo 1)
}

# 主要功能：极速创建项目并获取密钥
create_projects_and_get_keys_ultra() {
    local start_total=$SECONDS
    log "INFO" "======================================================"
    log "INFO" "🚀 极速模式: 创建 $TOTAL_PROJECTS 个项目并获取API密钥"
    log "INFO" "配置: 前缀=$PROJECT_PREFIX, 并行=$MAX_PARALLEL_JOBS"
    log "INFO" "======================================================"
    
    # 验证gcloud配置
    if ! gcloud auth list --filter=status:ACTIVE >/dev/null 2>&1; then
        log "ERROR" "gcloud认证失败，请先运行: gcloud auth login"
        return 1
    fi
    
    log "INFO" "用户名: ${EMAIL_USERNAME}"
    echo "脚本将在 3 秒后开始执行..."
    for i in {3..1}; do echo -n "$i... "; sleep 1; done; echo "开始!"
    
    # 初始化输出文件
    > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"; > "$JSON_KEY_FILE"
    
    # 生成项目ID列表
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        # 确保符合GCP项目ID规范
        local project_id=$(echo "$base_id" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then 
          project_id="g${project_id:1}"
          project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//')
        fi
        projects_to_create+=("$project_id")
    done
    
    # === 阶段 1: 批量创建项目 ===
    local phase1_start=$SECONDS
    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_projects.txt"; > "$CREATED_PROJECTS_FILE"
    export -f task_create_project log retry_with_backoff
    export TEMP_DIR MAX_RETRY_ATTEMPTS PERFORMANCE_LOG BATCH_SIZE
    
    run_parallel_batched task_create_project "📁 阶段1: 创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
    
    local created_project_ids=()
    if [ -f "$CREATED_PROJECTS_FILE" ]; then 
      mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"
    fi
    local phase1_duration=$((SECONDS - phase1_start))
    
    if [ ${#created_project_ids[@]} -eq 0 ]; then
        log "ERROR" "❌ 项目创建阶段完全失败，中止操作"
        generate_report 0 $TOTAL_PROJECTS "阶段1 (创建项目): ${phase1_duration}s"
        return 1
    fi
    
    log "INFO" "✅ 阶段1完成: ${#created_project_ids[@]}/${TOTAL_PROJECTS} 项目创建成功"
    
    # === 阶段 2: 智能等待 ===
    local phase2_start=$SECONDS
    log "INFO" "⏳ 阶段2: 智能等待 ${GLOBAL_WAIT_SECONDS}s (GCP后端同步)"
    
    # 显示等待进度
    for ((i=1; i<=GLOBAL_WAIT_SECONDS; i++)); do 
        show_progress $i $GLOBAL_WAIT_SECONDS "等待同步" 0 0
        sleep 1
    done
    echo; local phase2_duration=$((SECONDS - phase2_start))
    
    # === 阶段 3: 批量启用API ===
    local phase3_start=$SECONDS
    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/enabled_projects.txt"; > "$ENABLED_PROJECTS_FILE"
    export -f task_enable_api log retry_with_backoff
    
    run_parallel_batched task_enable_api "🔧 阶段3: 启用API" "$ENABLED_PROJECTS_FILE" "${created_project_ids[@]}"
    
    local enabled_project_ids=()
    if [ -f "$ENABLED_PROJECTS_FILE" ]; then 
      mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"
    fi
    local phase3_duration=$((SECONDS - phase3_start))
    
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then
        log "ERROR" "❌ API启用阶段完全失败，中止操作"
        local phase_times="阶段1: ${phase1_duration}s, 阶段2: ${phase2_duration}s, 阶段3: ${phase3_duration}s"
        generate_report 0 $TOTAL_PROJECTS "$phase_times"
        return 1
    fi
    
    log "INFO" "✅ 阶段3完成: ${#enabled_project_ids[@]}/${#created_project_ids[@]} API启用成功"
    
    # === 阶段 4: 批量创建密钥 ===
    local phase4_start=$SECONDS
    export -f task_create_key log retry_with_backoff parse_json write_keys_to_files
    export PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE JSON_KEY_FILE KEY_CREATE_TIMEOUT
    
    run_parallel_batched task_create_key "🔑 阶段4: 创建密钥" "/dev/null" "${enabled_project_ids[@]}"
    
    local phase4_duration=$((SECONDS - phase4_start))
    
    # 完成JSON文件
    if [[ -s "$JSON_KEY_FILE" ]]; then echo "]" >> "$JSON_KEY_FILE"; fi
    
    # === 最终报告 ===
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null | xargs || echo "0")
    local total_duration=$((SECONDS - start_total))
    
    local phase_times="阶段1 (创建): ${phase1_duration}s, 阶段2 (等待): ${phase2_duration}s, 阶段3 (API): ${phase3_duration}s, 阶段4 (密钥): ${phase4_duration}s"
    
    generate_report "$successful_keys" "$TOTAL_PROJECTS" "$phase_times"
    
    # 性能统计
    if [ "$successful_keys" -gt 0 ] && [ $total_duration -gt 0 ]; then
        local keys_per_minute=$(echo "scale=2; $successful_keys * 60 / $total_duration" | bc 2>/dev/null || echo "N/A")
        log "INFO" "🎯 平均速率: $keys_per_minute 密钥/分钟"
    fi
    
    log "INFO" "📊 详细性能数据已保存至: $PERFORMANCE_LOG"
    
    if [ "$successful_keys" -lt "$TOTAL_PROJECTS" ]; then 
        local missing=$((TOTAL_PROJECTS - successful_keys))
        log "WARN" "⚠️  有 $missing 个项目未能成功获取密钥"
    fi
    
    log "INFO" "💡 提醒: 项目需要关联有效的结算账号才能使用API密钥"
    log "INFO" "======================================================"
}

# 删除功能保持不变，但添加性能日志
delete_all_existing_projects() {
  local start_time=$SECONDS
  log "INFO" "🗑️  开始删除所有现有项目..."
  
  local list_error="${TEMP_DIR}/list_projects_error.log"
  local ALL_PROJECTS=($(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet 2>"$list_error"))
  
  if [ $? -ne 0 ]; then 
    log "ERROR" "无法获取项目列表: $(cat "$list_error")"
    return 1
  fi
  
  if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then 
    log "INFO" "未找到任何用户项目，无需删除"
    return 0
  fi
  
  local total_to_delete=${#ALL_PROJECTS[@]}
  log "INFO" "找到 $total_to_delete 个项目需要删除"
  
  echo "项目列表预览 (前10个):"
  printf '%s\n' "${ALL_PROJECTS[@]:0:10}"
  if [ $total_to_delete -gt 10 ]; then echo "... 还有 $((total_to_delete-10)) 个项目"; fi
  
  read -p "!!! 危险操作 !!! 确认要删除所有 $total_to_delete 个项目吗？(输入 'DELETE-ALL' 确认): " confirm
  if [ "$confirm" != "DELETE-ALL" ]; then 
    log "INFO" "删除操作已取消"
    return 1
  fi
  
  echo "项目删除日志 ($(date +%Y-%m-%d_%H:%M:%S))" > "$DELETION_LOG"
  echo "------------------------------------" >> "$DELETION_LOG"
  
  export -f delete_project log retry_with_backoff show_progress
  export DELETION_LOG TEMP_DIR MAX_PARALLEL_JOBS MAX_RETRY_ATTEMPTS
  
  run_parallel_batched delete_project "🗑️ 删除项目" "/dev/null" "${ALL_PROJECTS[@]}"
  
  local duration=$((SECONDS - start_time))
  local successful_deletions=$(grep -c "成功删除项目:" "$DELETION_LOG" 2>/dev/null || echo "0")
  local failed_deletions=$(grep -c "删除项目失败:" "$DELETION_LOG" 2>/dev/null || echo "0")
  
  echo ""; echo "========== 删除报告 =========="
  echo "总计尝试: $total_to_delete 个项目"
  echo "成功删除: $successful_deletions 个"
  echo "删除失败: $failed_deletions 个" 
  echo "执行时间: $((duration/60))分${duration%60}秒"
  echo "详细日志: $DELETION_LOG"
  echo "=========================="
}

delete_project() {
  local project_id="$1"
  local error_log="${TEMP_DIR}/delete_${project_id}_error.log"
  
  if gcloud projects delete "$project_id" --quiet 2>"$error_log"; then
    log "SUCCESS" "成功删除: $project_id"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 成功删除项目: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    rm -f "$error_log"; return 0
  else
    local error_msg=$(cat "$error_log" 2>/dev/null || echo "未知错误")
    log "ERROR" "删除失败: $project_id: $error_msg"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除项目失败: $project_id - $error_msg" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    rm -f "$error_log"; return 1
  fi
}

# 增强的配置功能
configure_settings() {
  while true; do
      clear; echo "⚙️  配置参数"; echo "======================================================"
      echo "当前配置:"
      echo "1. 项目数量: $TOTAL_PROJECTS"
      echo "2. 项目前缀: $PROJECT_PREFIX"  
      echo "3. 并行任务数: $MAX_PARALLEL_JOBS"
      echo "4. 批处理大小: $BATCH_SIZE"
      echo "5. 最大重试次数: $MAX_RETRY_ATTEMPTS"
      echo "6. 全局等待时间: ${GLOBAL_WAIT_SECONDS}s"
      echo "7. API启用超时: ${API_ENABLE_TIMEOUT}s"
      echo "8. 密钥创建超时: ${KEY_CREATE_TIMEOUT}s"
      echo "0. 返回主菜单"
      echo "======================================================"
      
      read -p "请选择要修改的设置 [0-8]: " setting_choice
      
      case $setting_choice in
        1) 
          read -p "请输入项目数量 (1-500, 当前: $TOTAL_PROJECTS): " new_count
          if [[ "$new_count" =~ ^[1-9][0-9]*$ ]] && [ "$new_count" -le 500 ]; then 
            TOTAL_PROJECTS=$new_count
            log "INFO" "项目数量已设置为: $TOTAL_PROJECTS"
          else
            echo "❌ 无效输入，请输入1-500之间的数字"; sleep 2
          fi
          ;;
        2) 
          read -p "请输入项目前缀 (3-20字符, 字母开头, 当前: $PROJECT_PREFIX): " new_prefix
          if [[ "$new_prefix" =~ ^[a-z][a-z0-9-]{2,19}$ ]]; then 
            PROJECT_PREFIX="$new_prefix"
            log "INFO" "项目前缀已设置为: $PROJECT_PREFIX"
          else
            echo "❌ 前缀必须以字母开头，3-20字符，只能包含小写字母、数字和连字符"; sleep 2
          fi
          ;;
        3) 
          read -p "请输入并行任务数 (10-100, 推荐40-80, 当前: $MAX_PARALLEL_JOBS): " new_parallel
          if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]] && [ "$new_parallel" -ge 10 ] && [ "$new_parallel" -le 100 ]; then 
            MAX_PARALLEL_JOBS=$new_parallel
            log "INFO" "并行任务数已设置为: $MAX_PARALLEL_JOBS"
          else
            echo "❌ 请输入10-100之间的数字"; sleep 2
          fi
          ;;
        4) 
          read -p "请输入批处理大小 (5-50, 当前: $BATCH_SIZE): " new_batch
          if [[ "$new_batch" =~ ^[1-9][0-9]*$ ]] && [ "$new_batch" -ge 5 ] && [ "$new_batch" -le 50 ]; then 
            BATCH_SIZE=$new_batch
            log "INFO" "批处理大小已设置为: $BATCH_SIZE"
          else
            echo "❌ 请输入5-50之间的数字"; sleep 2
          fi
          ;;
        5) 
          read -p "请输入最大重试次数 (1-10, 当前: $MAX_RETRY_ATTEMPTS): " new_retries
          if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]] && [ "$new_retries" -le 10 ]; then 
            MAX_RETRY_ATTEMPTS=$new_retries
            log "INFO" "最大重试次数已设置为: $MAX_RETRY_ATTEMPTS"
          else
            echo "❌ 请输入1-10之间的数字"; sleep 2
          fi
          ;;
        6) 
          read -p "请输入全局等待时间 (15-300秒, 当前: $GLOBAL_WAIT_SECONDS): " new_wait
          if [[ "$new_wait" =~ ^[1-9][0-9]*$ ]] && [ "$new_wait" -ge 15 ] && [ "$new_wait" -le 300 ]; then 
            GLOBAL_WAIT_SECONDS=$new_wait
            log "INFO" "全局等待时间已设置为: ${GLOBAL_WAIT_SECONDS}s"
          else
            echo "❌ 请输入15-300之间的数字"; sleep 2
          fi
          ;;
        7) 
          read -p "请输入API启用超时 (60-600秒, 当前: $API_ENABLE_TIMEOUT): " new_timeout
          if [[ "$new_timeout" =~ ^[1-9][0-9]*$ ]] && [ "$new_timeout" -ge 60 ] && [ "$new_timeout" -le 600 ]; then 
            API_ENABLE_TIMEOUT=$new_timeout
            log "INFO" "API启用超时已设置为: ${API_ENABLE_TIMEOUT}s"
          else
            echo "❌ 请输入60-600之间的数字"; sleep 2
          fi
          ;;
        8) 
          read -p "请输入密钥创建超时 (30-300秒, 当前: $KEY_CREATE_TIMEOUT): " new_key_timeout
          if [[ "$new_key_timeout" =~ ^[1-9][0-9]*$ ]] && [ "$new_key_timeout" -ge 30 ] && [ "$new_key_timeout" -le 300 ]; then 
            KEY_CREATE_TIMEOUT=$new_key_timeout
            log "INFO" "密钥创建超时已设置为: ${KEY_CREATE_TIMEOUT}s"
          else
            echo "❌ 请输入30-300之间的数字"; sleep 2
          fi
          ;;
        0) return ;;
        *) echo "❌ 无效选项，请重新选择"; sleep 2 ;;
      esac
  done
}

# 显示性能统计
show_performance_stats() {
  clear
  echo "📊 性能统计"; echo "======================================================"
  
  if [ ! -f "$PERFORMANCE_LOG" ]; then
    echo "暂无性能数据"; echo "请先运行密钥创建功能后查看"
    read -p "按回车键返回..."; return
  fi
  
  echo "📈 操作统计:"
  local create_success=$(grep -c "CREATE.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  local create_failed=$(grep -c "CREATE.*FAILED" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  local enable_success=$(grep -c "ENABLE.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  local enable_failed=$(grep -c "ENABLE.*FAILED" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  local key_success=$(grep -c "KEY.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  local key_failed=$(grep -c "KEY.*FAILED" "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
  
  echo "项目创建: 成功 $create_success, 失败 $create_failed"
  echo "API启用: 成功 $enable_success, 失败 $enable_failed"  
  echo "密钥创建: 成功 $key_success, 失败 $key_failed"
  echo ""
  
  echo "⏱️ 平均用时分析:"
  # 计算平均时间
  if command -v awk >/dev/null 2>&1; then
    local avg_create=$(grep "CREATE.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null | awk -F',' '{sum+=$3; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
    local avg_enable=$(grep "ENABLE.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null | awk -F',' '{sum+=$3; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
    local avg_key=$(grep "KEY.*SUCCESS" "$PERFORMANCE_LOG" 2>/dev/null | awk -F',' '{sum+=$3; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
    
    echo "项目创建平均: ${avg_create}s"
    echo "API启用平均: ${avg_enable}s"
    echo "密钥创建平均: ${avg_key}s"
  else
    echo "需要awk命令来计算平均时间"
  fi
  
  echo ""; echo "🔍 最近失败记录 (最后5个):"
  grep "FAILED" "$PERFORMANCE_LOG" 2>/dev/null | tail -5 | while IFS=',' read -r operation project duration result; do
    echo "- $operation $project: $result"
  done
  
  echo ""; echo "📁 日志文件位置: $PERFORMANCE_LOG"
  read -p "按回车键返回主菜单..."
}

# 增强的主菜单
show_menu() {
  clear
  echo "======================================================"
  echo "🚀 GCP Gemini API 密钥极速管理工具 v4.0"
  echo "======================================================"
  
  # 显示当前状态
  local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1)
  if [ -z "$current_account" ]; then current_account="❌ 未认证"; fi
  
  local current_project; current_project=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$current_project" ]; then current_project="未设置"; fi
  
  echo "📋 当前状态:"
  echo "   账号: $current_account"
  echo "   项目: $current_project"
  echo ""
  echo "⚙️ 当前配置:"
  echo "   数量: $TOTAL_PROJECTS 个项目 | 前缀: $PROJECT_PREFIX"
  echo "   并行: $MAX_PARALLEL_JOBS 任务 | 批量: $BATCH_SIZE"
  echo "   重试: $MAX_RETRY_ATTEMPTS 次 | 等待: ${GLOBAL_WAIT_SECONDS}s"
  echo ""
  echo "🎯 功能菜单:"
  echo "1. 🚀 [极速模式] 批量创建项目并获取API密钥"
  echo "2. 🗑️  删除所有现有项目"  
  echo "3. ⚙️  配置参数设置"
  echo "4. 📊 查看性能统计"
  echo "5. 🔍 检查输出文件"
  echo "0. 🚪 退出程序"
  echo "======================================================"
  
  read -p "请输入选项 [0-5]: " choice
  
  case $choice in
    1) create_projects_and_get_keys_ultra ;;
    2) delete_all_existing_projects ;;
    3) configure_settings ;;
    4) show_performance_stats ;;
    5) check_output_files ;;
    0) log "INFO" "👋 程序退出，感谢使用!"; exit 0 ;;
    *) echo "❌ 无效选项 '$choice'，请重新选择"; sleep 2 ;;
  esac
  
  if [[ "$choice" =~ ^[1-5]$ ]]; then 
    echo ""; read -p "按回车键返回主菜单..."
  fi
}

# 检查输出文件功能
check_output_files() {
  clear
  echo "📁 输出文件检查"; echo "======================================================"
  
  local files=("$PURE_KEY_FILE" "$COMMA_SEPARATED_KEY_FILE" "$JSON_KEY_FILE")
  local file_descriptions=("纯密钥文件" "逗号分隔密钥" "JSON详细信息")
  
  for i in "${!files[@]}"; do
    local file="${files[$i]}"
    local desc="${file_descriptions[$i]}"
    
    echo "📄 $desc ($file):"
    if [ -f "$file" ]; then
      local size=$(wc -c < "$file" 2>/dev/null || echo "0")
      local lines=$(wc -l < "$file" 2>/dev/null || echo "0")
      echo "   ✅ 存在 | 大小: ${size} 字节 | 行数: ${lines}"
      
      if [ "$file" = "$PURE_KEY_FILE" ] && [ $lines -gt 0 ]; then
        echo "   🎯 包含 $lines 个API密钥"
        echo "   📝 预览 (前3个):"
        head -3 "$file" 2>/dev/null | sed 's/\(.\{20\}\).*/\1.../' | sed 's/^/      /'
      fi
    else
      echo "   ❌ 文件不存在"
    fi
    echo ""
  done
  
  # 检查性能日志
  echo "📊 性能日志 ($PERFORMANCE_LOG):"
  if [ -f "$PERFORMANCE_LOG" ]; then
    local log_size=$(wc -c < "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
    local log_lines=$(wc -l < "$PERFORMANCE_LOG" 2>/dev/null || echo "0")
    echo "   ✅ 存在 | 大小: ${log_size} 字节 | 条目: ${log_lines}"
  else
    echo "   ❌ 文件不存在"
  fi
  
  echo ""; read -p "按回车键返回主菜单..."
}

# 清理资源函数
cleanup_resources() {
  log "INFO" "🧹 执行清理工作..."
  if [ -d "$TEMP_DIR" ]; then 
    rm -rf "$TEMP_DIR"
    log "INFO" "临时目录已清理: $TEMP_DIR"
  fi
  
  # 完成JSON文件（如果未完成）
  if [ -f "$JSON_KEY_FILE" ] && ! tail -1 "$JSON_KEY_FILE" | grep -q "]"; then
    echo "]" >> "$JSON_KEY_FILE"
  fi
}

# ===== 主程序入口 =====
main() {
  # 设置信号处理
  trap cleanup_resources EXIT SIGINT SIGTERM
  
  # 检查依赖
  local missing_deps=()
  for cmd in gcloud bc timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_deps+=("$cmd")
    fi
  done
  
  if [ ${#missing_deps[@]} -gt 0 ]; then
    log "ERROR" "❌ 缺少必要依赖: ${missing_deps[*]}"
    echo "请安装缺少的命令后重新运行脚本"
    exit 1
  fi
  
  # 检查GCP认证
  log "INFO" "🔐 检查GCP认证状态..."
  if ! gcloud auth list --filter=status:ACTIVE >/dev/null 2>&1; then
    log "WARN" "⚠️  未检测到活动的GCP认证"
    echo "正在启动认证流程..."
    if ! gcloud auth login; then
      log "ERROR" "❌ GCP认证失败"
      exit 1
    fi
  fi
  
  log "INFO" "✅ GCP认证检查通过"
  
  # 检查项目配置（可选）
  if ! gcloud config get-value project >/dev/null 2>&1; then
    log "INFO" "💡 提示: 可以使用 'gcloud config set project PROJECT_ID' 设置默认项目"
  fi
  
  # 主循环
  while true; do 
    show_menu
  done
}

# 启动程序
main "$@"
