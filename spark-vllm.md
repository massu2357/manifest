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

結論から言うと、**壊れません。完全に可逆です** ✅

---

### 🛡️ なぜ安全と言えるか

やることは実質2つだけです。

1. `/etc/netplan/40-cx7.yaml` を**新規作成**する
2. `sudo netplan apply` で反映する

**既存設定を書き換えるのではなく、ファイルを1枚足すだけ**です。公式にもロールバック手順（ファイル削除 → `netplan apply`）が明記されています。

そして重要な点として、**以下は一切影響を受けません**。

- 📦 HuggingFace のモデルキャッシュ（再ダウンロード不要）
- 🐳 Docker イメージ・コンテナ定義
- 🔌 QSFPの物理接続・インターフェース名
- 🔑 SSH の公開鍵（`authorized_keys` はIPではなくユーザ単位）

変わるのは **IPアドレスの値だけ**です。

---

### ⚠️ 移行前の確認3点

**① サブネットの衝突チェック（これが一番重要）**

公式サンプルは `192.168.100.0/24` と `192.168.101.0/24` を使います。社内LANやDockerブリッジがこの帯域と被っていると、**管理LAN側の通信が壊れます**。

```bash
ip route
docker network inspect bridge | grep Subnet
```

被っていたら `192.168.200.x` など空いている帯域に変えてください。設定値を変えるだけで手順は同じです。

**② 作業は管理LAN経由で**

QSFP経由でSSHしていると、`netplan apply` で自分の接続が切れます。Wi-Fi/有線LAN側、または物理コンソールから実施してください。

**③ 現状を控えておく**

```bash
ip addr show enp1s0f1np1
ip addr show enP2p1s0f1np1
ip link show enp1s0f1np1   # MTU も控えておくと安心
ls /etc/netplan/           # 既存ファイルの有無を確認
```

---

### 📋 移行手順

```bash
# 1. まず推論を止める（両ノード）
docker compose down        # または docker stop/rm でRayコンテナを削除

# 2. netplan 設定を作成（両ノード、IPだけ変える）
sudo tee /etc/netplan/40-cx7.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
      dhcp4: no
    enP2p1s0f1np1:
      addresses: [192.168.101.10/24]
      dhcp4: no
EOF
sudo chmod 600 /etc/netplan/40-cx7.yaml
sudo netplan apply

# 3. 疎通確認
ip addr show enp1s0f1np1
ping -c3 192.168.100.11      # 相手ノード

# 4. SSH再確認（ホスト鍵の受け入れが必要）
ssh 192.168.100.11 hostname
```

**Rayコンテナを先に止めるのが必須**です。Rayは起動時のIPにバインドし続けるため、IP変更後も生き残っていると中途半端な状態になります。作り直せば済みます。

---

### 🔧 移行後に更新するもの

| 対象 | 内容 |
|---|---|
| compose の `.env` | `VLLM_HOST_IP` / `HEAD_ADDR` / `NO_PROXY` |
| `~/.ssh/known_hosts` | 新IPのホスト鍵を受け入れ（`discover-sparks` 再実行でも可） |
| `/etc/hosts` | ノード名でIPを引いている場合 |

`NCCL_SOCKET_IFNAME` などのインターフェース名は**変わりません**ので、そのままで大丈夫です。

---

### 🚨 万一おかしくなったら

```bash
sudo rm /etc/netplan/40-cx7.yaml
sudo netplan apply
```

これで元の自動割り振り状態に戻ります。管理LANが生きていれば、リモートからでも復旧できます。

---

いま**動く状態がある**というのは検証上とても価値があるので、移行後は同じ405B（または8B）の疎通テストをもう一度通して、「IP以外は何も変わっていない」ことを確認してから compose 化に進むのが安全な順序です。

**新しいファイルを重ねるのではなく、既存ファイルを書き換えるのが正解です** 🎯

netplan は `/etc/netplan/*.yaml` を**全部読んでマージ**します（ファイル名の昇順で、後勝ち）。放置して `40-cx7.yaml` を足すと、両方の設定が混ざって挙動が読めなくなります。

---

### ⚠️ まず中身を確認してください

**DGX OS が最初から置いているファイルを消してはいけません。** 消すと管理LAN側の通信ごと落ちる可能性があります。

```bash
ls -la /etc/netplan/
sudo cat /etc/netplan/*.yaml
sudo netplan get            # マージ後の「実際に効いている設定」が見られる
```

