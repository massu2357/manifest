<<<<<<< HEAD
2 台の DGX Spark クラスタ化は、NVIDIA 公式 playbook（connect-two-sparks → nccl）の流れが定石です。既に管理NW経由の SSH ができているので、残りは以下の 5 フェーズです。

## フェーズ0: 前提確認

- **両ノードで同一ユーザー名**を使うこと。playbook・ツール群が SSH で全ホスト一貫したユーザーを前提にしています。合わせるのが無難です。
- QSFP ケーブルを両機の任意の QSFP ポートに直結（現地作業はこれだけ）。
- DGX OS を両ノード同バージョンに揃えておく。

## フェーズ1: CX-7 の Up インターフェース特定（両ノードで）

```bash
ibdev2netdev
# rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)  ← これを使う
```

`enp1...` 側を使い、同一物理ポートの別名である `enP2p...` は無視します。**重要な罠**: PCI エニュメレーションの都合で、Up になるポート名が 2 台で異なることがあります（片方 `...f1`、もう片方 `...f0`）。設定を片方からコピーせず、**必ず各ノードで実際の Up 名を確認**してください。

## フェーズ2: CX-7 に固定IP（netplan、両ノードで）

Node 1 の `/etc/netplan/40-cx7.yaml`（IF名は各自の Up 名に置換）:

```yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
      dhcp4: no
      mtu: 9000
```

Node 2 は `192.168.100.11/24` で同様に。適用と確認:

```bash
sudo chmod 600 /etc/netplan/40-cx7.yaml
sudo netplan apply
ping 192.168.100.11   # 対向へ疎通確認
```

MTU 9000 は直結構成での転送スループット最適化です。あわせて、NetworkManager が CX-7 に自動生成した DHCP プロファイルは削除か autoconnect 無効に(放置すると mDNS ホスト名衝突の既知事象を踏みます)。

## フェーズ3: RDMA 帯域検証（perftest）

NCCL に行く前に、リンクが素の RDMA で健全かをゲートします:

```bash
sudo apt install perftest
# Node1（サーバ側）: ib_write_bw -d rocep1s0f1
# Node2（クライアント側）: ib_write_bw -d rocep1s0f1 192.168.100.10
```

**合格ラインはレール当たり ~90 Gbps 以上**（100Gbps リンクで実効 ~93.3 Gbps が目安）。ここで ~13 Gbps 程度に張り付く場合はファームウェアのスロットル問題が知られており、先に潰す必要があります。

## フェーズ4: ノード間パスワードレス SSH

playbook の `discover-sparks.sh` を片方で実行すると、ノード自動発見と双方向 SSH 設定まで自動化されます。手動なら CX-7 のIPに対して `ssh-copy-id` を双方向で。あわせて両ノードの `/etc/hosts` に CX-7 IP → ホスト名を書いておくと、以降の mpirun / Ray の指定が確定的になります。

## フェーズ5: NCCL 検証

DGX Spark の Blackwell（sm_121）向けに **NCCL をソースビルド**し、nccl-tests で 2 ノード間の集合通信を検証します(手順は playbook「NCCL for Two Sparks」準拠)。実行例:

```bash
mpirun -np 2 -H 192.168.100.10:1,192.168.100.11:1 \
  --mca plm_rsh_agent "ssh -o StrictHostKeyChecking=no" \
  -x NCCL_SOCKET_IFNAME=enp1s0f1np1 \
  -x UCX_NET_DEVICES=enp1s0f1np1 \
  -x OMPI_MCA_btl_tcp_if_include=enp1s0f1np1 \
  -x LD_LIBRARY_PATH \
  $HOME/nccl-tests/build/all_gather_perf
```

環境変数で CX-7 を明示指定しないと、管理NW側に落ちて動くのに 50 倍遅い「サイレント TCP フォールバック」になり得ます。ログに NET/IB が出ていることを確認してください。2 台でIF名が違う場合は `NCCL_SOCKET_IFNAME=enp1s0f1np1,enp1s0f0np0` のように**両方の名前をカンマ区切りで渡し、各ランクに自分のIFをマッチさせる**のが確実です。

## フェーズ6: ワークロード層

ここまでで「土台」完成です。上に載せるものを選びます:

