#!/bin/bash

# 修复版本 - 针对API密钥提取问题的改进

# ===== 配置 =====
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=5  # 减少到5个用于测试
MAX_PARALLEL_JOBS=2  # 大幅减少并发数
GLOBAL_WAIT_SECONDS=30 # 增加等待时间
API_ENABLE_WAIT=15  # API启用后的等待时间
MAX_RETRY_ATTEMPTS=5
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"

mkdir -p "$TEMP_DIR"

# ===== 改进的日志函数 =====
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${TEMP_DIR}/debug.log"
}

# ===== 改进的JSON解析 =====
parse_json() {
    local json="$1"
    local field="$2"
    
    # 更好的错误处理
    if [ -z "$json" ]; then
        log "ERROR" "JSON输入为空"
        return 1
    fi
    
    # 多种解析方法
    local value=""
    case "$field" in
        ".keyString")
            # 方法1：使用sed
            value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p')
            
            # 方法2：如果sed失败，尝试grep
            if [ -z "$value" ]; then
                value=$(echo "$json" | grep -oP '(?<="keyString":\s*")[^"]*')
            fi
            
            # 方法3：使用awk作为备选
            if [ -z "$value" ]; then
                value=$(echo "$json" | awk -F'"keyString":"' '{print $2}' | awk -F'"' '{print $1}')
            fi
            ;;
    esac
    
    if [ -n "$value" ]; then
        log "DEBUG" "成功解析字段 $field: ${value:0:20}..."
        echo "$value"
        return 0
    else
        log "ERROR" "无法解析字段 $field，JSON内容: ${json:0:200}..."
        return 1
    fi
}

# ===== 改进的密钥创建函数 =====
task_create_key() {
    local project_id="$1"
    local error_log="${TEMP_DIR}/key_${project_id}_error.log"
    local output_log="${TEMP_DIR}/key_${project_id}_output.log"
    
    log "INFO" "开始为项目 $project_id 创建API密钥..."
    
    # 先检查项目状态
    if ! gcloud projects describe "$project_id" >/dev/null 2>&1; then
        log "ERROR" "项目 $project_id 不存在或无法访问"
        return 1
    fi
    
    # 检查API是否已启用
    if ! gcloud services list --enabled --project="$project_id" --filter="config.name:generativelanguage.googleapis.com" --quiet | grep -q generativelanguage; then
        log "ERROR" "项目 $project_id 的 Generative Language API 未启用"
        return 1
    fi
    
    # 设置当前项目（重要！）
    gcloud config set project "$project_id" --quiet
    
    # 等待一段时间确保API完全激活
    log "INFO" "等待 ${API_ENABLE_WAIT} 秒确保API完全激活..."
    sleep $API_ENABLE_WAIT
    
    # 创建API密钥，使用更详细的输出
    local create_output
    local attempt=1
    
    while [ $attempt -le $MAX_RETRY_ATTEMPTS ]; do
        log "INFO" "尝试 $attempt/$MAX_RETRY_ATTEMPTS 创建API密钥..."
        
        create_output=$(gcloud services api-keys create \
            --project="$project_id" \
            --display-name="Gemini API Key for $project_id" \
            --format="json" \
            --verbosity="info" \
            --quiet 2>"$error_log")
        
        local exit_code=$?
        
        # 保存完整输出用于调试
        echo "$create_output" > "$output_log"
        
        if [ $exit_code -eq 0 ] && [ -n "$create_output" ]; then
            log "DEBUG" "gcloud命令执行成功，输出长度: ${#create_output}"
            break
        else
            log "WARN" "尝试 $attempt 失败，错误: $(cat "$error_log")"
            if [ $attempt -lt $MAX_RETRY_ATTEMPTS ]; then
                local wait_time=$((attempt * 10))
                log "INFO" "等待 $wait_time 秒后重试..."
                sleep $wait_time
            fi
            attempt=$((attempt + 1))
        fi
    done
    
    if [ $attempt -gt $MAX_RETRY_ATTEMPTS ]; then
        log "ERROR" "创建API密钥失败，已达到最大重试次数"
        return 1
    fi
    
    # 尝试解析API密钥
    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    
    if [ -n "$api_key" ]; then
        log "SUCCESS" "成功提取API密钥: $project_id -> ${api_key:0:20}..."
        
        # 写入文件
        (
            flock 200
            echo "$api_key" >> "$PURE_KEY_FILE"
            if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
                echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
            fi
            echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        ) 200>"${TEMP_DIR}/key_files.lock"
        
        rm -f "$error_log" "$output_log"
        return 0
    else
        log "ERROR" "无法从输出中提取API密钥"
        log "DEBUG" "完整输出内容保存在: $output_log"
        return 1
    fi
}

