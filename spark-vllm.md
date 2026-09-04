調査結果をまとめます。ご質問は「**① 導入にあたり必要なこと（事前準備）**」「**② プロキシの通信先リスト**」「**③ 事前に必要なソフトウェア**」の3点として整理しました。

---

## 📍 前提：見るべきタブが違います

いただいたURLのトップ（Overview / Instructions）は**1台構成**の手順です。2台クラスタでの推論は **Multi-node serving タブ** の「A. Two nodes (direct QSFP cable)」が本体になります。Ray クラスタとテンソル並列（TP=2）でGPUをプールする構成です。

使うコンテナイメージも異なります ⚠️

| | 1台構成 | **2台構成（今回）** |
|---|---|---|
| イメージ | `vllm/vllm-openai:latest`（Docker Hub） | `nvcr.io/nvidia/vllm:26.05-py3`（**NGC**） |
| 通信先 | Docker Hub | NGC (nvcr.io) |

> 💡 **テンソル並列（Tensor Parallel / TP）**＝1つのモデルの重み行列を複数GPUに分割して同時計算する手法。2台で1モデルを持つのでノード間通信が常時発生します。

---

## ③ 事前に必要なソフトウェア

プレイブックが挙げる必須要件は、Docker、NVIDIA Container Toolkit、HuggingFaceアカウントとアクセストークン、NGCとHuggingFaceへのネットワーク到達性です。実際に手を動かす順で並べると：

| # | 項目 | 内容 |
|---|---|---|
| 1 | **Docker** | 両ノード。`sudo usermod -aG docker $USER` でsudo不要に |
| 2 | **NVIDIA Container Toolkit** | `nvidia-ctk runtime configure --runtime=docker` 済みであること |
| 3 | **QSFP接続＋パスワードなしSSH** | 「Connect Two Sparks」プレイブック相当。**構築済みとのことなので流用可** |
| 4 | `~/.ssh` ディレクトリ | 存在しないとスクリプトが失敗するため、両ノードで `mkdir -p ~/.ssh && chmod 700 ~/.ssh` |
| 5 | **tmux / screen** | 必須級。`run_cluster.sh` はEXITトラップでコンテナを停止するため、SSHが切れるとクラスタが崩壊します |
| 6 | wget / curl | スクリプト取得とAPIテスト用 |
| 7 | **NGCアカウント＋APIキー** | `docker login nvcr.io`（ユーザー名は文字列 `$oauthtoken`）。公開イメージでも403になる事例があるので取得推奨 |
| 8 | **HFトークン** | サンプルの Llama 3.3 70B はゲート付きモデルで、HFサイトでのライセンス同意とread権限トークンが必要 |

---

## ② プロキシ通信先リスト 🌐

⚠️ **重要な前置き**：NVIDIAは DGX Spark の公式許可ドメイン一覧を公開していません（開発者フォーラムに同じ質問が出ていますが、2026年8月時点で未回答のままです）。以下は**プレイブックの各コマンドが実際に叩く先**から導出したものです。

### A. 必須（すべてTCP/443）

| 用途 | ドメイン |
|---|---|
| 🐳 NGCコンテナ取得 | `nvcr.io` |
| 🔑 NGC認証・API | `authn.nvidia.com` / `api.ngc.nvidia.com` |
| 📜 run_cluster.sh 取得 | `raw.githubusercontent.com`（＋`github.com`） |
| 🐍 pip（後述） | `pypi.org` / `files.pythonhosted.org` |
| 🤗 HF Hub API | `huggingface.co` / `hf.co` |

> **なぜpipが必要？** 2台構成の手順では `run_cluster.sh` を `sed` で書き換え、コンテナ起動時に `pip install ray[default]>=2.9` を実行してからRayを起動するためです。コンテナ内からPyPIへ出られないとクラスタが上がりません。

### B. HuggingFace のモデル実体（ここが最大の落とし穴）

HFはモデル本体をAPIとは別ドメインから配信します。`huggingface.co` だけ許可してダウンロードが固まる、が定番の事故です。

HF公式の `.well-known/meta.json` に記載の現行ドメイン：