判断基準はシンプルです。

| ファイル | 対応 |
|---|---|
| `01-network-manager-all.yaml` など、**CX-7以外**も含む標準ファイル | 🚫 触らない |
| ご自身が作った**CX-7専用**のファイル | ✏️ これを書き換える |

---

### ✏️ 書き換え手順

```bash
# 1. バックアップ（/etc/netplan の外へ退避）
sudo cp /etc/netplan/<既存ファイル>.yaml ~/netplan-backup.yaml.bak
```

> 💡 バックアップを `/etc/netplan/` 内に `.bak` で置くのはNGです。netplan は拡張子 `.yaml` 以外を読みませんが、紛らわしいので外に出すのが安全です。

```bash
# 2. 既存ファイルを静的IPに書き換え
sudo tee /etc/netplan/<既存ファイル>.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
      dhcp4: no
      link-local: []
    enP2p1s0f1np1:
      addresses: [192.168.101.10/24]
      dhcp4: no
      link-local: []
EOF

sudo chmod 600 /etc/netplan/<既存ファイル>.yaml
```

`link-local: []` を明示しているのがポイントです。これが無いと、**169.254.x.x のアドレスが残ったまま**静的IPが追加され、NCCLがどちらを掴むか不定になります。

---

### 🧪 適用は `netplan try` で

```bash
sudo netplan try
```

これは **120秒以内に Enter を押さないと自動的に元へ戻る**モードです。設定ミスでネットワークが切れても勝手に復旧するので、リモート作業では必ずこちらを使ってください。問題なければ Enter → 確定します。

確認できたら通常の適用に切り替えても構いません。

```bash
sudo netplan apply
ip addr show enp1s0f1np1     # 169.254.x.x が消えていること
```

---

### 🔧 もうひとつの注意：renderer を揃える

既存ファイルに `renderer: NetworkManager` の記述があれば、**書き換え後のファイルにも同じ行を残してください**。

netplan のデフォルト renderer は `networkd` なので、指定を消すと「NetworkManager と systemd-networkd が同じインターフェースを取り合う」状態になり、IPが付いたり消えたりします。これは原因が分かりにくい厄介な不具合です。

```yaml
network:
  version: 2
  renderer: NetworkManager      # ← 既存にあったら維持する
  ethernets:
    ...
```

---

### 📌 まとめ

1. `sudo netplan get` で現状把握
2. **CX-7用の自作ファイルだけ**を書き換え（新規追加しない）
3. `link-local: []` と `renderer` の扱いに注意
4. `netplan try` で安全に適用

まずは `ls /etc/netplan/` と `sudo netplan get` の結果を見せていただければ、どのファイルをどう直すか具体的に指定できます。

それなら話はずっと簡単です 👍 **同じファイルなので、公式の手順をそのまま実行すれば上書きされます。**

前回、私は「DGX OS標準のファイルを消さないよう注意」とお伝えしましたが、`40-cx7.yaml` は Massuさんご自身が作られたCX-7専用ファイルなので、その心配は不要でした。

---

### ✅ やること

公式 Step 3 の Option 1 のコマンドを**そのまま**流すだけです。

```bash
# バックアップだけ先に（/etc/netplan の外へ）
sudo cp /etc/netplan/40-cx7.yaml ~/40-cx7.yaml.bak

# 中身を確認（renderer 行の有無をチェック）
sudo cat /etc/netplan/40-cx7.yaml
```

`sudo tee /etc/netplan/40-cx7.yaml > /dev/null <<EOF ...` は**ファイルを丸ごと置き換える**ので、古い自動割り振りの設定は残りません。前回お伝えした「`link-local: []` を明示」も、上書きなら不要です。

> 💡 netplan の `link-local` のデフォルトは `[ipv6]` です。つまり**IPv4のリンクローカルは書かない限り付きません**。IPv6の `fe80::` が残るのは正常なので、気にしなくて大丈夫です。

---

### ⚠️ 1点だけ引き継ぐもの

古いファイルに `renderer: NetworkManager` の行があった場合は、**新しい内容にも残してください**。公式サンプルには含まれていないため、そのまま貼ると renderer が `networkd` に切り替わり、NetworkManager と競合する可能性があります。

```yaml
network:
  version: 2
  renderer: NetworkManager      # ← 元ファイルにあったら維持
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
      dhcp4: no
    enP2p1s0f1np1:
      addresses: [192.168.101.10/24]
      dhcp4: no
```

