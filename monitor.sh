#!/bin/bash

# 配置多个模型参数
declare -A MODELS

# 模型1配置
MODELS["Qwen3-235B"]="
CONTAINER_NAME=Qwen3-235B
HEALTH_CHECK_URL=http://localhost:30000/health
CHECK_INTERVAL=30
RESTART_DELAY=200
MAX_RETRIES=3
RUN_COMMAND=docker run -itd -v /aipublic/model:/model -v /aipublic:/aipublic --name Qwen3-235B --privileged=True --gpus all --shm-size=16g --ipc=host -p 30000:30000 --ulimit memlock=-1 --restart=always -e CUDA_VISIBLE_DEVICES=4,5,6,7 vllm:0.10.1 bash -c \"LOG_TIMESTAMP=\\\$(date +%Y%m%d_%H%M%S); python -m vllm.entrypoints.openai.api_server --model /model/Qwen3-235B-A22B --port 30000 --max-model-len 32000 -tp 4 --max-num-seqs 32 --served-model-name /model/Qwen3-235B --enable-auto-tool-choice --tool-call-parser hermes > /aipublic/logs/Qwen3-235B/server_log_\\\${LOG_TIMESTAMP}.log 2>&1\"
MONITOR_LOG=/aipublic/logs/Qwen3-235B/monitor.log
"

# 模型2配置示例 - 可以根据需要添加更多模型
# MODELS["Another-Model"]="
# CONTAINER_NAME=Another-Model
# HEALTH_CHECK_URL=http://localhost:30001/health
# CHECK_INTERVAL=30
# RESTART_DELAY=180
# MAX_RETRIES=3
# RUN_COMMAND=docker run -itd -v /aipublic/model:/model -v /aipublic:/aipublic --name Another-Model --privileged=True --gpus all --shm-size=16g --ipc=host -p 30001:30000 --ulimit memlock=-1 --restart=always -e CUDA_VISIBLE_DEVICES=0,1,2,3 vllm:0.10.1 bash -c \"LOG_TIMESTAMP=\\\$(date +%Y%m%d_%H%M%S); python -m vllm.entrypoints.openai.api_server --model /model/Another-Model --port 30000 --max-model-len 16000 -tp 2 --max-num-seqs 16 --served-model-name /model/Another-Model > /aipublic/logs/Another-Model/log_\\\${LOG_TIMESTAMP}.log 2>&1\"
# MONITOR_LOG=/aipublic/logs/Another-Model/monitor.log
# "

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
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 连续失败达到阈值，准备重启容器..." >> "$MONITOR_LOG"
                
                # 检查容器是否存在且运行中
                if docker ps -q --filter "name=$CONTAINER_NAME" > /dev/null; then
                    echo "$(date +'%Y-%m-%d %H:%M:%S') - 重启容器..." >> "$MONITOR_LOG"
                    docker restart "$CONTAINER_NAME" >> "$MONITOR_LOG" 2>&1
                else
                    # 如果容器不存在，则重新创建
                    echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器不存在，重新创建..." >> "$MONITOR_LOG"
                    # 清理可能存在的旧容器（已停止的）
                    if docker ps -aq --filter "name=$CONTAINER_NAME" > /dev/null; then
                        docker rm "$CONTAINER_NAME" >> "$MONITOR_LOG" 2>&1
                    fi
                    # 启动新容器
                    eval "$RUN_COMMAND" >> "$MONITOR_LOG" 2>&1
                fi
                
                # 等待模型加载完成
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器重启完成，等待 $RESTART_DELAY 秒让模型加载..." >> "$MONITOR_LOG"
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