| 区分 | ドメイン |
|---|---|
| **LFS / Xet転送** | `cdn-lfs.hf.co`, `cdn-lfs-us-1.hf.co`, `cdn-lfs-eu-1.hf.co`, `transfer.xethub.hf.co` |
| **Xet補助** | `cas-server.xethub.hf.co`, `cas-bridge.xethub.hf.co` |
| **CDN** | `us.aws.cdn.hf.co`, `us-east-1.aws.cdn.hf.co`, `us-west-2.aws.cdn.hf.co`, `ap-southeast-1.aws.cdn.hf.co`, `us.gcp.cdn.hf.co` ほか |

HF公式は、可能であれば `hf.co` と `huggingface.co` のサフィックス（全サブドメイン）で許可することを推奨しています。エンドポイントが変わってもルールが壊れないためです。ただしプロキシが単一ラベルのワイルドカードしか扱えない場合、`*.hf.co` は `us.aws.cdn.hf.co` のような深い階層にマッチしない点に注意が必要です。

> 💡 **Xet（ゼット）**＝HFが従来のGit LFSから移行中の新ストレージ方式。リポジトリごとに新旧が混在するため、**両方のドメイン群を開ける必要があります**。

### C. 任意（状況に応じて）

- OS更新を通すなら：`archive.ubuntu.com` / `security.ubuntu.com` / `repo.download.nvidia.com` / `developer.download.nvidia.com`
- 1台構成も試すなら：`registry-1.docker.io` / `auth.docker.io` / `production.cloudflare.docker.com` / `docker-images-prod.s3.*.amazonaws.com`

---

## ① 導入前に必ず押さえる設定ポイント ⚠️

### 1. プロキシ設定は「3層」に入れる必要があります

ここを1箇所しか設定せずにハマるケースが非常に多いです。

| 層 | 設定場所 | 効くもの |
|---|---|---|
| ホストOS | `/etc/environment`, `~/.bashrc` | `wget`, `curl` |
| **Dockerデーモン** | `/etc/systemd/system/docker.service.d/http-proxy.conf` → `systemctl daemon-reload && systemctl restart docker` | **`docker pull`** |
| **コンテナ内** | `run_cluster.sh` に `-e HTTP_PROXY=... -e HTTPS_PROXY=... -e NO_PROXY=...` を追加 | **HFダウンロード、pip** |

### 2. `NO_PROXY` の設定漏れ = クラスタが組めない 🔴

2台間の Ray / NCCL / GLOO 通信がプロキシに吸われると確実に失敗します。以下を必ず除外してください。

```
NO_PROXY=localhost,127.0.0.1,<Node1のQSFP IP>,<Node2のQSFP IP>,<両ノードの管理LAN IP>,.local
```

大文字（`NO_PROXY`）と小文字（`no_proxy`）の**両方**を設定するのが安全です（参照する変数がツールによって異なるため）。

### 3. SSLインスペクション（MITM）の有無を確認 🔴

社内プロキシが証明書を差し替える構成の場合、コンテナ内のPythonが証明書検証で落ちます。その場合は社内CA証明書をコンテナにマウントし、以下を指定します。

```
-e REQUESTS_CA_BUNDLE=/path/to/ca.pem
-e SSL_CERT_FILE=/path/to/ca.pem
-e CURL_CA_BUNDLE=/path/to/ca.pem
```

### 4. ノード間ポート（プロキシではなくホストFW側）

`run_cluster.sh` はホストネットワークで動きます。ufw等が有効なら、QSFPインターフェース側は原則フルオープンにしてください。主要なものは Ray GCS **6379**、Rayダッシュボード **8265**、vLLM API **8000**、加えてRayワーカーとNCCLが動的ポートを使います。

---

## 🎯 進め方の提案

プロキシ環境では、**まず1台単体（Instructionsタブ・小さめのモデル）で通信経路を確定させてから**、2台のRayクラスタに進むことを強くおすすめします。1台構成なら失敗要因が「NGC取得」と「HF取得」の2つに絞れるため、切り分けが圧倒的に楽です。

もう1点、モデル選定について。手順書のサンプルは Llama 3.3 70B ですが、BF16だと約140GBのダウンロードが発生します。プロキシ経由での初回取得はかなり時間がかかるので、recipes.vllm.ai の DGX Spark 向けレシピから量子化版（FP8 / NVFP4）を選ぶ方が現実的です。

必要であれば、上記を反映した **プロキシ対応版の `run_cluster.sh` 起動コマンド一式**を書き起こしますが、いかがしましょうか。

