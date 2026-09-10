# DGX Spark 2ノード vLLM 分散推論

NVIDIA公式プレイブック（`run_cluster.sh` + Ray）で動作確認した構成を、
docker compose による常駐運用へ移行するための資材である。

同時に1つの大きなモデルを載せる運用を前提とし、
**ノード固有設定とモデル固有設定を2軸に分離**している。

---

## 1. 設計方針

| 軸 | ファイル | 変更頻度 |
|---|---|---|
| ノード固有 | `node.env` | 一度書いたら不変 |
| モデル固有 | `models/*.env` | モデルを変えるたび |
| 構造 | `docker-compose.yml` / `entrypoint.sh` | 触らない |

`--env-file` は複数指定でき、**後勝ちでマージ**される。
`GPU_MEM_UTIL` のような値は `node.env` に既定を置き、
特定モデルだけ変えたい場合は `models/*.env` に書けば上書きされる。

---

## 2. 公式手順との差分

| 項目 | 公式プレイブック | 本資材 |
|---|---|---|
| Ray の導入 | `run_cluster.sh` を sed でパッチし、起動のたびに `pip install` | イメージに焼き込み（`Dockerfile`） |
| プロセスの常駐 | ターミナルを開いたまま維持 | `restart: unless-stopped` |
| サーバ起動 | `docker exec` で別途実行 | entrypoint に統合 |
| 分散通信の環境変数 | `-e` で7個指定 | `MN_IF_NAME` 1つから展開 |
| RDMA | 指定なし（TCP経路） | 同左（任意で有効化可能） |

分散通信の設定値は公式と同一である。変えたのは「どう起動するか」だけである。

---

## 3. ファイル構成

```
spark-vllm/
├── Dockerfile              # Ray入りイメージのビルド定義
├── ca/                     # 社内CA置き場（不要なら空のまま）
├── docker-compose.yml      # 両ノード共通
├── entrypoint.sh           # 両ノード共通（ロールで分岐）
├── node.env.example        # → 各ノードで node.env にコピー
└── models/
    ├── qwen3-8b-smoke.env  # 経路確認用
    ├── qwen3-235b.env      # 動作確認済み
    ├── nemotron-super.env  # 未検証
    └── glm53-flash.env     # 実験用
```

---

## 4. 前提条件

| 項目 | 確認方法 |
|---|---|
| QSFPのIPが手動設定（netplan）で永続化されている | `ip addr show enp1s0f1np1` |
| 両ノード間の疎通がとれる | `ping -c3 <相手IP>` |
| モデルが**両ノードに**ダウンロード済み | `du -sh ~/.cache/huggingface/hub/models--*` |

`~/.cache/huggingface` は各ノードのローカルディスクであり共有されない。
head 側にしか無い状態では worker が重みを読めずに起動に失敗する。

---

## 5. 事前に採取する値

両ノードで実行して控えておく。

```bash
# QSFP のインターフェース名と IP
ip -br addr

# デバイス名との対応、(Up) 側を確認
ibdev2netdev

# RDMA デバイスの有無
ls /dev/infiniband

# HFキャッシュの実パスと空き容量
du -sh ~/.cache/huggingface
df -h  ~/.cache/huggingface
```

各物理ポートには論理インターフェースが2つ存在する（`enp1s0f1np1` と
`enP2p1s0f1np1` は同じ物理ポートの別名）。取り違えると NCCL が
通信経路を見つけられないため、`(Up)` 側を選ぶこと。

---

## 6. イメージのビルド

**両ノードで実行**する。または片方でビルドし、`docker save` / `docker load` で
もう一方へ持ち込む（エアギャップ環境ではこちら）。

```bash
cd ~/spark-vllm
mkdir -p ca

# 社内CAがある場合のみ
# cp /usr/local/share/ca-certificates/<社内CA>.crt ca/

docker build \
  --build-arg HTTP_PROXY="$HTTP_PROXY" \
  --build-arg HTTPS_PROXY="$HTTPS_PROXY" \
  -t vllm-ray:26.05 .
```

ビルド末尾で `ray, version 2.x.x` が表示されれば成功である。

持ち込む場合:

```bash
docker save vllm-ray:26.05 | gzip > vllm-ray.tar.gz
gunzip -c vllm-ray.tar.gz | docker load
```

---

## 7. 配置

