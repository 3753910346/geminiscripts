#!/bin/bash

# 针对已存在项目的API密钥提取脚本
# 解决项目配额已满的问题

# ===== 配置 =====
TIMESTAMP=$(date +%s)
TEMP_DIR="/tmp/existing_projects_${TIMESTAMP}"
PURE_KEY_FILE="existing_keys.txt"
COMMA_SEPARATED_KEY_FILE="existing_comma_keys.txt"
MAX_PARALLEL_JOBS=5  # 保守的并行数
API_ENABLE_WAIT=10   # API启用等待时间
MAX_RETRY_ATTEMPTS=3
PROJECT_LOG="${TEMP_DIR}/project_status.log"

mkdir -p "$TEMP_DIR"

# ===== 日志函数 =====
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${TEMP_DIR}/script.log"
}

# ===== JSON解析函数 =====
parse_json() {
    local json="$1"
    local field="$2"
    
    if [ -z "$json" ]; then
        return 1
    fi
    
    local value=""
    case "$field" in
        ".keyString")
            value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p')
            if [ -z "$value" ]; then
                value=$(echo "$json" | grep -oP '(?<="keyString":\s*")[^"]*' 2>/dev/null || true)
            fi
            ;;
    esac
    
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    else
        return 1
    fi
}

# ===== 写入密钥文件 =====
write_keys_to_files() {
    local api_key="$1"
    local project_id="$2"
    if [ -z "$api_key" ]; then return; fi
    
    (
        flock 200
        echo "$api_key" >> "$PURE_KEY_FILE"
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then 
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        echo "项目: $project_id -> 密钥: ${api_key:0:20}..." >> "${TEMP_DIR}/key_mapping.txt"
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# ===== 检查项目状态 =====
check_project_status() {
    local project_id="$1"
    
    # 检查项目是否存在
    if ! gcloud projects describe "$project_id" >/dev/null 2>&1; then
        echo "NOT_EXIST"
        return
    fi
    
    # 检查项目是否处于活动状态
    local project_state=$(gcloud projects describe "$project_id" --format="value(lifecycleState)" 2>/dev/null)
    if [ "$project_state" != "ACTIVE" ]; then
        echo "INACTIVE"
        return
    fi
    
    # 检查API是否已启用
    if gcloud services list --enabled --project="$project_id" --filter="config.name:generativelanguage.googleapis.com" --quiet 2>/dev/null | grep -q generativelanguage; then
        echo "API_ENABLED"
    else
        echo "API_DISABLED"
    fi
}

# ===== 启用API =====
enable_api_for_project() {
    local project_id="$1"
    local error_log="${TEMP_DIR}/enable_${project_id}.log"
    
    log "INFO" "为项目 $project_id 启用 Generative Language API..."
    
    if gcloud services enable generativelanguage.googleapis.com \
        --project="$project_id" \
        --quiet 2>"$error_log"; then
        
        # 等待API完全启用
        log "INFO" "等待 ${API_ENABLE_WAIT} 秒让API完全启用..."
        sleep $API_ENABLE_WAIT
        
        # 验证API状态
        if gcloud services list --enabled --project="$project_id" \
            --filter="config.name:generativelanguage.googleapis.com" \
            --quiet 2>/dev/null | grep -q generativelanguage; then
            log "SUCCESS" "API启用成功: $project_id"
            rm -f "$error_log"
            return 0
        else
            log "WARN" "API可能未完全同步，继续尝试: $project_id"
            sleep 5
            return 0
        fi
    else
        log "ERROR" "启用API失败: $project_id - $(cat "$error_log" 2>/dev/null)"
        rm -f "$error_log"
        return 1
    fi
}

# ===== 创建API密钥 =====
create_api_key_for_project() {
    local project_id="$1"
    local error_log="${TEMP_DIR}/key_${project_id}.log"
    local output_log="${TEMP_DIR}/key_output_${project_id}.log"
    
    log "INFO" "为项目 $project_id 创建API密钥..."
    
    # 设置当前项目
    gcloud config set project "$project_id" --quiet
    
    local attempt=1
    while [ $attempt -le $MAX_RETRY_ATTEMPTS ]; do
        log "INFO" "尝试 $attempt/$MAX_RETRY_ATTEMPTS 创建API密钥..."
        
        local create_output
        create_output=$(gcloud services api-keys create \
            --project="$project_id" \
            --display-name="Gemini API Key $(date +%Y%m%d_%H%M%S)" \
            --format="json" \
            --quiet 2>"$error_log")
        
        local exit_code=$?
        echo "$create_output" > "$output_log"
        
        if [ $exit_code -eq 0 ] && [ -n "$create_output" ]; then
            # 尝试解析API密钥
            local api_key
            api_key=$(parse_json "$create_output" ".keyString")
            
            if [ -n "$api_key" ]; then
                log "SUCCESS" "成功创建API密钥: $project_id"
                write_keys_to_files "$api_key" "$project_id"
                rm -f "$error_log" "$output_log"
                return 0
            else
                log "WARN" "API密钥创建成功但无法解析，查看输出文件: $output_log"
            fi
        fi
        
        if [ $attempt -lt $MAX_RETRY_ATTEMPTS ]; then
            local wait_time=$((attempt * 5))
            log "INFO" "等待 $wait_time 秒后重试..."
            sleep $wait_time
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "创建API密钥失败: $project_id"
    return 1
}

# ===== 处理现有项目 =====
process_existing_projects() {
    log "INFO" "======================================================"
    log "INFO" "开始处理现有项目的API密钥提取"
    log "INFO" "======================================================"
    
    # 清空输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"
    > "${TEMP_DIR}/key_mapping.txt"
    
    # 获取所有项目
    log "INFO" "获取项目列表..."
    local all_projects=($(gcloud projects list --format="value(projectId)" --filter="lifecycleState:ACTIVE" 2>/dev/null))
    
    if [ ${#all_projects[@]} -eq 0 ]; then
        log "ERROR" "未找到任何活跃项目"
        return 1
    fi
    
    log "INFO" "找到 ${#all_projects[@]} 个活跃项目"
    
    # 检查每个项目的状态
    log "INFO" "检查项目状态..."
    echo "项目状态检查报告:" > "$PROJECT_LOG"
    echo "==================" >> "$PROJECT_LOG"
    
    local api_enabled_projects=()
    local api_disabled_projects=()
    
    for project_id in "${all_projects[@]}"; do
        local status=$(check_project_status "$project_id")
        echo "$project_id: $status" >> "$PROJECT_LOG"
        
        case "$status" in
            "API_ENABLED")
                api_enabled_projects+=("$project_id")
                log "INFO" "✓ $project_id (API已启用)"
                ;;
            "API_DISABLED")
                api_disabled_projects+=("$project_id")
                log "INFO" "○ $project_id (需要启用API)"
                ;;
            "INACTIVE"|"NOT_EXIST")
                log "WARN" "✗ $project_id (项目不可用)"
                ;;
        esac
    done
    
    log "INFO" "状态统计:"
    log "INFO" "- API已启用: ${#api_enabled_projects[@]} 个"
    log "INFO" "- 需要启用API: ${#api_disabled_projects[@]} 个"
    
    # 为需要的项目启用API
    if [ ${#api_disabled_projects[@]} -gt 0 ]; then
        log "INFO" "======================================================"
        log "INFO" "阶段1: 为 ${#api_disabled_projects[@]} 个项目启用API"
        log "INFO" "======================================================"
        
        for project_id in "${api_disabled_projects[@]}"; do
            if enable_api_for_project "$project_id"; then
                api_enabled_projects+=("$project_id")
            fi
            sleep 2  # 避免速率限制
        done
    fi
    
    # 为所有启用了API的项目创建密钥
    if [ ${#api_enabled_projects[@]} -gt 0 ]; then
        log "INFO" "======================================================"
        log "INFO" "阶段2: 为 ${#api_enabled_projects[@]} 个项目创建API密钥"
        log "INFO" "======================================================"
        
        local successful_keys=0
        local failed_keys=0
        
        for project_id in "${api_enabled_projects[@]}"; do
            if create_api_key_for_project "$project_id"; then
                successful_keys=$((successful_keys + 1))
            else
                failed_keys=$((failed_keys + 1))
            fi
            
            # 显示进度
            local processed=$((successful_keys + failed_keys))
            echo "进度: $processed/${#api_enabled_projects[@]} (成功:$successful_keys 失败:$failed_keys)"
            
            sleep 3  # 避免速率限制
        done
        
        # 最终报告
        log "INFO" "======================================================"
        log "INFO" "执行完成报告:"
        log "INFO" "- 处理项目总数: ${#all_projects[@]}"
        log "INFO" "- API启用项目: ${#api_enabled_projects[@]}"
        log "INFO" "- 成功获取密钥: $successful_keys"
        log "INFO" "- 失败: $failed_keys"
        log "INFO" "- 密钥文件: $PURE_KEY_FILE"
        log "INFO" "- 密钥映射: ${TEMP_DIR}/key_mapping.txt"
        log "INFO" "- 项目状态: $PROJECT_LOG"
        log "INFO" "======================================================"
        
        if [ $successful_keys -gt 0 ]; then
            echo ""
            echo "成功！已获取 $successful_keys 个API密钥"
            echo "密钥保存在: $PURE_KEY_FILE"
            echo "项目-密钥映射保存在: ${TEMP_DIR}/key_mapping.txt"
            return 0
        else
            echo ""
            echo "未能获取任何API密钥，请检查日志: ${TEMP_DIR}/script.log"
            return 1
        fi
    else
        log "ERROR" "没有任何项目可以创建API密钥"
        return 1
    fi
}

# ===== 清理函数 =====
cleanup() {
    log "INFO" "清理临时文件..."
    # 保留重要的日志文件，只删除临时文件
    find "$TEMP_DIR" -name "*.log" -not -name "script.log" -not -name "key_mapping.txt" -not -name "project_status.log" -delete 2>/dev/null || true
}

# ===== 主程序 =====
trap cleanup EXIT

echo "现有项目API密钥提取工具"
echo "========================"
echo ""

# 检查依赖
if ! command -v gcloud &>/dev/null; then
    log "ERROR" "未找到 gcloud 命令，请安装 Google Cloud SDK"
    exit 1
fi

# 检查认证
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    log "ERROR" "未找到活跃的GCP账户，请运行: gcloud auth login"
    exit 1
fi

# 显示当前账户信息
current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
log "INFO" "当前账户: $current_account"

# 询问用户确认
echo ""
echo "此脚本将："
echo "1. 扫描你账户下的所有现有项目"
echo "2. 为还没有启用 Generative Language API 的项目启用该API"
echo "3. 为所有项目创建新的API密钥"
echo ""
read -p "确认继续？(y/N): " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    process_existing_projects
else
    log "INFO" "操作已取消"
    exit 0
fi
