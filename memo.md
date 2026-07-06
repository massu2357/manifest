DGX Spark で「固定IPを振る」対象は、ほぼ間違いなく **通常の有線LANポート（Realtek 10GbE / RJ45）** だと思います。ここがポイントなのですが、DGX Spark はデスクトップ構成のため、この管理用インターフェースは Ubuntu Server のような netplan/systemd-networkd ではなく **NetworkManager** が管理しています。実際、GNOME のネットワーク設定にも「Realtek Ethernet」として表示されます。なので固定IPは GUI か `nmcli` で入れるのが正攻法です。

（QSFP の ConnectX-7 側は 2 台クラスタ用の 200GbE インターコネクトで、そちらは `/etc/netplan/40-cx7.yaml` を使う別ワークフローになります。1 台運用で LAN に固定IPを振りたいだけなら、以下の管理NIC側の手順で OK です。）

## 方法A: GNOME 設定（デスクトップから一番速い）

1. 右上のネットワークアイコン → 設定 → 「ネットワーク」
2. 有線接続（Realtek Ethernet）の歯車アイコンをクリック
3. 「IPv4」タブ → 方式を **手動 (Manual)** に変更
4. アドレス／ネットマスク／ゲートウェイ、必要なら DNS を入力 → 適用
5. 接続をいったんオフ→オンして反映

## 方法B: nmcli（再現性重視・手順書に残せる）

air-gapped 用途で設定を記録・横展開したいなら、こちらの方が管理しやすいはずです。

まず対象デバイスと接続名を確認します（Realtek 有線は type が ethernet で出ます。CX-7 の `enp1s0f*` / `enP2p*` と混同しないよう注意）：

```bash
nmcli device status
nmcli connection show
```

接続名（例では "Wired connection 1"、環境により異なる）を確認したら：

```bash
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "192.168.1.1,8.8.8.8"

sudo nmcli connection up "Wired connection 1"
```

反映後は `ip addr show` で確認してください。閉域セグメントに入れる場合は、`ipv4.gateway` を外部に向けない／`ipv4.dns` を内部リゾルバに向ける（またはDNS省略）に調整すればそのまま air-gapped 運用に載せられます。

## 注意点（DGX Spark 固有の落とし穴）

- **NetworkManager が全物理IFに DHCP プロファイルを自動作成する**挙動があり、CX-7 インターコネクトのポートに対しても "Wired connection" を作って DHCP を試み続けます。DHCP サーバーがない状態だと Avahi の mDNS ホスト名衝突（`spark1-30.local` のように連番が付く）を起こす既知事象があります。まだインターコネクトを使わないなら、CX-7 側のプロファイルは `nmcli connection modify <name> connection.autoconnect no` などで無効化しておくと安全です。
- netplan を触る場合の権限問題：DGX Spark 出荷時の `/etc/netplan/*` はパーミッションが緩いことがあり、`sudo chmod 600 /etc/netplan/*` してから `sudo netplan apply` するのが定石です（warning 回避）。

まずは方法A で疎通確認 → 手順を残したいタイミングで nmcli に置き換える、という流れが楽だと思います。CX-7 でのクラスタ構成まで進む段階になったら、そちら側の netplan 設定も別途詰めましょう。

---

2 台クラスタの本番化なら、固定IP化の対象は**2 つのネットワークに分けて**考えるのが要点です。それぞれ管理方式が違います。

- **管理NW（Realtek 10GbE / RJ45）** … 初期セットアップで DHCP が振られたのはこちら。SSH・監視・管理の到達性を安定させるために固定化します。管理は **NetworkManager**。
- **CX-7 インターコネクト（200GbE QSFP）** … クラスタ本体のファブリック。NCCL / mpirun / Ray が確定的にアドレス解決できるよう、**こここそ固定IPが必須**です。管理は **netplan**。NVIDIA も 2 ノード構成では手動の静的割り当てを推奨しています(自動の link-local だと再起動でIPが変わります)。

---

## 1. 管理NW（Realtek）: DHCP → 固定

前回の手順どおり NetworkManager で各ノードに別々の固定IPを入れます（再現性重視なら nmcli）：

```bash
# 対象の有線接続名を確認（CX-7 の enp1s0f* / enP2p* と混同しない）
nmcli device status

# Node ごとに別IPを設定
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "192.168.1.1"
sudo nmcli connection up "Wired connection 1"
```

中央管理したい場合は、完全固定ではなく **DHCP 予約（MAC 固定リース）**でも本番要件は満たせます。air-gapped セグメントに置くなら完全固定＋gateway/DNS を内部向けに、が扱いやすいです。

## 2. CX-7 インターコネクト: 固定IP化（netplan）

**まず Up しているインターフェースを確認**します。どれが Up かは物理的にどの QSFP ポートに挿したかで変わります：

```bash
ibdev2netdev
# 例:
# rocep1s0f1 port 1 ==> enp1s0f1np1 (Up)   ← これを使う
# roceP2p1s0f1 port 1 ==> enP2p1s0f1np1 (Up)  ← 同一物理ポートの別名。無視
```

NVIDIA の指針では、**`enp1...` 側を使い、`enP2p...` 側は無視**します(同じ物理ポートの別名のため)。ケーブル 1 本なら全帯域（200GbE）出るので、片方のペアだけ設定すれば十分です。ケーブル 2 本で束ねる場合のみ 4 インターフェース全部にIPを振る必要があります。

**Node 1** `/etc/netplan/40-cx7.yaml`（Up のIFに置き換え、MTU 9000 は任意の最適化）：

```yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
      dhcp4: no
      mtu: 9000
```

**Node 2** は同一サブネットで別IP：

```yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.11/24]
      dhcp4: no
      mtu: 9000
```

