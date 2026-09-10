#!/bin/bash
# DGX Spark 2ノード vLLM: ロール別エントリポイント
set -euo pipefail

log() { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

# ------------------------------------------------------------------
# Ray の確認
# Dockerfile で焼き込んでいれば何もしない。
# 素の NGC イメージを使っている場合のみ、その場で導入する
# （公式プレイブックが run_cluster.sh に sed で挿し込んでいた処理と同等）。
# この経路は PyPI への通信が必要なため、オフライン運用では使えない。
# ------------------------------------------------------------------
if ! command -v ray >/dev/null 2>&1; then
  log "ray not found in image; installing from PyPI..."
  pip install -q --root-user-action=ignore 'ray[default]>=2.9'
fi

log "ray: $(ray --version 2>&1 | head -1)"
log "role=${NODE_ROLE} self=${VLLM_HOST_IP} head=${HEAD_ADDR}"
log "net: if=${NCCL_SOCKET_IFNAME} master=${MASTER_ADDR}"

# コンテナ再起動時に前回の Ray 状態が残っていることがあるため掃除する
ray stop --force >/dev/null 2>&1 || true

# ---------------- worker ----------------
if [ "${NODE_ROLE}" = "worker" ]; then
  log "starting ray worker -> ${HEAD_ADDR}:6379"
  exec ray start --block \
    --address="${HEAD_ADDR}:6379" \
    --node-ip-address="${VLLM_HOST_IP}"
fi

# ---------------- head ----------------
log "starting ray head on ${VLLM_HOST_IP}:6379"
ray start --head --port=6379 --node-ip-address="${VLLM_HOST_IP}"

# worker が参加するまで待つ。これにより両ノードの起動順を気にしなくてよくなる
log "waiting for ${RAY_NUM_NODES} ray nodes to join..."
waited=0
while true; do
  alive=$(python3 -c \
    'import ray; ray.init(address="auto"); print(sum(1 for n in ray.nodes() if n["Alive"]))' \
    2>/dev/null || echo 0)
  log "  alive nodes: ${alive}/${RAY_NUM_NODES} (${waited}s)"
  [ "${alive}" -ge "${RAY_NUM_NODES}" ] && break
  sleep 5
  waited=$((waited + 5))
done
log "ray cluster ready. launching vllm serve..."
log "model=${MODEL} tp=${TP_SIZE} len=${MAX_MODEL_LEN} util=${GPU_MEM_UTIL}"

# EXTRA_VLLM_ARGS は意図的にクォートしない（複数引数として展開させる）
# そのため各値に空白を含めないこと（JSON を渡す場合は空白なしで書く）
# shellcheck disable=SC2086
exec vllm serve "${MODEL}" \
  --tensor-parallel-size "${TP_SIZE}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --gpu-memory-utilization "${GPU_MEM_UTIL}" \
  --distributed-executor-backend ray \
  --host 0.0.0.0 --port 8000 \
  ${EXTRA_VLLM_ARGS}