インターフェース名も、古いファイルの記載と一致しているか見比べておくと確実です。

---

### 🧪 適用

```bash
sudo netplan try      # 120秒で自動ロールバック。問題なければ Enter
ip addr show enp1s0f1np1
```

`169.254.x.x` が消えて `192.168.100.10` だけになっていれば成功です。

戻したくなったら、バックアップを書き戻して `sudo netplan apply` で元通りになります。

いい選択です 👍 2台の固定構成なら compose が一番バランスが取れます。一式を作りました。### 🔑 設計のポイント

**1. compose ファイルは両ノード共通、`.env` だけ変える**
差分は実質 `NODE_ROLE` と `VLLM_HOST_IP` の2つです。管理対象が減ります。

**2. `entrypoint.sh` が role で分岐**
- worker → `ray start --block` のみ
- head → `ray start --head` → **workerの参加を待つ** → `vllm serve` を `exec`

この「待つ」処理があるおかげで、**起動順を気にしなくてよくなります**。頭からworkerを叩き起こす必要も、`ray status` を手で確認する必要もありません。

**3. `docker exec` が不要になる**
公式手順の「クラスタを立てる」と「サーバを起動する」の2ステップが、1つの常駐プロセスに統合されます。SSHセッションに紐づく部分がなくなるのが本質的な改善点です。

---

### 🚀 使い方

```bash
# 両ノードで
mkdir -p ~/spark-vllm && cd ~/spark-vllm
# ファイルを配置後
chmod +x entrypoint.sh
cp env.head.example .env      # worker側は env.worker.example
vi .env                       # IP・イメージ名を自環境に合わせる

docker compose up -d
docker compose logs -f
```

`Application startup complete.` が出れば完了です。停止は `docker compose down`。

---

### ⚠️ 補足3点

**① QSFPのIPを恒久化してください**
composeは自動復帰しますが、**IPが消えていると起動ループになります**。`ip addr add` ではなく、NetworkManagerのプロファイルとして登録するのが確実です。

```bash
sudo nmcli con add type ethernet ifname enP2p1s0f1np1 con-name qsfp \
  ipv4.method manual ipv4.addresses 192.168.100.1/24 \
  ipv6.method disabled connection.autoconnect yes
```

これなら「NetworkManagerに設定を消される」問題自体が起きません。

**② `restart: unless-stopped` は unhealthy では再起動しません**
Dockerの再起動ポリシーはプロセス終了のみを見ます。ヘルスチェック失敗で復旧させたい場合は、別途 systemd タイマーや autoheal コンテナが必要です。まずは手動確認で十分かと思います。

**③ `MAX_MODEL_LEN=64` は疎通確認専用です**
405Bの動作確認が済んだら、実用モデルに切り替えて値を戻してください。

---

`/dev/infiniband` の有無だけ先に確認しておくと安心です（`ls /dev/infiniband`）。無ければ compose の `devices:` を外してください。


## ① docker compose は破壊的な変更をしないか

**ホストに対して破壊的な変更はしません** ✅ ただし、認識しておくべき点が3つあります。

**変更されないもの**
- netplan、systemd、カーネルパラメータ、aptパッケージ
- ホストのファイルシステム（マウント先を除く）
- 既存のDockerイメージ

**影響が残るもの**

| 項目 | 内容 | 元に戻す方法 |
|---|---|---|
| 🔴 **HFキャッシュ** | **書き込み可能**でマウント。コンテナ内から削除するとホスト側も消えます | バックアップ以外に手段なし |
| 🟡 **自動起動** | `restart: unless-stopped` によりOS起動時に立ち上がります | `docker compose down` |
| 🟡 **ポート占有** | `network_mode: host` で 6379 / 8000 / 8265 を掴みます | 同上 |

一番気にすべきは**HFキャッシュのマウント**です。400GBのモデルが消えると再ダウンロードになります。心配なら読み取り専用にできます。

```yaml
- ${HF_CACHE}:/root/.cache/huggingface:ro   # ダウンロードはホスト側で行う前提
```

なお `pid: host` は指定していないので、entrypoint 内の `ray stop --force` が**ホスト側のプロセスに影響することはありません**。コンテナ内に閉じています。

---

## ② 同時に複数の異なるモデルを起動できるか

**分散（TP=2）モデルを2つ同時は物理的に不可能です** ❌