```bash
cd ~/spark-vllm
chmod +x entrypoint.sh

cp node.env.example node.env
vi node.env       # NODE_ROLE と VLLM_HOST_IP をノードに合わせる

# 使うモデルを current.env として指す
ln -sfn models/qwen3-235b.env current.env
```

`node.env` で書き換えるのは実質この4つである。

- `NODE_ROLE`（head / worker）
- `VLLM_HOST_IP`（自ノードの QSFP 側 IP）
- `MN_IF_NAME`（QSFP のインターフェース名）
- `HF_CACHE`（HFキャッシュのパス）

---

## 8. 起動

両ノードで同じコマンドを実行する。順序は問わない
（head が worker の参加を待つ設計にしてある）。

```bash
docker compose --env-file node.env --env-file current.env up -d
docker compose logs -f
```

head のログに以下が順に現れれば正常である。

```
[entrypoint] ray: ray, version 2.x.x
[entrypoint] role=head self=192.168.100.10 head=192.168.100.10
[entrypoint] starting ray head on 192.168.100.10:6379
[entrypoint] waiting for 2 ray nodes to join...
[entrypoint]   alive nodes: 1/2 (0s)
[entrypoint]   alive nodes: 2/2 (10s)
[entrypoint] ray cluster ready. launching vllm serve...
...
INFO:     Application startup complete.
```

`ray not found in image; installing from PyPI...` が出た場合は、
`node.env` の `VLLM_IMAGE` が素の NGC イメージのままである。

---

## 9. モデルの切り替え

**両ノードで**リンクを張り替えて再起動する。

```bash
ln -sfn models/nemotron-super.env current.env
docker compose --env-file node.env --env-file current.env up -d
```

compose が環境変数の変更を検知してコンテナを再作成する。
いま何が動いているかは `ls -l current.env` で分かる。

---

## 10. 動作確認

head ノードで実行する。プロキシ環境では `--noproxy '*'` が必須である。
これを付けないと、ローカルへのリクエストがプロキシに転送されて失敗する。

```bash
curl --noproxy '*' http://localhost:8000/v1/models

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

クラスタ状態:

```bash
docker exec vllm-node ray status
```

Ray ダッシュボード（head の 8265 番）は SSH トンネルで参照する。

```bash
ssh -L 8265:localhost:8265 nvidia@192.168.100.10
```

---

## 11. チューニング

安定して起動できたら、この順序で詰める。

1. `free -h` と起動ログで実使用量を確認
2. `--max-num-seqs` を 8 → 16 → 32 と上げる
3. 最後に `GPU_MEM_UTIL` を 0.75 へ

**`GPU_MEM_UTIL` を先に上げないこと。** 統合メモリ機では
これがシステムフリーズにつながる唯一のパラメータである。
他を詰めきってから最後に触る。

見るべき指標:

```bash
docker compose logs | grep -iE "KV cache|GPU blocks|Maximum concurrency"

curl --noproxy '*' http://localhost:8000/metrics \
  | grep -E "num_requests_waiting|gpu_cache_usage_perc|num_preemptions"
