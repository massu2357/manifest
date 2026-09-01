# ご質問への回答：PySpark で checkpoint 更新をログ監視できるか

**結論：できます。** 標準の `StreamingQueryListener` で十分実装可能です 👍

---

## 📁 まず、checkpoint に何が書かれているか

Structured Streaming の `checkpointLocation` の中身はこうなっています。

```
<checkpointLocation>/
├── offsets/     ← バッチ開始「前」に「これから処理する範囲」を記録
├── commits/     ← バッチ成功「後」に「完了しました」を記録
├── sources/0/   ← ファイルソース専用：読み込み済みファイルの一覧
└── metadata     ← クエリID など
```

監視の肝はここです 👇

| 状態 | 意味 |
|---|---|
| `offsets` の最大番号 == `commits` の最大番号 | ✅ 健全（全バッチ完了済み） |
| `offsets` だけ進んで `commits` が無い | ⚠️ そのバッチは未完了 → **再起動時に丸ごと再処理される** |

> 💡 **用語補足**：`offset`（オフセット）は「どこまで読んだかの通し番号」、`commit`（コミット）は「その分の処理が終わった証跡」です。

---

## ① StreamingQueryListener で出す（推奨・PySpark 3.4 以降）

バッチが1つ終わるたびにイベントが飛んでくるので、そこでログを吐きます。

```python
import json, logging
from pyspark.sql.streaming import StreamingQueryListener

log = logging.getLogger("stream-monitor")

class CheckpointMonitor(StreamingQueryListener):
    def onQueryStarted(self, event):
        log.info(f"[STARTED] id={event.id} runId={event.runId}")

    def onQueryProgress(self, event):
        # バージョン差異を避けるため JSON で受けるのが安全
        p = json.loads(event.progress.json)
        src = p["sources"][0]
        log.info(json.dumps({
            "batchId":      p["batchId"],        # ★最重要
            "numInputRows": p["numInputRows"],
            "startOffset":  src["startOffset"],  # 前回どこまで
            "endOffset":    src["endOffset"],    # 今回どこまで
            "durationMs":   p["durationMs"],
        }, ensure_ascii=False))

    def onQueryTerminated(self, event):
        log.error(f"[TERMINATED] id={event.id} exception={event.exception}")

spark.streams.addListener(CheckpointMonitor())
```

- `onQueryProgress` が飛ぶ = そのバッチが完了している、というシグナルになります
- **PySpark 3.3 以前は Python 版が無い**（Scala のみ）ので、その場合は②へ

---

## ② `lastProgress` をポーリング（全バージョン対応）

```python
import time, json

q = df.writeStream.option("checkpointLocation", CKPT).start()
last_id = -1

while q.isActive:
    p = q.lastProgress
    if p and p["batchId"] != last_id:
        last_id = p["batchId"]
        log.info(json.dumps(p, ensure_ascii=False))
    time.sleep(30)
```

同じ batchId を出し続けないよう、前回値との比較を入れるのがコツです。

---

## ③ checkpoint ディレクトリを直接突き合わせる（一番確実）

「offsets と commits が揃っているか」を直接見る方法です。定期実行して差分が出たらアラート、という運用ができます。

```python
def max_batch_id(spark, ckpt, sub):
    hadoop = spark._jvm.org.apache.hadoop
    conf   = spark._jsc.hadoopConfiguration()
    path   = hadoop.fs.Path(f"{ckpt}/{sub}")
    fs     = path.getFileSystem(conf)
    ids = [int(f.getPath().getName())
           for f in fs.listStatus(path)
           if f.getPath().getName().isdigit()]
    return max(ids) if ids else -1

off = max_batch_id(spark, CKPT, "offsets")
cmt = max_batch_id(spark, CKPT, "commits")
log.info(f"[CKPT] offsets={off} commits={cmt} gap={off - cmt}")
if off - cmt > 1:
    log.error("⚠️ 未コミットのバッチが滞留しています")
```

> 通常運用では `gap` は 0 か 1（処理中のバッチ）になります。それ以上が続くなら異常です。

---

## ⚠️ ファイルソース固有の注意点

`maxFilesPerTrigger=100` で100件ずつ読む構成だと思いますが、

- `startOffset` / `endOffset` は `{"logOffset": 42}` のような**通し番号だけ**で、「どのファイルを読んだか」は分かりません
- 実際のファイル名は `sources/0/` のメタデータログにあります（既定10バッチごとに `.compact` へ圧縮されます）

**ファイル名レベルで追いたいなら `foreachBatch` の中で出すのが実用的です。**

```python
from pyspark.sql.functions import input_file_name

def write_batch(bdf, batch_id):
    bdf = bdf.withColumn("_src", input_file_name()).cache()
    files = [r._src for r in bdf.select("_src").distinct().collect()]
    log.info(f"[BATCH {batch_id}] files={len(files)} rows={bdf.count()}")
    log.info(f"[BATCH {batch_id}] BEFORE_ES_WRITE")

    bdf.drop("_src").write.format("es").mode("append").save(INDEX)

    log.info(f"[BATCH {batch_id}] AFTER_ES_WRITE")  # ★ここが重要
    bdf.unpersist()

df.writeStream.foreachBatch(write_batch).option("checkpointLocation", CKPT).start()
```

---

## 🔍 重複調査との関係（こちらが本題かもしれません）

Structured Streaming + ES は **at-least-once（最低1回は届くが、2回届くこともある）** です。次の順序で落ちると重複が発生します。

```
1. offsets 書き込み  ✅
2. ES へ書き込み      ✅  ← ここまで成功
3. commits 書き込み  ❌  ← ここで異常終了
4. 再起動 → 同じ batchId を再実行 → ES に丸ごと二重投入
```

data stream への書き込みは上書きが効かないため、この場合は**きれいに2倍**になります。「Spark のログ量が2倍だった」という所見とも整合します。

**次に同じ事象が起きたときに即断できるよう、`batchId` を必ずログに含めておくことを強くおすすめします。** 同じ `batchId` が2回出ていれば、再処理による重複と確定できます。

---

現在の Spark / PySpark のバージョンを教えていただければ、①か②のどちらで組むべきか、より具体的にお伝えできます。