両ノードで適用（DGX Spark は出荷時の netplan パーミッションが緩いので chmod 必須）：

```bash
sudo chmod 600 /etc/netplan/40-cx7.yaml
sudo netplan apply
ip addr show enp1s0f1np1   # 確認
```

MTU 9000（ジャンボフレーム）は大容量転送のスループットに効きますが、**両端＋経路上で揃っていないと通信が壊れる**ので、直結（スイッチなし）でのみ有効化してください。RDMA の帯域検証は perftest の `ib_send_bw` で行えます(100G リンクなら実測 ~93Gbps 前後が目安)。

## 本番運用での注意点

- **mDNS ホスト名衝突の既知事象**: NetworkManager が CX-7 の各IFに対しても自動で DHCP プロファイルを作り、DHCP サーバーがないと Avahi が `spark1-30.local` のように連番を付け続ける問題があります。上記のように CX-7 を**静的設定にすれば DHCP 試行がなくなり回避**できます。念のため未使用の CX-7 プロファイルは `nmcli connection modify <name> connection.autoconnect no` で自動接続を切っておくと確実です。
- **名前解決の固定**: mpirun / Ray / NCCL の設定でノード名を使うなら、両ノードの `/etc/hosts` に固定した CX-7 IP → ノード名を書いておくと確定的になります。
- **パスワードレス SSH の張り直し**: 管理NW・CX-7 のIPを変えたら SSH 鍵配布もやり直しが必要です。NVIDIA の `discover-sparks` スクリプト（自動）か、`ssh-copy-id` で手動配布してください。

管理NWは「到達性のため」、CX-7 は「クラスタ通信の確定性のため」と役割が別なので、両方固定しておくのが本番としては安全です。まず CX-7 を静的化 → 帯域検証 → SSH 張り直し、の順で進めるのが詰まりにくいと思います。

---

はい、できます。むしろそれが DGX Spark でのヘッドレス構築の定石です。

理由はこれまで整理した構成そのものにあります。**管理NW（Realtek / NetworkManager 管理）と CX-7（netplan 管理）は独立**していて、あなたの SSH ライフラインは管理NW側にあります。CX-7 のインターフェースをいくらいじっても、乗っている管理NWの接続は切れません。「自分が座っている枝は切らない」構図になっているので安全です。

遠隔で安全に進めるための注意点だけ挙げておきます。

- **netplan ファイルには CX-7 のIFだけ書く。** 管理NIC（Realtek）を同じファイルに入れない限り、`netplan apply` は管理接続に触れません。管理側は nmcli で作った NetworkManager プロファイルに残るため、netplan の適用対象外だからです。
- **`sudo netplan try` を保険に使う。** 既定 120 秒以内に確認しなければ自動ロールバックされるので、遠隔での netplan 変更の安全弁になります（`netplan apply` が NM をリロードする際の一時的な瞬断も、これで担保できます）。問題なければ Enter で確定。
- **CX-7 に自動生成された DHCP プロファイルが残っていないか確認。** 前述の mDNS 衝突の原因になるやつで、静的 netplan 設定と競合することがあります。`nmcli connection show` で CX-7 IF 向けの "Wired connection X" があれば削除／無効化してから適用するとクリーンです。
- **順序的に「管理IPの固定化そのもの」だけは要注意。** IPを変える操作なので、DHCP セッション上で実行すると一旦切れます（新IPで入り直す前提）。これは先にやるので問題ないはずですが、加えて**一度再起動して固定IPが復活・到達できることを確認**してから完全ヘッドレスに移ると、再起動時のロックアウトを防げます。ついでに管理接続の `autoconnect=yes` と sshd の自動起動も見ておくと安心です。

ここまで来れば、CX-7 の設定・SSH 鍵配布（discover-sparks / ssh-copy-id）・帯域検証（ib_send_bw）まで全部リモートで完結します。物理作業として残るのは **QSFP ケーブルの接続だけ**です（挿さっていないと `ibdev2netdev` で Up にならないので、そこだけは現地で済ませておく必要があります）。

---

半分そのとおり、で少し補足が要る、という感じです。

正確に言うと、**CX-7 インターコネクトは「クラスタの通信が流れる物理・ネットワークの土台」**です。そこにIPを振る作業は、クラスタ化に必須のステップではありますが、「IPを振った＝クラスタ完成」ではありません。土管を通す工程、というイメージが近いです。

CX-7 の正体は、2 台の Spark を直結する **200GbE の専用線（ConnectX-7 NIC の QSFP ポート）**です。ここが管理NWと役割が真逆なのがポイントで、

- **管理NW（Realtek 10GbE）** = あなたが箱に触る線（SSH・監視・操作）
- **CX-7** = 箱同士が会話する線（ノード間のデータ転送）

分散推論では、大型モデルを 2 台に分割して NCCL が all-reduce などで大量のテンソルをやり取りします。この帯域を 10GbE の管理線で流すと話にならないので、200GbE + RoCEv2（RDMA）の専用線を使う——これが「2 台を 1 台のように動かす」実効性能の肝です。なので CX-7 は"クラスタらしさ"を担う中核ではあります。

ただ、クラスタとして実際に動かすには CX-7 のIPに加えてあと 2 つ要ります：

1. **ノード間のパスワードレス SSH**（discover-sparks / ssh-copy-id で張る）
2. **分散ランタイム**（Ray クラスタ / mpirun / NCCL の設定）が、その CX-7 の上で 2 台をまとめて 1 つの計算資源として扱う

つまり階層で見ると、**CX-7 のIP設定＝ネットワーク層の必要条件**で、その上に SSH の信頼関係と分散フレームワークが乗って初めて「クラスタ」になります。「CX-7 の設定箇所＝クラスタ設定の"すべて"」ではなく、"土台部分"だと捉えておくと正確です。