DGX Spark は **1ノードあたり GPU 1基**（GB10）です。2ノードで GPU は合計2基。TP=2 のモデル1つで全部使い切ります。

現実的な選択肢は3つです。

| 方式 | 構成 | 使えるメモリ | 向き |
|---|---|---|---|
| **A. 1ノード1モデル** | 各Sparkで独立に TP=1 | 各128GB | 🎯 最も素直 |
| **B. モデル切替** | `.env` の `MODEL` を変えて `up -d` | 256GB | 大きいモデルを試したい |
| **C. LoRAで多重化** | `--enable-lora` でベース共通・アダプタ複数 | 256GB | 用途別チューニング |

**Aが実用上おすすめです。** クラスタを解体して各ノードで独立にvLLMを立て、前段に **LiteLLM などのルーター**を置けば、利用者からは「1つのAPIで複数モデルが使える」状態になります。

> 💡 補足：同一ノードで小さいモデルを2つ並べることも可能です（`GPU_MEM_UTIL=0.45` ずつ、ポートを分ける）。ただしメモリ帯域を食い合うため、両方とも遅くなります。

---

## ③ 200B〜300B クラスは動くか

**量子化されていれば動きます** ✅ 実際、公式手順の Step 10 が 405B（AWQ INT4・約200GB）で成立しています。

| モデル | 精度 | 重み | 2台256GBで |
|---|---|---|---|
| 200B | INT4 | 約100GB | ✅ 余裕あり |
| 300B | INT4 | 約150GB | ✅ 動く |
| 405B | INT4 | 約200GB | ⚠️ 起動はするがKV領域がほぼ無い |
| 200B | BF16 | 約400GB | ❌ 無理 |

**重要な注意：MoEでも「重みは全部メモリに載る」**

MoE（専門家混合）はアクティブなパラメータが少ないだけで、**全専門家の重みをメモリに置く必要があります**。「MoEだから軽い」ではなく、総パラメータで計算してください。速いのは計算量であって、メモリ消費ではありません。

**DeepSeek V4 Flash について**

サイズ的には約149GBなので**余裕で収まります**。残り約100GBをKVキャッシュに回せるため、405Bのような「起動はするが実用にならない」状態にならないのがポイントです。

ただし**この compose 構成のまま動くとは限りません**。以前お伝えした通り、コミュニティ実装ではGB10向けにビルドした専用イメージを使っています。NGC標準イメージがV4アーキテクチャに対応していれば `.env` の `MODEL` 差し替えだけで済みますが、対応していなければ起動時にエラーになります。

**確認方法**：まず現行構成のまま `MODEL=deepseek-ai/DeepSeek-V4-Flash` で起動してみて、`Model architectures ... are not supported` のようなエラーが出るかどうかを見るのが早いです。ダウンロードの前に、モデルの `config.json` だけ取得してアーキテクチャ名を確認する手もあります。

---

### 🚧 見落とされがちなボトルネック

サイズが収まっても、**メモリ帯域**が速度の上限を決めます。DGX Spark のLPDDR5xは約273GB/sで、H100（3TB/s超）の1/10程度です。

大きいモデルほど1トークン生成あたりの読み出し量が増えるため、200B級だと**単一ストリームで数十トークン/秒**が現実的な水準になります。「動く」と「実用的に速い」は別の話として見ておくのが安全です。

NCCL は **GPU同士がデータをやり取りするためのライブラリ**です。TP=2 では層ごとに2基のGPU間で結果を集約するため、**トークン生成のたびにNCCLが走ります**。ここの設定が速度と起動成否を直接決めます。

理解の鍵は、NCCLが**2つの経路を使い分けている**点です。**制御プレーン**は「お互いを見つけて手をつなぐ」段階、**データプレーン**は「実際にテンソルを流す」段階です。前者は普通のTCP、後者はRDMA（CPUを介さずGPU/NICが直接メモリをやり取りする高速経路）を使います。

---

### 📊 各変数の役割

| 変数 | 担当 | 間違えるとどうなるか |
|---|---|---|
| `NCCL_SOCKET_IFNAME` | 制御プレーンで使うNIC | Wi-Fiや`docker0`を掴んで**初期化がハング**。`network_mode: host` だと候補が多く誤選択しやすい |
| `NCCL_IB_HCA` | データプレーンのRDMAデバイス | 未接続デバイスを選ぶと**TCPに落ちて激遅**（10倍近い差） |
| `NCCL_IB_GID_INDEX` | RoCEのアドレス識別子 | 不一致だと **`ncclCommInitRank` エラー** |
| `NCCL_DEBUG` | ログ出力量 | 機能影響なし。切り分け用 |

