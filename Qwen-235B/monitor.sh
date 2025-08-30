#!/bin/bash

# 配置参数
CONTAINER_NAME="Qwen3-235B"  # 容器名称
HEALTH_CHECK_URL="http://localhost:30000/health"  # 健康检查接口
CHECK_INTERVAL=30  # 检查间隔(秒)
RESTART_DELAY=200  # 重启后等待时间(秒)，确保模型加载完成
MAX_RETRIES=3  # 连续失败多少次后重启
RUN_COMMAND="docker run -itd \
-v /aipublic/model:/model \
-v /aipublic:/aipublic \
--name ${CONTAINER_NAME} \
--privileged=True \
--gpus all \
--shm-size=16g \
--ipc=host -p 30000:30000 \
--ulimit memlock=-1 \
--restart=always \
-e CUDA_VISIBLE_DEVICES=4,5,6,7 \
vllm:0.10.1 \
bash -c \"LOG_TIMESTAMP=\$(date +%Y%m%d_%H%M%S); \
python -m vllm.entrypoints.openai.api_server \
--model /model/Qwen3-235B-A22B \
--port 30000 \
--max-model-len 32000 \
-tp 4 \
--max-num-seqs 32 \
--served-model-name /model/Qwen3-235B \
--enable-auto-tool-choice \
--tool-call-parser hermes > /aipublic/logs/Qwen3-235B/log_\${LOG_TIMESTAMP}.log 2>&1\""  # 启动容器时执行的命令

# 初始化计数器
failure_count=0

echo "模型健康监控脚本启动..."
echo "监控容器: $CONTAINER_NAME"
echo "健康检查接口: $HEALTH_CHECK_URL"
echo "检查间隔: $CHECK_INTERVAL 秒"
echo "重启后等待时间: $RESTART_DELAY 秒"

while true; do
    # 发送健康检查请求
    # 使用curl检查接口，允许3秒超时，只检查HTTP状态码
    response=$(curl -s -w "%{http_code}" -o /dev/null --connect-timeout 3 "$HEALTH_CHECK_URL")
    
    # 检查响应状态码，200表示正常
    if [ "$response" -eq 200 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - 模型健康检查正常"
        failure_count=0  # 重置失败计数器
    else
        failure_count=$((failure_count + 1))
        echo "$(date +'%Y-%m-%d %H:%M:%S') - 模型健康检查失败 ($failure_count/$MAX_RETRIES)，响应码: $response"
        
        # 达到最大失败次数，重启容器
        if [ $failure_count -ge $MAX_RETRIES ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - 连续失败达到阈值，准备重启容器..."
            
            # 检查容器是否存在且运行中
            if docker ps -q --filter "name=$CONTAINER_NAME" > /dev/null; then
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 重启容器..."
                docker restart $CONTAINER_NAME > /dev/null
            else
                # 如果容器不存在，则重新创建
                echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器不存在，重新创建..."
                # 清理可能存在的旧容器（已停止的）
                if docker ps -aq --filter "name=$CONTAINER_NAME" > /dev/null; then
                    docker rm $CONTAINER_NAME > /dev/null
                fi
                # 启动新容器
                eval $RUN_COMMAND
            fi
            
            # 等待模型加载完成
            echo "$(date +'%Y-%m-%d %H:%M:%S') - 容器重启完成，等待 $RESTART_DELAY 秒让模型加载..."
            sleep $RESTART_DELAY
            
            # 重置失败计数器
            failure_count=0
        fi
    fi
    
    # 等待下一次检查
    sleep $CHECK_INTERVAL
done