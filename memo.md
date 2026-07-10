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