> 💡 **GID とは**：RoCE（Ethernet上でRDMAを走らせる方式）で使うアドレス表のこと。1つのポートに複数のエントリがあり、`0/1`はRoCEv1、`2/3`はRoCEv2といった具合に用途が分かれています。両ノードで**同じ種類**を選ぶ必要があります。

---

### ⚠️ 前回の `.env` を訂正します

**`NCCL_IB_GID_INDEX` は指定しないでください。** 現行のNCCLではデフォルトが `-1` で、リンク層がEthernet（RoCE）ならRoCEv2対応のGIDインデックスを自動選択する仕様になっています。手で `3` を書くと、自動検出より悪い結果になる場合があります。

私が `3` を例示したのは古い情報に引きずられたためで、**まず未設定で試すのが正解**です。`ncclCommInitRank` エラーが出たときだけ、手動指定を検討してください。

---

### 🔍 値の調べ方

```bash
# デバイス名 ↔ インターフェース名の対応と Up/Down
ibdev2netdev
#   例) rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)

# ポートが PORT_ACTIVE か
ibv_devinfo

# GIDテーブル（手動指定が必要になった場合のみ）
show_gids
```

**`(Up)` になっている方**を選んでください。DGX Sparkは1つの物理ポートに論理インターフェースが2つあるため、ここが最大の落とし穴です。

---

### ✅ 推奨する初期設定

```bash
NCCL_SOCKET_IFNAME=enp1s0f1np1   # ibdev2netdev の (Up) 側
NCCL_IB_HCA=rocep1s0f1           # 上と対応するデバイス
# NCCL_IB_GID_INDEX=             # 未設定（自動検出に任せる）
NCCL_DEBUG=INFO                  # 初回のみ。安定したら WARN
```

初回は `INFO` にして、ログに以下が出るか確認してください。

```
NET/IB : Using [0]rocep1s0f1:1/RoCE
```

`NET/Socket` と出ていたらRDMAが使われていません。その場合は `NCCL_IB_HCA` を見直してください。

---

### 🧰 切り分けに使える変数

| 変数 | 用途 |
|---|---|
| `NCCL_IB_DISABLE=1` | **RDMAを無効化してTCPに固定**。これで動くならRDMA設定が原因と確定 |
| `NCCL_DEBUG_SUBSYS=INIT,NET` | ログを初期化とネットワークだけに絞る |
| `NCCL_IB_TIMEOUT=22` | リンクが不安定なときの猶予延長 |

`NCCL_IB_DISABLE=1` は速度を捨てる代わりに**確実に動く**ので、「vLLM側の問題かNCCL側の問題か」を切り分ける最初の一手として便利です。

---

### 🧪 vLLMより先にNCCL単体で検証する

NVIDIAが DGX Spark 向けの nccl-tests プレイブックを提供しています。`all_reduce_perf` を2ノードで流せば、**vLLMを持ち出さずにNCCLだけを検証**できます。

vLLMの起動失敗はログが長くて原因が埋もれがちなので、先にここで通しておくと切り分けが一段楽になります。

はい、そこで正しいです ✅ **MITライセンスでゲートなし**なので、`hf auth login` は必須ではありません。

---

### 🔍 まず事前チェック（160GB落とす前に）

`config.json` だけ先に取得して、**手元のvLLMが対応しているか**を確認するのが安全です。

```bash
hf download deepseek-ai/DeepSeek-V4-Flash \
  --include "config.json" "configuration_*.py" \
  --local-dir ~/ds4-check

cat ~/ds4-check/config.json | head -40
```

アーキテクチャは `deepseek_v4` です。NGC の vLLM イメージがこれに対応していなければ、起動時に `not supported` で落ちます。

あわせてディスク確認も。

```bash
df -h ~/.cache/huggingface
```

---

### 📥 ダウンロードコマンド

**ホスト側で実行**してください（プロキシ設定と社内CAがそのまま効きます）。

```bash
HF_HOME=~/.cache/huggingface \
  hf download deepseek-ai/DeepSeek-V4-Flash
```

進捗が止まったら、同じコマンドを再実行すれば**途中から再開**されます。

