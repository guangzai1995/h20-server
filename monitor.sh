#!/bin/bash

# 配置多个模型参数
declare -A MODELS

# 模型1配置
MODELS["Qwen3-235B"]="
CONTAINER_NAME=Qwen3-235B
HEALTH_CHECK_URL=http://localhost:30000/health
CHECK_INTERVAL=10
RESTART_DELAY=220
MAX_RETRIES=3
RUN_COMMAND=docker run -itd -v /aipublic/model:/model -v /aipublic:/aipublic --name Qwen3-235B --privileged=True --gpus all --shm-size=16g --ipc=host -p 30000:30000 --ulimit memlock=-1 --restart=always -e CUDA_VISIBLE_DEVICES=4,5,6,7 vllm:0.10.1 bash -c \"LOG_TIMESTAMP=\\\$(date +%Y%m%d_%H%M%S); python -m vllm.entrypoints.openai.api_server --model /model/Qwen3-235B-A22B --port 30000 --max-model-len 32000 -tp 4 --max-num-seqs 32 --served-model-name /model/Qwen3-235B --enable-auto-tool-choice --tool-call-parser hermes > /aipublic/logs/Qwen3-235B/server_log_\\\${LOG_TIMESTAMP}.log 2>&1\"
MONITOR_LOG=/aipublic/logs/Qwen3-235B/monitor.log
"

#模型2配置
MODELS["Qwen3-Rerank"]="
CONTAINER_NAME=Qwen3-Rerank
HEALTH_CHECK_URL=http://localhost:30009/health
CHECK_INTERVAL=10
RESTART_DELAY=180
MAX_RETRIES=3
RUN_COMMAND=docker run -itd -v /aipublic/model:/model -v /aipublic:/aipublic --name Qwen3-Rerank --privileged=True --gpus all --shm-size=16g --ipc=host -p 30009:30009 --ulimit memlock=-1 --restart=always -e CUDA_VISIBLE_DEVICES=3 vllm:0.10.1 bash -c \"LOG_TIMESTAMP=\\\$(date +%Y%m%d_%H%M%S); python -m vllm.entrypoints.openai.api_server --model /model/Qwen3-Reranker-8B --port 30009 --gpu-memory-utilization 0.4 -tp 1 --max-num-seqs 32 --hf_overrides '{"architectures": ["Qwen3ForSequenceClassification"],"classifier_from_token": ["no", "yes"],"is_original_qwen3_reranker": true}' --served-model-name /model/Qwen3-Rerank > /aipublic/logs/Qwen3-Rerank/log_\\\${LOG_TIMESTAMP}.log 2>&1\"
MONITOR_LOG=/aipublic/logs/Qwen3-Rerank/monitor.log
"
#模型3配置
MODELS["Qwen3-Embedding"]="
CONTAINER_NAME=Qwen3-Embedding
HEALTH_CHECK_URL=http://localhost:30002/health
CHECK_INTERVAL=10
RESTART_DELAY=180
MAX_RETRIES=3
RUN_COMMAND=docker run -itd -v /aipublic/model:/model -v /aipublic:/aipublic --name Qwen3-Embedding --privileged=True --gpus all --shm-size=16g --ipc=host -p 30002:30002 --ulimit memlock=-1 --restart=always -e CUDA_VISIBLE_DEVICES=3 vllm:0.10.1 bash -c \"LOG_TIMESTAMP=\\\$(date +%Y%m%d_%H%M%S); python -m vllm.entrypoints.openai.api_server --model /model/Qwen3-Embedding-8B --port 30002 --gpu-memory-utilization 0.4 -tp 1 --max-num-seqs 32 --served-model-name /model/Qwen3-Embedding > /aipublic/logs/Qwen3-Embedding/log_\\\${LOG_TIMESTAMP}.log 2>&1\"
MONITOR_LOG=/aipublic/logs/Qwen3-Embedding/monitor.log
"

# 创建日志目录
for model in "${!MODELS[@]}"; do
    # 解析配置
    IFS=$'\n' read -d '' -r -a config_lines <<< "${MODELS[$model]}"
    declare -A config
    for line in "${config_lines[@]}"; do
        if [[ -n "$line" ]]; then
            key=$(echo "$line" | cut -d'=' -f1)
            value=$(echo "$line" | cut -d'=' -f2-)
            config["$key"]="$value"
        fi
    done
    
    # 创建日志目录
    log_dir=$(dirname "${config[MONITOR_LOG]}")
    mkdir -p "$log_dir"
done

# 检查容器是否存在
container_exists() {
    local container_name=$1
    docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"
}

# 检查容器是否正在运行
container_running() {
    local container_name=$1
    docker ps --format "{{.Names}}" | grep -q "^${container_name}$"
}

