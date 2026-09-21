# Namaran

> **Code daily. Without assist.**

Namaranは、プログラマーがコードを扱う感覚を鈍らせないための、1日数分のコーディングドリルです。

AIコーディングツールで仕事の生産性は上がった一方、自分の頭と手でコードを読み・書き・直す機会は減りつつあります。Namaranはその数分だけ補助を外して、コードに触れる場所です。上達や競争ではなく、**維持**を目的にしています。

```text
開く → 考える → 答えを見る → 閉じる
```

## 出題

毎日、4言語 × 3種別の12問を公開します。

| 言語 | 対象バージョン |
|---|---|
| C | C23 |
| C++ | C++26 |
| Rust | Rust 2024 edition |
| Haskell | Haskell 2010 |

| 種別 | 内容 |
|---|---|
| READ | コードを頭の中で実行する(何が出力されるか、コンパイルできるか) |
| WRITE | 小さな関数や式を自分で書く(答えは参考実装) |
| DEBUG | 壊れたコードの問題を見つけ、最小限直す |

実行環境・採点・スコア・ランキング・アカウントはありません。意図的に作っていません。過去の問題は日付ごとのアーカイブから読めます。

## 仕組み

サイトは **HTML と CSS だけ**の静的サイトです。ブラウザ向けのJavaScript、ビルド、CMS、データベースは使っていません。Cloudflare Pagesで配信し、日付なしのURL(`/rust/read` など)を最新の公開日のページに解決する部分だけを Pages Functions([functions/_middleware.js](functions/_middleware.js))が担っています。

問題は**AIが毎日作り、人間の承認なしに公開します**。

```text
GitHub Actions(毎日 00:10 JST)
  write   お題を抽選(script/odai.sh)し、Claude Code が namara-daily Skill で12問を書く
  verify  Claudeが触っていない別のランナーで、パッチを検査(script/check-patch.sh)し、
          コンパイル・実行・静的解析で答えを裏付ける(script/verify.sh)
  publish 検査を通ったパッチだけを main に当て、sitemap.xml を作り直して push
        →  Cloudflare Pages が自動デプロイ
```

Claudeが動くジョブは読み取り権限しか持ちません。公開するのは、その出力を検査し直す別のジョブです。

「問題を作る」側はAIを遠慮なく使い、「問題を解く」側だけが補助を外す、という分担です。問題の質は、毎日の人間の判断ではなく、文章として書き出した基準(要件定義・Skill・お題の候補集)と機械的な検証で保ちます。

検証では、ページに載ったコードをそのままコンパイルして確かめます。

| 言語 | ツール |
|---|---|
| C | `gcc-14 -std=c23 -Werror -fanalyzer`、ASan/UBSan付きで実行 |
| C++ | `g++-14 -std=c++26 -Werror`、ASan/UBSan付きで実行 |
| Rust | `clippy-driver --edition 2024 -D warnings` |
| Haskell | `ghc -XHaskell2010 -Wall -Werror`、`hlint` |

READの答えの出力は実際の実行結果と照合し、「コンパイルエラーになる」という答えは実際に失敗することを確かめます。DEBUGの問題文が「いまはこう出力される」と書くときは、壊れたプログラムを実際に動かしてその出力と照合します。

## ディレクトリ構成

```text
index.html, style.css, 404.html, _headers   サイト本体
{c,cpp,rust,haskell}/{read,write,debug}/
  YYYY-MM-DD.html                            日付ごとの問題ページ(公開後は編集しない。ハイライトの付け直しだけは例外)
  archive.html                               その言語・種別の過去問一覧
functions/_middleware.js                     日付なしURLの解決・未来日の404
script/content.sh                            問題ページの雛形生成とアーカイブへの追記
script/verify.sh                             問題ページと検証用ソースの検証
script/highlight.sh                          コードのシンタックスハイライト
script/odai.sh                               お題の抽選
script/check-patch.sh                        公開前のパッチ検査
script/sitemap.sh                            sitemap.xml の生成
sitemap.xml, robots.txt                      生成物と、その場所を示す1行
.claude/skills/namara-daily/                 問題作成の手順(SKILL.md)とお題の候補集(odai.txt)
.github/workflows/                           定期実行ワークフローと sitemap 追随
doc/                                         要件定義・基本設計
```

## 手元で問題を作る

```text
/namara-daily                                  今日の12問を抽選お題で作る
/namara-daily 2026-09-20 rust/debug 所有権の移動  言語・種別・テーマを指定する
```

Skillを使わずに手で書く場合は、次の順です。

```bash
./script/content.sh new 2026-09-20 rust/debug   # 雛形を作り、archive.html に1行追加
# rust/debug/2026-09-20.html の TODO を埋め、検証用ソースを用意する
./script/highlight.sh rust/debug/2026-09-20.html   # コードを直したら再実行
./script/verify.sh 2026-09-20 /path/to/verify-dir rust/debug
```

検証用ソースの置き方(`NAME.ok.rs` / `NAME.ng.rs` / `NAME.bug.rs` / `NAME.stdout`)は [script/verify.sh](script/verify.sh) の冒頭にあります。検証には上の表のツールが必要です。

`sitemap.xml` は公開と同じ手順の中で作られます。手元で作り直すときは `./script/sitemap.sh`、最新かどうかだけ見るときは `./script/sitemap.sh --check` です。

## 定期実行のセットアップ

1. Claude Pro/Max/Team/Enterprise のアカウントで、手元で `claude setup-token` を実行する
2. 表示されたトークンを、リポジトリの Settings → Secrets and variables → Actions に `CLAUDE_CODE_OAUTH_TOKEN` として登録する
3. Actions → **Namaran daily** → Run workflow で試す(日付を指定して過去日の分を作ることもできる)

実行はサブスクリプションの利用枠を使います。使うモデルはワークフロー冒頭の `CLAUDE_MODEL` で変えられます。検証を通らなかった日は何も公開されず、サイトは前回の問題を表示し続けます。

## ドキュメント

- [doc/requirements.md](doc/requirements.md) — 要件定義。Namaranが何をして、何をしないか。良い問題・面白い問題の基準
- [doc/basic-design.md](doc/basic-design.md) — 基本設計。URL設計、HTML規約、運用フロー、自動公開の設計判断
- [.claude/skills/namara-daily/SKILL.md](.claude/skills/namara-daily/SKILL.md) — 問題作成の手順
- [CLAUDE.md](CLAUDE.md) — 対象言語のバージョンと言語仕様リファレンス