**これを両ノードで実行してください。** キャッシュは各ノードのローカルなので共有されません。

---

### 💾 容量の見積もり

284Bパラメータで、MoEの専門家部分がFP4、それ以外がFP8という混合精度です。重み実体はおおよそ **150〜160GB** です。

ただし `hf_xet` が別途チャンクキャッシュ（`~/.cache/huggingface/xet`）を作るため、**空き300GB程度**を見ておくと安心です。ダウンロード完了後は以下で削減できます。

```bash
du -sh ~/.cache/huggingface/xet
rm -rf ~/.cache/huggingface/xet    # 再DL時に再作成される
```

---

### ⚠️ 見落としやすい落とし穴

**チャットテンプレートが同梱されていません**

このリリースにはJinja形式のチャットテンプレートが無く、代わりに `encoding` フォルダのPythonスクリプトでメッセージを文字列化する方式が案内されています。

つまり `vllm serve` しても **`/v1/chat/completions` がそのままでは使えない可能性が高い**です。`--chat-template` で別途テンプレートを渡すか、`/v1/completions`（生の文字列）で試すことになります。以前触れたコミュニティ実装が専用イメージを使っていたのは、この辺りの対応も含まれているためと思われます。

**推奨サンプリング設定**

公式は `temperature = 1.0, top_p = 1.0` を推奨しています。また Think Max モードを使う場合はコンテキスト長を最低384Kにするよう記載があります。

---

### 🌏 代替ダウンロード元

HuggingFace が遅い場合、ModelScope にも同じモデルが置かれています。プロキシで `xethub.hf.co` が通らない環境なら、こちらの方が早いかもしれません。

---

まずは `config.json` の取得と `df -h` から始めてください。config が読めた時点で、対応可否とメモリ見積もりをもう少し正確に詰められます。

汚さない順に3つあります。**一番きれいなのは、既にあるvLLMコンテナを使い捨てで回す方法**です 🎯

---

### 🥇 方法A：コンテナで実行（ホストへのインストールゼロ）

vLLMイメージには `hf` が入っています。**`--rm` で使い捨て**にすれば、ホストには何も残りません。

```bash
docker run --rm -it \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e HTTP_PROXY="$HTTP_PROXY" -e HTTPS_PROXY="$HTTPS_PROXY" \
  -e NO_PROXY="$NO_PROXY" \
  -e REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
  -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  -v /usr/local/share/ca-certificates:/usr/local/share/ca-certificates:ro \
  $VLLM_IMAGE \
  bash -c "update-ca-certificates && hf download deepseek-ai/DeepSeek-V4-Flash"
```

ポイントは **社内CAディレクトリを読み取り専用でマウント**し、コンテナ起動のたびに `update-ca-certificates` を走らせている点です。これで以前の証明書エラーが解消され、かつコンテナ内の変更は終了時に消えます。

> 💡 Ray用のコンテナとは別プロセスなので、クラスタが動いていても干渉しません（GPUを使わないため `--gpus` 不要）。

**残るもの**：`~/.cache/huggingface` の中身だけ（＝欲しいモノ）

---

### 🥈 方法B：pipx（ホストに入れるが隔離される）

コンテナ経由が煩わしければこちらです。専用のvenvが自動で作られ、システムのPythonには一切触りません。

```bash
sudo apt install -y pipx
pipx install "huggingface_hub[cli,hf_xet]"
pipx ensurepath && exec $SHELL
```

**残るもの**：`~/.local/share/pipx/venvs/huggingface-hub/` と `~/.local/bin/hf`

不要になったら以下で完全に消せます。

```bash
pipx uninstall huggingface_hub
```

`sudo apt install pipx` がAPT履歴に残るのが気になる場合は、方法Cへ。

---

### 🥉 方法C：使い捨てvenv（sudo不要・ディレクトリ1つ）

```bash
python3 -m venv /tmp/hfenv
/tmp/hfenv/bin/pip install -q "huggingface_hub[cli,hf_xet]"

HF_HOME=~/.cache/huggingface \
  /tmp/hfenv/bin/hf download deepseek-ai/DeepSeek-V4-Flash

rm -rf /tmp/hfenv    # 完了後に削除
```

PATHも通さず、フルパスで直接叩く形です。`rm -rf` 一発で痕跡が消えます。