# 监控函数
monitor_model() {
    local model_name=$1
    local config_str=$2
    
    # 解析配置
    IFS=$'\n' read -d '' -r -a config_lines <<< "$config_str"
    declare -A config
    for line in "${config_lines[@]}"; do
        if [[ -n "$line" ]]; then
            key=$(echo "$line" | cut -d'=' -f1)
            value=$(echo "$line" | cut -d'=' -f2-)
            config["$key"]="$value"
        fi
    done
    
    # 设置变量
    local CONTAINER_NAME="${config[CONTAINER_NAME]}"
    local HEALTH_CHECK_URL="${config[HEALTH_CHECK_URL]}"
    local CHECK_INTERVAL="${config[CHECK_INTERVAL]}"
    local RESTART_DELAY="${config[RESTART_DELAY]}"
    local MAX_RETRIES="${config[MAX_RETRIES]}"
    local RUN_COMMAND="${config[RUN_COMMAND]}"
    local MONITOR_LOG="${config[MONITOR_LOG]}"
    
    # 初始化计数器
    local failure_count=0
    
    # 写入监控日志头
    echo "==========================================" >> "$MONITOR_LOG"
    echo "模型监控启动时间: $(date +'%Y-%m-%d %H:%M:%S')" >> "$MONITOR_LOG"
    echo "监控模型: $model_name" >> "$MONITOR_LOG"
    echo "容器名称: $CONTAINER_NAME" >> "$MONITOR_LOG"
    echo "健康检查接口: $HEALTH_CHECK_URL" >> "$MONITOR_LOG"
    echo "检查间隔: $CHECK_INTERVAL 秒" >> "$MONITOR_LOG"
    echo "重启后等待时间: $RESTART_DELAY 秒" >> "$MONITOR_LOG"
    echo "最大重试次数: $MAX_RETRIES" >> "$MONITOR_LOG"
    echo "==========================================" >> "$MONITOR_LOG"
    
    # 初始检查：如果容器不存在，则创建
    if ! container_exists "$CONTAINER_NAME"; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器不存在，创建容器..." >> "$MONITOR_LOG"
        eval "$RUN_COMMAND" >> "$MONITOR_LOG" 2>&1
        echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器创建完成，等待 $RESTART_DELAY 秒让模型加载..." >> "$MONITOR_LOG"
        sleep "$RESTART_DELAY"
    fi
    
    while true; do
        # 发送健康检查请求
        response=$(curl -s -w "%{http_code}" -o /dev/null --connect-timeout 3 "$HEALTH_CHECK_URL")
        
        # 检查响应状态码，200表示正常
        if [ "$response" -eq 200 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - 模型健康检查正常" >> "$MONITOR_LOG"
            failure_count=0  # 重置失败计数器
        else
            failure_count=$((failure_count + 1))
            echo "$(date +'%Y-%m-%d %H:%M:%S') - 模型健康检查失败 ($failure_count/$MAX_RETRIES)，响应码: $response" >> "$MONITOR_LOG"
            
            # 达到最大失败次数，重启容器
            if [ $failure_count -ge $MAX_RETRIES ]; then
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 连续失败达到阈值，准备处理容器..." >> "$MONITOR_LOG"
                
                # 检查容器是否存在
                if container_exists "$CONTAINER_NAME"; then
                    # 检查容器是否正在运行
                    if container_running "$CONTAINER_NAME"; then
                        echo "$(date +'%Y-%m-%d %H:%M:%S') - 重启容器..." >> "$MONITOR_LOG"
                        docker restart "$CONTAINER_NAME" >> "$MONITOR_LOG" 2>&1
                    else
                        echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器已停止，启动容器..." >> "$MONITOR_LOG"
                        docker start "$CONTAINER_NAME" >> "$MONITOR_LOG" 2>&1
                    fi
                else
                    # 如果容器不存在，则重新创建
                    echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器不存在，重新创建..." >> "$MONITOR_LOG"
                    eval "$RUN_COMMAND" >> "$MONITOR_LOG" 2>&1
                fi
                
                # 等待模型加载完成
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器处理完成，等待 $RESTART_DELAY 秒让模型加载..." >> "$MONITOR_LOG"
                sleep "$RESTART_DELAY"
                
                # 重置失败计数器
                failure_count=0
            fi
        fi
        
        # 等待下一次检查
        sleep "$CHECK_INTERVAL"
    done
}

# 为每个模型启动监控进程
for model in "${!MODELS[@]}"; do
    echo "启动监控进程 for $model..."
    monitor_model "$model" "${MODELS[$model]}" &
    # 记录PID，以便后续管理
    echo $! > "/tmp/${model}_monitor.pid"
done

echo "所有模型监控进程已启动。"
echo "使用 'pkill -f monitor_models.sh' 停止所有监控进程。"

# 等待所有后台进程
wait