## ご質問への回答：はい、そのドキュメントで合っています ✅

ただし2つは**役割が違う**ので、そこだけ整理させてください。

| URL | 内容 | vLLMマルチノードとの関係 |
|---|---|---|
| **connect-two-sparks** /stacked-sparks | QSFPケーブル接続、netplanでのIP設定、パスワードなしSSH | ✅ **これが前提条件そのもの**。vLLM の Multi-node タブ Step 1 が参照しているのがこのページです |
| **nccl** /stacked-sparks | ホスト上でNCCL v2.30.7-1 をソースビルド → `all_gather_perf` で帯域測定 | ⚪ **vLLMには必須ではありません** |

### なぜNCCLは必須でないのか

vLLMコンテナ（`nvcr.io/nvidia/vllm:26.05-py3`）は**自前のNCCLを同梱**しているため、ホストの `~/nccl/build` はコンテナ内から参照されません。あのプレイブックは「配線と200GbEの帯域が正しく出ることの検証」という位置づけです。

とはいえ実施済みであれば、**QSFP経路の疎通と実効帯域が保証されている**状態なので、トラブル時の切り分けが非常に楽になります。大きなアドバンテージです。

### ⚠️ 1点だけ注意：使うインターフェースが違います

NCCLプレイブックは `NCCL_SOCKET_IFNAME=enP7s7`（**管理LAN側**）を指定していましたが、vLLM側は `MN_IF_NAME=enp1s0f1np1`（**QSFP側**）を使います。作業前にQSFP側のIPを控えてください。

```bash
# 両ノードで実行
ibdev2netdev                    # Up になっている I/F を確認
ip addr show enp1s0f1np1        # → 192.168.100.10 / .11 など
```

---

# 🚀 マルチノードvLLM 導入手順（プロキシ対応版）

## Step 0. プロキシ環境変数を決める

まずこれを両ノードで確定させます。ここが全ての土台です。

```bash
export PROXY="http://<proxy-host>:<port>"
export NODE1_IP=192.168.100.10   # ← 実際のQSFP IPに置換
export NODE2_IP=192.168.100.11   # ← 実際のQSFP IPに置換

export MY_NO_PROXY="localhost,127.0.0.1,${NODE1_IP},${NODE2_IP},.local,192.168.100.0/24"
```

> 🔴 **最重要**：`NO_PROXY` に両ノードのQSFP IPが入っていないと、Ray/NCCLの通信がプロキシに吸われてクラスタが組めません。ここだけは絶対に外さないでください。

## Step 1. Dockerデーモンにプロキシを設定（両ノード）

`docker pull` はデーモンが行うため、シェルの環境変数では効きません。

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=${MY_NO_PROXY}"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
docker info | grep -i proxy    # 反映確認
```

## Step 2. NGCログイン＋イメージ取得（両ノード）

```bash
docker login nvcr.io
# Username: $oauthtoken   ← 変数ではなく、この文字列そのもの
# Password: <NGC APIキー>

docker pull nvcr.io/nvidia/vllm:26.05-py3
export VLLM_IMAGE=nvcr.io/nvidia/vllm:26.05-py3
```

## Step 3. run_cluster.sh の取得とパッチ（両ノード）

```bash
export http_proxy=$PROXY https_proxy=$PROXY no_proxy=$MY_NO_PROXY

wget https://raw.githubusercontent.com/vllm-project/vllm/51c1ee9b7c8acbba4899a8ebffd390685d171946/examples/ray_serving/run_cluster.sh

sed -i 's|^RAY_START_CMD="ray start|RAY_START_CMD="pip install -q --root-user-action=ignore '\''ray[default]>=2.9'\'' \&\& ray start|' run_cluster.sh

chmod +x run_cluster.sh
```

> 💡 このsedは、**コンテナ起動時にPyPIから `ray[default]` を入れる**ようスクリプトを書き換えています。つまりコンテナ内からPyPIへ出られないとクラスタが上がりません。次のStepでプロキシを渡すのはこのためです。

## Step 4. Head node 起動（Node 1・tmux内で実行）

```bash
tmux new -s vllm-head