> ⚠️ `/tmp` は再起動で消える環境もあるので、160GBのダウンロード中に消えないよう `~/hfenv` にする方が無難かもしれません（venv自体は数十MBです）。

---

### 📊 比較

| | ホストへの影響 | sudo | 手軽さ |
|---|---|---|---|
| **A. コンテナ** | なし | 不要※ | コマンドが長い |
| **B. pipx** | venv1つ + aptパッケージ | 必要 | ◎ 以後も使える |
| **C. 使い捨てvenv** | ディレクトリ1つ | 不要 | ○ |

※ dockerグループに入っている前提

---

### 🎯 おすすめ

**今回はAでいいと思います。** 証明書もプロキシもコンテナ側で完結し、ホストの構成をまったく変えずに済みます。

ただし「今後もモデルを頻繁に入れ替える」なら、**Bのpipx**にしておくとコマンドが `hf download <model>` の一行で済むようになり、運用が楽です。DGX Sparkを本番基盤として使っていく方針なら、pipx自体は他のCLIツール管理にも使えるので入れて損はありません。

まずAで `config.json` の事前チェックを回してみて、感触を見てから判断されるのが良さそうです。

**基本は可能ですが、そのままだと外部通信を試みます** ⚠️ 明示的に止める設定が必要です。

---

### 🚨 起動時に外へ出ようとするもの

| 発生源 | 内容 | 抑止方法 |
|---|---|---|
| **HuggingFace Hub** | `MODEL` にリポジトリID（`Qwen/Qwen3-8B`）を指定していると、キャッシュがあっても**更新確認のためHTTPアクセス**します | `HF_HUB_OFFLINE=1` |
| **vLLM の使用状況収集** | 匿名の利用統計を送信します | `VLLM_NO_USAGE_STATS=1` |
| **Ray のダッシュボード/メトリクス** | ノード間のみ。外部へは出ません | 対応不要 |

> 💡 特に厄介なのが1つ目です。ローカルにモデルがあっても、HFへの疎通確認でタイムアウト待ちが発生し、**起動が数分余計にかかる**ことがあります。エラーにならず「ただ遅い」ので原因に気づきにくいです。

---

### ✅ オフライン化の設定

`.env` に追加してください。

```bash
# --- オフライン動作 ---
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
VLLM_NO_USAGE_STATS=1
DO_NOT_TRACK=1
```

`docker-compose.yml` の `environment:` にも渡します。

```yaml
      - HF_HUB_OFFLINE=${HF_HUB_OFFLINE:-0}
      - TRANSFORMERS_OFFLINE=${TRANSFORMERS_OFFLINE:-0}
      - VLLM_NO_USAGE_STATS=${VLLM_NO_USAGE_STATS:-1}
      - DO_NOT_TRACK=${DO_NOT_TRACK:-1}
```

**さらに確実にするなら、ローカルパス指定**が最善です。

```bash
MODEL=/root/.cache/huggingface/hub/models--Qwen--Qwen3-8B/snapshots/<hash>
```

リポジトリIDではなくパスを渡せば、HFに問い合わせる理由自体が消えます。ただし `--served-model-name` を付けないとAPIのモデル名が長いパスになるので、その場合は `EXTRA_VLLM_ARGS` に追加してください。

---

### 🔌 「オフライン」の範囲について

3つのレイヤーを分けて考える必要があります。

**① 推論時（実行中）** → 完全にオフラインで動きます。モデルさえローカルにあれば、外部通信は一切不要です。

**② 起動時** → 上記の環境変数で塞げます。

**③ コンテナイメージの入手** → **ここは別問題です。** `docker compose up` の際、ローカルにイメージが無ければ NGC からpullしようとします。エアギャップ環境では事前に持ち込む必要があります。

```bash
# 接続可能な環境で
docker pull $VLLM_IMAGE
docker save $VLLM_IMAGE | gzip > vllm-image.tar.gz

# エアギャップ側で
gunzip -c vllm-image.tar.gz | docker load
```

compose に `pull_policy: never` を足しておくと、うっかりpullを試みることも防げます。

```yaml
    image: ${VLLM_IMAGE}
    pull_policy: never
```

---

### 🧪 検証方法

設定が効いているかは、**プロキシを外して起動する**のが一番確実です。

```bash
# .env のプロキシを空にして起動
HTTP_PROXY=
HTTPS_PROXY=
```

これで正常に `Application startup complete.` まで到達すれば、外部通信に依存していないことが証明できます。ネットワークを物理的に切る前の予行演習として有効です。

