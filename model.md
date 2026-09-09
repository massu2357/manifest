## Model

- Qwen/Qwen3-30B-A3B-GPTQ-Int4

```
# envs/gptq-moe-test.env
VLLM_IMAGE=vllm-ray:26.05

MN_IF_NAME=enp1s0f1np1
HF_CACHE=/home/nvidia/.cache/huggingface
RAY_NUM_NODES=2

MODEL=<小さめの qwen3_moe GPTQ-Int4 リポジトリ>
TP_SIZE=2
MAX_MODEL_LEN=8192
GPU_MEM_UTIL=0.60
EXTRA_VLLM_ARGS=--max-num-seqs 4

NCCL_DEBUG=WARN
RAY_MEMORY_MONITOR_REFRESH_MS=0
HF_HUB_OFFLINE=0
TRANSFORMERS_OFFLINE=0
VLLM_NO_USAGE_STATS=1
DO_NOT_TRACK=1
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=localhost,127.0.0.1,192.168.100.10,192.168.100.11
```
```
docker compose --env-file envs/gptq-moe-test.env logs | grep -iE "marlin|gptq|quantization"
```

- Qwen/Qwen3-235B-A22B-GPTQ-Int4

```
# envs/qwen3-235b.env
VLLM_IMAGE=vllm-ray:26.05

MN_IF_NAME=enp1s0f1np1
HF_CACHE=/home/nvidia/.cache/huggingface
RAY_NUM_NODES=2

MODEL=Qwen/Qwen3-235B-A22B-GPTQ-Int4
TP_SIZE=2
MAX_MODEL_LEN=32768
GPU_MEM_UTIL=0.70
EXTRA_VLLM_ARGS=--max-num-seqs 8 --reasoning-parser qwen3 --enable-chunked-prefill

NCCL_DEBUG=WARN
RAY_MEMORY_MONITOR_REFRESH_MS=0
HF_HUB_OFFLINE=0
TRANSFORMERS_OFFLINE=0
VLLM_NO_USAGE_STATS=1
DO_NOT_TRACK=1
HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=localhost,127.0.0.1,192.168.100.10,192.168.100.11
```
```
curl --noproxy '*' http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-235B-A22B-GPTQ-Int4",
    "messages": [{"role":"user","content":"日本の首都は？"}],
    "max_tokens": 512,
    "temperature": 0.6,
    "top_p": 0.95
  }'
```

- RedHatAI/GLM-5.3-Flash-NVFP4
- nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8