export MN_IF_NAME=enp1s0f1np1
export VLLM_HOST_IP=$(ip -4 addr show $MN_IF_NAME | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export VLLM_IMAGE=nvcr.io/nvidia/vllm:26.05-py3

bash run_cluster.sh $VLLM_IMAGE $VLLM_HOST_IP --head ~/.cache/huggingface \
  -e VLLM_HOST_IP=$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=$MN_IF_NAME \
  -e OMPI_MCA_btl_tcp_if_include=$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=$VLLM_HOST_IP \
  -e HTTP_PROXY=$PROXY -e HTTPS_PROXY=$PROXY -e NO_PROXY=$MY_NO_PROXY \
  -e http_proxy=$PROXY -e https_proxy=$PROXY -e no_proxy=$MY_NO_PROXY
```

**追加した最後の2行がプロキシ対応部分**です。ここが無いとStep 3のpipとStep 7のモデルDLが失敗します。

> ⚠️ tmux/screen必須です。`run_cluster.sh` はEXITトラップでコンテナを停止するため、SSHが切れるとクラスタごと落ちます。

## Step 5. Worker node 起動（Node 2・tmux内で実行）

```bash
tmux new -s vllm-worker

export MN_IF_NAME=enp1s0f1np1
export VLLM_HOST_IP=$(ip -4 addr show $MN_IF_NAME | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export HEAD_NODE_IP=192.168.100.10          # ← Node 1 のQSFP IP
export VLLM_IMAGE=nvcr.io/nvidia/vllm:26.05-py3

bash run_cluster.sh $VLLM_IMAGE $HEAD_NODE_IP --worker ~/.cache/huggingface \
  -e VLLM_HOST_IP=$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=$MN_IF_NAME \
  -e OMPI_MCA_btl_tcp_if_include=$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=$HEAD_NODE_IP \
  -e HTTP_PROXY=$PROXY -e HTTPS_PROXY=$PROXY -e NO_PROXY=$MY_NO_PROXY \
  -e http_proxy=$PROXY -e https_proxy=$PROXY -e no_proxy=$MY_NO_PROXY
```

## Step 6. クラスタ確認 ✅ ここが最初の関門

```bash
export VLLM_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^node-[0-9]+$')
docker exec $VLLM_CONTAINER ray status
```

**2ノード分のGPUリソースが見えればOK**です。ここまで通れば、プロキシ設定とノード間通信は正しく分離できています。

## Step 7. モデル取得

```bash
docker exec -it $VLLM_CONTAINER /bin/bash -c '
  hf auth login
  hf download <モデルハンドル>'
```

💡 プレイブックの例は `meta-llama/Llama-3.3-70B-Instruct`（HFでのライセンス同意が必要なゲートモデル）ですが、BF16で約140GBあります。プロキシ経由の初回DLは相当時間がかかるので、[recipes.vllm.ai の DGX Spark 向けレシピ](https://recipes.vllm.ai/browse?panel=open&hw=dgx_spark_gb10)から量子化版を選ぶ方が現実的です。

**もしDLが固まったら**：Xet転送がプロキシと相性が悪いケースがあります。`-e HF_HUB_DISABLE_XET=1` を足して従来のLFS経路に落とすと通ることがあります。

## Step 8. 推論サーバ起動

```bash
docker exec -it $VLLM_CONTAINER /bin/bash -c '
  vllm serve <モデルハンドル> \
    --tensor-parallel-size 2 \
    --max-model-len 2048 \
    --distributed-executor-backend ray'
```

`Application startup complete.` が出れば完了です。

## Step 9. 動作確認

```bash
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<モデルハンドル>","prompt":"Write a haiku about a GPU","max_tokens":32}'
```

---

## 🔍 詰まりやすい箇所（優先度順）

1. **Step 6でノードが1つしか見えない** → `NO_PROXY` にQSFP IPが入っているか確認
2. **Step 3のpipが失敗** → Step 4/5の `-e http_proxy`（小文字）が抜けている
3. **SSL証明書エラー** → プロキシがSSLインスペクションしている場合、社内CA証明書をコンテナにマウントし `-e REQUESTS_CA_BUNDLE=/path/ca.pem -e SSL_CERT_FILE=/path/ca.pem` を追加
4. **メモリ逼迫** → UMAのバッファキャッシュを解放：`sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'`

---

上記をそのまま実行できる形の**手順書（Markdown）**としてファイル出力もできます。実機で見ながら進めるなら、そちらの方が使いやすいかもしれません。必要でしたらお申し付けください。