より厳密に確認したい場合は、head ノードで通信を観測する手もあります。

```bash
sudo tcpdump -n -i any 'port 443 and not net 192.168.100.0/24'
```

起動中にパケットが飛ばなければクリーンです。

---

### 📌 まとめ

| 項目 | オフライン可否 |
|---|---|
| 推論の実行 | ✅ 完全に可能 |
| vLLM/Rayの起動 | ✅ 環境変数の追加で可能 |
| モデルの取得 | ❌ 事前ダウンロードが必要 |
| コンテナイメージ | ❌ 事前に `docker save` で持ち込み |

エアギャップ環境への展開を見据えているとのことでしたので、**いまのうちに `HF_HUB_OFFLINE=1` を入れた状態で通しておく**ことをおすすめします。後から「実は起動時にHFを見ていた」と発覚するより、接続できる今のうちに確認しておく方が安全です。

**必須ではありません。** ただし「あるとRDMA、無いとTCPフォールバック」という性能差が出ます。

---

### 📊 何が変わるか

| | `/dev/infiniband` あり | なし |
|---|---|---|
| NCCLの経路 | RoCE（RDMA） | TCPソケット |
| ログの表示 | `NET/IB : Using [0]rocep1s0f1:1/RoCE` | `NET/Socket : Using [0]enp1s0f1np1` |
| 動作 | ✅ | ✅ **動きます** |
| 速度 | 速い | 遅い |

TP=2 では**層ごとに小さなall-reduceが何度も走る**ため、帯域よりレイテンシが効きます。RDMAはCPUとカーネルを迂回するので、この小さな通信の往復が短くなります。TCPフォールバックでもトークンは生成されますが、生成速度に体感差が出ます。

---

### ⚠️ 「残しておく」の可否

**`/dev/infiniband` が存在するなら残して問題ありません。** 副作用はありません。

**存在しない場合は起動できません。** compose に「デバイスがあれば使う」という条件指定の構文はないため、以下のエラーで落ちます。

```
error gathering device information while adding custom device
"/dev/infiniband": no such file or directory
```

なので判断はシンプルです。

```bash
ls /dev/infiniband
```

- 何か表示される → **残す**
- `No such file or directory` → **`devices:` を2行ともコメントアウト**

---

### 🔧 関連する2つの設定について

```yaml
    cap_add:
      - IPC_LOCK
    ulimits:
      memlock: -1
```

こちらは**デバイスの有無に関わらず残して大丈夫**です。RDMAがメモリページを固定（ピン留め）するために必要な権限で、RDMAを使わない場合は単に使われないだけです。起動エラーにはなりません。

`shm_size: 10.24g` は公式手順と同じ値で、RDMAとは無関係に必要です。

---

### 🔍 一度確認しておくと良いこと

**いま動いている `run_cluster.sh` のコマンドに、デバイス指定が入っていたか**を見ておくことをおすすめします。

`run_cluster.sh` 本体には `--network host` / `--shm-size` / `--gpus all` / HFキャッシュのマウントしか含まれていません。デバイス指定は追加引数として渡す必要があります。

つまり、公式手順のコマンドに `--device` や `--privileged` が含まれていなければ、**現在の動作確認済み構成はTCPフォールバックで動いている**可能性があります。その場合、compose で `devices:` を足すのは「公式手順との差分を増やす」ことになります。

一変数ずつ検証する方針なら、**まず公式手順と同じ状態（devices なし）で compose を通し**、動作確認後に `devices:` を足して速度差を比べる、という順序が切り分けやすいです。

現状の確認は起動後のログで可能です。

```bash
docker compose logs | grep -E "NET/(IB|Socket)"
```

---

### 🔐 セキュリティ観点

`devices:` はコンテナにハードウェアへの直接アクセスを与えるものなので、権限の付与ではあります。ただし `--privileged` と比べれば範囲は限定的で、GPU/RDMAワークロードでは標準的な構成です。単一テナントのアプライアンス用途であれば、実務上の懸念は小さいと考えて差し支えありません。

より絞りたい場合は、デバイスを個別指定する手もあります。

```yaml
    devices:
      - /dev/infiniband/uverbs0
      - /dev/infiniband/rdma_cm
```

ただしデバイス名は環境依存なので、`ls /dev/infiniband` の実際の出力を見てから決めてください。