- **vLLM + Ray クラスタ**: 分散推論の定番。Ray がクラスタを編成し、NCCL が RoCE 上で AllReduce を実行する構成
- **TensorRT-LLM**: 高性能ですが、**1.3.0rc10 に 2 台 Spark 構成での NCCL 検出リグレッション（segfault/hang）が報告されており、1.2.0rc6 では動作**という状況なので、コンテナのバージョン選定に注意
- **sparkrun**: コミュニティツール。コンテナ/モデル配布とマルチノード推論起動を自動化してくれるので、運用を楽にしたいなら検討価値あり

まず nccl-tests が NET/IB で帯域が出るところまでをゴールに進めて、その後にワークロード選定、という順がお勧めです。フェーズ3 か 5 で数字が出ない場合が一番ハマりやすいので、そこで詰まったら状況を教えてください。
=======
このPlaybookで実際に外へ出る通信は **apt 1回 ＋ git clone 2回の計3つだけ**です。`make`（ビルド）とStep 4以降は完全にローカル／ノード間通信なので、以下を開ければ完走できます。

## 開けるべきURL一覧

| ドメイン | 用途 | ポート | 必須度 |
|---|---|---|---|
| `github.com` | nccl / nccl-tests の git clone | 443 | **必須** |
| `ports.ubuntu.com` | libopenmpi-dev（aarch64 Ubuntuパッケージ）とその依存 | 80(http) | **必須** |
| `repo.download.nvidia.com` | DGX OS の NVIDIAリポジトリ（apt-get update が参照） | 443 | 推奨 |
| `developer.download.nvidia.com` | CUDAリポジトリ（apt-get update が参照） | 443 | 推奨 |
| `codeload.github.com` | git の tarball/アーカイブ取得（保険） | 443 | 任意 |
| `objects.githubusercontent.com` | GitHub LFS/オブジェクト（保険） | 443 | 任意 |

ポイントが2つあります。

**プロトコルの混在** — apt は `http://`（80番）で取りにいくことが多く、GitHub は `https://`（443番）です。プロキシ側で **80番の転送も許可**しておかないと、apt だけ弾かれます。

**apt の許可先は実機で確定するのが確実** — DGX OS がミラーを差し替えている可能性があるので、次で実際のホストを吸い出してください（deb822形式の `.sources` にも対応）:

```bash
grep -rhoP 'https?://[^/ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u
```

ここに出たホストをそのまま許可リストに入れれば漏れません。スキーム（http/https）も確認できます。

## プロキシ設定方法

以下 `PROXY_HOST:PORT` を自分の値に置き換え、認証ありなら `http://user:pass@PROXY_HOST:PORT/` の形式にします。

**apt**（sudo実行なので、環境変数ではなくこの設定ファイル方式が確実）
```bash
sudo tee /etc/apt/apt.conf.d/95proxy >/dev/null <<'EOF'
Acquire::http::Proxy  "http://PROXY_HOST:PORT/";
Acquire::https::Proxy "http://PROXY_HOST:PORT/";
EOF
```

**git**（clone は一般ユーザ実行なのでユーザ設定でOK）
```bash
git config --global http.proxy  http://PROXY_HOST:PORT
git config --global https.proxy http://PROXY_HOST:PORT
```

**環境変数（永続化するなら `/etc/environment` に記載）**
```bash
http_proxy=http://PROXY_HOST:PORT
https_proxy=http://PROXY_HOST:PORT
no_proxy=localhost,127.0.0.1,::1,169.254.0.0/16,<相手SparkのIP>
```
`no_proxy` に **169.254.0.0/16（CX-7 のリンクローカル）と相手ノードのIP** を必ず入れてください。ノード間通信や mpirun の SSH がプロキシに吸われるのを防ぎます。

**MITM（TLSインスペクション）型プロキシの場合**
```bash
sudo cp corp-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```
git・apt ともシステムCAバンドルを見るので、これでHTTPS検証が通ります。git で個別指定が要る場合は `git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt`。

**sudo の罠** — ユーザシェルで `export` した `http_proxy` は、sudo 実行時に既定（env_reset）で引き継がれません。apt は上の `apt.conf.d` 方式なら影響を受けませんが、env 変数で通したい処理があれば `sudo -E` で環境を保持してください。

---

なお、この一覧は **NCCL Playbook 完走（Step 2の疎通テストまで）** をカバーするものです。この先で2ノードにまたがって vLLM などの推論スタックを立てる段階では、PyPI やコンテナレジストリなど別の許可先が必要になるので、そこは別途整理する形になります。

>>>>>>> 17454bb (Add)