# ===== 改进的API启用函数 =====
task_enable_api() {
    local project_id="$1"
    local success_file="$2"
    local error_log="${TEMP_DIR}/enable_${project_id}_error.log"
    
    log "INFO" "为项目 $project_id 启用 Generative Language API..."
    
    # 设置当前项目
    gcloud config set project "$project_id" --quiet
    
    # 启用API
    if gcloud services enable generativelanguage.googleapis.com \
        --project="$project_id" \
        --quiet 2>"$error_log"; then
        
        log "SUCCESS" "API启用成功: $project_id"
        
        # 验证API是否真正启用
        local check_count=0
        while [ $check_count -lt 6 ]; do
            if gcloud services list --enabled --project="$project_id" \
                --filter="config.name:generativelanguage.googleapis.com" \
                --quiet | grep -q generativelanguage; then
                log "INFO" "API状态验证成功: $project_id"
                (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
                rm -f "$error_log"
                return 0
            fi
            log "INFO" "等待API状态同步... ($((check_count + 1))/6)"
            sleep 5
            check_count=$((check_count + 1))
        done
        
        log "WARN" "API可能未完全启用，但继续处理: $project_id"
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
        rm -f "$error_log"
        return 0
    else
        log "ERROR" "启用API失败: $project_id: $(cat "$error_log")"
        rm -f "$error_log"
        return 1
    fi
}

# ===== 主要功能 =====
create_projects_and_get_keys_test() {
    log "INFO" "======================================================"
    log "INFO" "测试模式: 创建 $TOTAL_PROJECTS 个项目并获取API密钥"
    log "INFO" "======================================================"
    
    # 清空输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"
    
    # 生成项目ID列表
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        local project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        projects_to_create+=("$project_id")
    done
    
    log "INFO" "将创建以下项目: ${projects_to_create[*]}"
    
    # 阶段1：创建项目（串行执行以避免配额问题）
    log "INFO" "阶段1: 创建项目 (串行执行)..."
    local created_projects=()
    for project_id in "${projects_to_create[@]}"; do
        log "INFO" "创建项目: $project_id"
        if gcloud projects create "$project_id" --name="$project_id" --quiet; then
            log "SUCCESS" "项目创建成功: $project_id"
            created_projects+=("$project_id")
        else
            log "ERROR" "项目创建失败: $project_id"
        fi
        sleep 2  # 避免速率限制
    done
    
    if [ ${#created_projects[@]} -eq 0 ]; then
        log "ERROR" "没有成功创建任何项目"
        return 1
    fi
    
    # 阶段2：全局等待
    log "INFO" "阶段2: 等待 ${GLOBAL_WAIT_SECONDS} 秒让项目状态同步..."
    sleep $GLOBAL_WAIT_SECONDS
    
    # 阶段3：启用API（串行执行）
    log "INFO" "阶段3: 启用API (串行执行)..."
    local enabled_projects=()
    for project_id in "${created_projects[@]}"; do
        if task_enable_api "$project_id" "/dev/null"; then
            enabled_projects+=("$project_id")
        fi
        sleep 3  # 避免速率限制
    done
    
    if [ ${#enabled_projects[@]} -eq 0 ]; then
        log "ERROR" "没有成功启用任何API"
        return 1
    fi
    
    # 阶段4：创建API密钥（串行执行）
    log "INFO" "阶段4: 创建API密钥 (串行执行)..."
    local successful_keys=0
    for project_id in "${enabled_projects[@]}"; do
        if task_create_key "$project_id"; then
            successful_keys=$((successful_keys + 1))
        fi
        sleep 5  # 给API密钥创建更多时间
    done
    
    # 最终报告
    log "INFO" "======================================================"
    log "INFO" "执行完成报告:"
    log "INFO" "成功创建项目: ${#created_projects[@]}"
    log "INFO" "成功启用API: ${#enabled_projects[@]}"
    log "INFO" "成功获取密钥: $successful_keys"
    log "INFO" "密钥保存文件: $PURE_KEY_FILE"
    log "INFO" "调试日志: ${TEMP_DIR}/debug.log"
    log "INFO" "======================================================"
    
    if [ $successful_keys -gt 0 ]; then
        log "SUCCESS" "至少获取了一些API密钥，检查 $PURE_KEY_FILE"
        return 0
    else
        log "ERROR" "未能获取任何API密钥"
        return 1
    fi
}

# ===== 主程序 =====
echo "修复版API密钥获取脚本"
echo "===================================="

# 检查依赖
if ! command -v gcloud &> /dev/null; then
    log "ERROR" "gcloud命令未找到，请安装Google Cloud SDK"
    exit 1
fi

# 检查认证
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    log "ERROR" "未找到活动的GCP账户，请运行 'gcloud auth login'"
    exit 1
fi

# 运行主要功能
create_projects_and_get_keys_test

log "INFO" "脚本执行完成"
