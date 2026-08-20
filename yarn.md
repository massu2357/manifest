**実行中のアプリは「ResourceManager UI からコンテナのログを開く」のが基本ルートです** 📍

YARN のログは実行中と完了後で置き場所が変わります。ここが最初のつまずきポイントです。

| 状態 | ログの場所 |
|---|---|
| 実行中 | 各 NodeManager のローカルディスク |
| 完了後 | HDFS に集約（ログアグリゲーション） |

**方法1：Web UI（一番手軽）🖥️**

Cloudera Manager > YARN > Web UI > **ResourceManager Web UI**（通常 8088番ポート）を開き、以下の順に辿ります。

`application_xxx` をクリック → **Attempt ID**（appattempt_xxx）→ **Container リスト** → 各コンテナの **Logs** リンク

コンテナのログリンクは NodeManager（8042番ポート）が実行中のログをそのまま返してくれます。

**方法2：コマンドライン 💻**

```bash
# まずアプリの種類と状態を確認
yarn application -status application_xxx

# ApplicationMaster（アプリ全体の司令塔）のログを見る
yarn logs -applicationId application_xxx -am 1

# コンテナ一覧を取得してから個別に見る
yarn applicationattempt -list application_xxx
yarn container -list appattempt_xxx
yarn logs -applicationId application_xxx -containerId container_xxx

# stderr だけに絞る（エラー調査ではこれが一番早い）
yarn logs -applicationId application_xxx -log_files stderr
```

⚠️ Kerberos 環境なので、実行前に `kinit` が必要です。

**方法3：NodeManager のローカルディスクを直接見る 📂**

コンテナが動いているホストに入り、以下のパス配下を確認します。

```
<yarn.nodemanager.log-dirs>/application_xxx/container_xxx/
  ├─ stdout   # 標準出力
  ├─ stderr   # エラー出力（まずここ）
  └─ syslog   # フレームワークのログ
```

パスは Cloudera Manager > YARN > 設定 で `yarn.nodemanager.log-dirs` を検索すると確認できます（`/var/log/hadoop-yarn/container` などが一般的です）。

**アプリの種類で「本当に見るべき場所」が変わります 🔍**

- **Spark** → RM UI の **ApplicationMaster** リンクから Spark UI へ。ステージ／タスク単位の失敗原因はこちらの方が圧倒的に分かりやすいです
- **MapReduce** → 完了後は JobHistory Server（19888番ポート）
- **Hive on Tez** → Tez UI、または HiveServer2 のクエリログ

なお、コンテナのローカルログはアプリ完了後に削除され、HDFS の `/tmp/logs/<ユーザー名>/` 配下へ移動します。実行中に握っておきたいログがあるなら、終わる前に取得しておくのが安全です 📌