```

- `Maximum concurrency for N tokens per request` が **1.0 を下回る**と、
  フル長のリクエストが1件も入らない状態を意味する
- `gpu_cache_usage_perc` が常時 90% 超なら飽和
- `num_preemptions` が増え続けるなら `--max-num-seqs` が過大

KVキャッシュは**起動時に全量が事前確保される**。利用者が増えても
プロセスのメモリ使用量は増えないため、負荷によるフリーズは起きない。
プールが埋まった場合はキュー待ちとプリエンプトで吸収される。

---

## 12. RDMA (RoCE) の有効化（任意）

公式プレイブックは RDMA デバイスを指定していないため、既定の構成は
NCCL が TCP ソケットを使う経路で動作している。RDMA を使うと、
TP=2 で層ごとに発生する集約通信のレイテンシが下がる。

```bash
ls /dev/infiniband
docker compose logs | grep -E "NET/(IB|Socket)"
```

`/dev/infiniband` が存在する場合のみ、`docker-compose.yml` 末尾の
コメントアウト部分（`cap_add` / `ulimits` / `devices`）を有効化する。
存在しない環境で有効化すると、デバイスが見つからず起動に失敗する。

`NCCL_IB_GID_INDEX` は指定しないこと。現行の NCCL は既定値 `-1` で
RoCEv2 対応の GID を自動選択する。`ncclCommInitRank` エラーが出た
場合にのみ手動指定を検討する。

有効化後、ログが `NET/IB : Using [0]rocep1s0f1:1/RoCE` に変われば成功である。

---

## 13. モデル選定の指針

DGX Spark ではメモリ帯域が律速する。デコード速度はおおよそ次式で決まる。

```
生成速度 ≒ メモリ帯域 ÷ 1トークンあたりに読む重み
```

GB10 の帯域は約 273GB/s。TP=2 なら両ノードが並列に読むため実効は約 546GB/s。

したがって選定の要点は次の2つである。

- **総パラメータ** … メモリ消費を決める（`235B × 2バイト = 470GB` が BF16 の素の状態）
- **アクティブパラメータ** … 速度を決める

**総が大きくアクティブが小さい MoE** が最適である。
Dense の大型モデル（70B BF16 = 140GB で約 4 tok/s）は
メモリに載っても実用速度が出ない。

メモリ予算の目安:

| 項目 | 値 |
|---|---|
| 物理合計（2ノード） | 256GB |
| `GPU_MEM_UTIL 0.70` | 約 180GB |
| 重みに割り当てる上限 | 150〜160GB |
| KVキャッシュ・活性化 | 30〜40GB |

---

## 14. トラブルシュート

### `ray: command not found`

イメージに Ray が入っていない。`Dockerfile` でビルドしたイメージを
`node.env` の `VLLM_IMAGE` に指定しているか確認する。

### head が `alive nodes: 1/2` のまま進まない

worker が Ray に参加できていない。worker 側のログと疎通を確認する。
`HEAD_ADDR` の値と head 側の実IPが一致しているか。

### 起動時にハングして進まない

`GLOO_SOCKET_IFNAME` / `TP_SOCKET_IFNAME` が未設定だと、PyTorch 分散の
初期化が別のインターフェースを掴んでハングする。`MN_IF_NAME` を確認する。

### `not supported architecture`

モデル登録ではなくカーネル側のエラーである可能性が高い。
GB10 は SM121 であり、B200 系（SM100）向けのカーネルとは互換がない。

```bash
docker exec vllm-node python3 -c \
  "from vllm.model_executor.models.registry import ModelRegistry; \
   print(ModelRegistry.get_supported_archs())"

docker exec vllm-node python3 -c \
  "import torch; print(torch.cuda.get_device_capability())"
```

### システムごとフリーズした

`GPU_MEM_UTIL` が高すぎる。統合メモリ機では OS・Docker・Ray が
同じメモリを共有するため、`0.9` は OS に 10% しか残さない指定になる。
復帰後、`restart: unless-stopped` により同じ設定で再起動ループする
恐れがあるため、まず `docker compose down` してから値を下げる。
操作する余裕がない場合は `sudo systemctl stop docker`。

### OS再起動後に起動ループする

QSFPのIPが消えている可能性がある。netplan 設定の永続化を確認する。

```bash
sudo netplan get
ip addr show enp1s0f1np1
```

---

## 15. オフライン運用

モデルのダウンロードが済んだら `node.env` の以下を有効にする。

```bash
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
```

ローカルにモデルがあっても HuggingFace へ更新確認に行く動作が止まる。
`VLLM_NO_USAGE_STATS=1` と `DO_NOT_TRACK=1` は既定で有効。
`pull_policy: never` によりイメージの外部取得も防いでいる。

検証は、`node.env` のプロキシを空にして起動し、正常に
`Application startup complete.` まで到達するかで行う。

エアギャップ環境へ持ち込む場合、事前準備が必要なものは次の3つである。

- コンテナイメージ（`docker save` / `docker load`）
- モデルの重み（両ノードの `~/.cache/huggingface`）
- Ray（`Dockerfile` で焼き込み済み）

---

## 16. 次の段階（任意）

- **systemd 化**: ネットワーク設定 → compose 起動の依存順序を明示したい場合
- **unhealthy 時の自動復旧**: `restart: unless-stopped` はプロセス終了時にのみ
  再起動するため、unhealthy では自動復旧しない。autoheal コンテナ等が必要
- **Kubernetes + LeaderWorkerSet**: 3ノード以上、または基盤として展開する場合
- **1台1モデル構成**: 複数モデルを同時提供したい場合は Ray をやめ、
  各ノードで `TP_SIZE=1` として LiteLLM 等で前段ルーティングする

2台の固定構成であれば、本手順（compose + netplan による永続IP +
Ray入りイメージ）で運用要件は満たせる。
