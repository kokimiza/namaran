# Namaran 基本設計書

> 対応する要件定義: [`requirements.md`](./requirements.md)

## 0. 本書の方針

Namaranは静的サイトであり、思想的にも技術的にも「小さいこと」が正しさである。

この設計書は、**とにかく早く動くサイトを作ること**を最優先する。

やらないこと：

* ビルドツール導入
* テンプレートエンジン
* 日替わりロジックの自動化（配信されるサイト側での話。問題を書いて公開する作業側の自動化は §9.2）
* 将来の拡張を見越した抽象化
* ロケール別（`/ja/` `/en/` 等）ディレクトリツリーによる多言語化（§1.5、否定的決定として記録済み）

要件定義 §21 の通り、Namaran本体は「問題がどう追加されたか」を知らない。**存在する静的ファイルを表示するだけ**でよい。「今日の問題」の解決だけは例外的に、Cloudflare Pages Functions（`functions/_middleware.js`、§5.2）が日付を見て機械的にファイルを選ぶ。これは編集判断を含まない決定的なルーティングであり、CMSではない。公開作業（通常は定期実行ワークフロー、§9.2）がやることは「日付つきファイルを1つ追加する」だけで、既存ファイルの上書きは発生しない（§9）。これにより、ブラウザ向けJS・ビルド・CMSを一切使わずにv1が完成する。

---

## 1. 「今日の問題」は12種類同時に存在する

構造上、Namaranには「言語 × 種別」の組み合わせ（4言語 × 3種別 = 12ページ）が常にすべて公開されている。つまり**サイト全体で1日1問**ではなく、

> **12種類の『今日のドリル』が並行して存在し、ユーザーは自分が維持したい言語・種別を1つ選んで触れる**

という設計である。

これは制約ではなく意図した仕様とする。理由：

* Cを普段使わない人に、Cの問題を強制する理由がない
* 「今日はRust/READ、明日はC++/DEBUG」のように、ユーザー自身が対象を選べる方が要件定義 §4 Skill Maintenance の思想に近い
* サイト全体で1つの問題に絞ろうとすると、「言語をどう選ぶか」という新しい決定ロジック（ローテーション、優先度、ランダム等）が必要になり、要件定義 §21 が明確に拒否している複雑さを呼び込む

要件定義 §1 の「1日1問」は、この12ページ構造と矛盾しないよう「1日1問を目安に、自分が維持したい言語・技能の問題へ触れる」という表現に修正済み（`requirements.md` 側を更新した）。

各ページが独立して「今日の問題」を名乗ってよい。ページ間で内容の整合性（同じ日に全ページを揃えて更新する、など）を取る必要はない。更新頻度もページごとにバラついてよい。

各組み合わせは、公開日ごとの固定ページ（アーカイブ）の集まりだけを持つ。「今日の問題」を指す専用ファイルは存在しない——`/c/read` のような日付なしURLは、最新の日付ページを指すエイリアスとしてミドルウェアが解決する。要件定義 §22、本書 §5.2・§7・§9 を参照。

---

## 1.5 ロケール別ディレクトリツリー（多言語化）はしない（否定的決定）

一時期、`/ja/{lang}/{type}/...` と `/en/{lang}/{type}/...` という2本のロケール別ツリーが存在した。**この構成は撤廃し、本書が一貫して前提とする単一の無プレフィックスツリー（`{lang}/{type}/...`、`<html lang="en">` 固定）に統合した。** 再発を防ぐため、判断の経緯をここに残す。

何が起きていたか：

* 問題ページを2ツリー分メンテナンスする必要があり、実際に更新が片方だけに入るドリフトの土壌になっていた（同じ情報を2箇所に置く設計は、置いた箇所の数だけ「更新を忘れる場所」を持つ）
* ルートパス `/` は常にミドルウェアが `Accept-Language` を見て `/ja/` か `/en/` へ302リダイレクトしており、`index.html` 本体（§6）が誰にも表示されない状態になっていた
* さらに古い時代には、ロケールを持たない無プレフィックスツリー（`c/read` 等）が別途存在した時期もあったが、`/ja/` `/en/` の追加後はどこからもリンクされずリンクグラフから孤立し、更新もされないまま放置された末に削除された。この削除自体も理由を記録しないまま行われており、「やらないと決めたことを記録しない」ことの再発コストを体現する事例になっていた

なぜやめたか：

* Namaranは元々「UI文言・問題文は英語で統一する」（§7.1）という単一言語設計だった。ロケール分割は、この前提を崩す複雑さを後から持ち込んだものであり、要件定義 §21 が明確に拒否している「将来の拡張を見越した抽象化」そのものだった
* 到達可能なページ・URLの数が増えることは、レビューすべき対象が増えることと同義である。誰にもリンクされないツリーは、更新もされず、誰の目にも入らないまま存在し続ける
* `/` のロケール判定リダイレクトは、エッジ（信頼境界）で動く `functions/_middleware.js` に、UI利便性のためだけの分岐を持ち込んでいた。ミドルウェアに残すべきなのは静的ファイルでは表現できない分岐（§5.1の未来日404、§5.2の「今日」エイリアス）だけであり、ロケール判定はそれに当たらない

今後の扱い：

* 多言語化そのものを永久に否定するわけではない。ただし再導入する場合は、**手作業のツリー複製ではなく**、単一の英語コンテンツから機械的に多言語版を生成・同期する仕組み（ビルド不要という制約下でなら、少なくともローカルの運用スクリプトによる決定的な変換）を前提に、改めて設計から検討すること
* 旧ロケールツリー（`/ja/*` `/en/*`）および旧 `fix` 型名への外部からの参照は、`functions/_middleware.js` の恒久リダイレクトで単一ツリーへ301誘導する。これはブックマーク・検索エンジンのインデックス保護のためだけの分岐であり、単一ツリー構成そのものには影響しない

---

## 2. 全体アーキテクチャ

```text
Browser
   ↓ HTTPS
Cloudflare Pages（静的ホスティング、ビルドコマンドなし）
   ↓
リポジトリ内の .html / .css ファイルをそのまま配信
```

* サーバーサイド処理なし
* API / DBなし
* クライアントJSなし

---

## 3. セキュリティ方針

### 3.1 前提：攻撃対象領域が構造的に小さい

Namaranには、一般的なWebアプリで問題になりやすい要素が最初から存在しない。

```text
JavaScript        なし
npm依存           なし
フレームワーク     なし
API               なし
DB                なし
ログイン           なし
フォーム送信       なし
ユーザー入力の保存  なし
```

正確に言うと、これは「JSなし＝安全」ということではなく、

> **動的処理を極端に減らした結果、攻撃可能な面がかなり小さい**

という状態である。ユーザー入力をDOMへ差し込む処理がないので一般的なXSSの入口がほぼなく、バックエンドがないのでSQL Injectionもなく、認証がないので認証突破もなく、npm依存がないのでJS依存パッケージ由来のサプライチェーンリスクも大きく減っている。

### 3.2 それでも残るリスク

一番現実的なのは、GitHubアカウントやCloudflareアカウントが乗っ取られ、HTMLそのものを書き換えられることである。これはJSの有無とは無関係で、静的サイトであっても常に残るリスクである（GitHub/Cloudflareアカウントの2段階認証などアカウント保護側で対処する話であり、Namaranのサイト設計そのものでは解決しない）。

また、将来HTMLに外部スクリプトや外部iframeを迂闊に追加すれば、その瞬間に外部依存・攻撃面が増える。そのため、次の原則を明文化する。

```text
外部JS       なし
外部CSS      なし
外部Font     なし
iframe       なし
analytics    なし
広告タグ     なし
```

`style.css` は自ホストの1枚のみ、フォントもシステムフォントのみを使う（§8参照）。これは意匠上の判断であると同時に、外部ホストへのリクエストを一切発生させないというセキュリティ上の判断でもある。

### 3.3 `_headers` によるセキュリティヘッダ

Cloudflare Pagesはリポジトリ直下に `_headers` ファイルを置くだけで、ビルド不要のままレスポンスヘッダを追加できる（[Headers · Cloudflare Pages docs](https://developers.cloudflare.com/pages/configuration/headers/)）。Namaranでは以下を設定する。

```text
/*
  Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'none'; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  Permissions-Policy: camera=(), microphone=(), geolocation=()
```

`default-src 'self'` ではなく `default-src 'none'` を起点にし、実際に使うリソース種別だけを個別に許可する、ホワイトリスト方式を採る。Namaranは画像・favicon・外部/自前を問わずWebフォントを一切使わず(§8、システムフォントのみ)、`style.css` 1枚だけを自ホストから読み込む(§3.2)。そのため明示的に許可が要るのは `style-src 'self'` だけであり、`img-src` / `font-src` / `connect-src` / `media-src` などは指定せず `default-src 'none'` へのフォールバックに任せて閉じたままにする——使っていないリソース種別をあらかじめ `'self'` で開けておくことは、要件定義 §21・本書 §0 が拒否する「将来の拡張を見越した抽象化」に当たる。将来favicon・画像・自前フォント等を追加する時点で、そのときはじめて対応する `-src` を1つ足せばよい。

特に `script-src 'none'` が重要である。これはブラウザに対して「このサイトではJavaScriptの実行自体を許さない」と宣言するものであり、将来だれかが誤って（あるいは意図的に）HTMLに `<script>` を混入させても、ブラウザ側でブロックされる。設計判断を文書に書くだけでなく、ブラウザに強制させるところまでやる。

Cloudflare Pagesはデフォルトでも `X-Content-Type-Options: nosniff` 等の一部ヘッダを付与するが（[Serving Pages](https://developers.cloudflare.com/pages/configuration/serving-pages/)）、`_headers` で明示的に宣言することで、プラットフォームのデフォルト挙動に依存せず意図を固定する。

> **JSを使わないのは高速化・簡素化のためだけでなく、不要な実行能力をブラウザに与えないというセキュリティ上の利点でもある。**

Cloudflare Pagesの配信ルートはリポジトリ直下なので、`doc/`（要件定義書・本設計書）もそのままデプロイされ、クロール可能になる。これは製品コンテンツではないので、`_headers` に `/doc/*` へのパス限定ルールを追加し、`X-Robots-Tag: noindex, nofollow` で検索結果から除外する。アクセス自体は許可したまま、インデックスだけを止める指定である（`robots.txt` は `sitemap.xml` の場所を示すだけで、クロールの許可・禁止は書かない。§9.3）。

---

## 4. ディレクトリ構成

```text
namara/
├── index.html               # ルートページ本体。実コンテンツ（§6）。_redirectsは使わない
├── style.css                 # 全ページ共通スタイル（1枚のみ）
├── _headers                   # Cloudflare Pages のセキュリティヘッダ定義（§3.3）
├── 404.html                   # 存在しないパスに来た人向けの最小ページ
├── functions/
│   └── _middleware.js         # 日付つきURLの入口判定・「今日」エイリアスの解決（§5.2）
├── c/
│   ├── read/
│   │   ├── 2026-08-21.html     # 公開日ごとに増えるアーカイブ（1日1ファイル、公開後は編集しない。例外は§9.4）
│   │   └── archive.html        # 全日付への一覧（§7.1a）。新しい日を公開するたびに1行だけ編集する唯一の例外
│   ├── write/
│   │   └── 2026-08-21.html
│   └── debug/
│       └── 2026-08-21.html
├── cpp/                       # 同じパターン（read/ / write/ / debug/）
├── rust/                      # 同じパターン
├── haskell/                   # 同じパターン
├── script/
│   ├── content.sh              # ローカル運用スクリプト（§9.1）。サイトには配信されない
│   ├── template.html           # 雛形生成元のテンプレート
│   ├── verify.sh               # 問題ページと検証用ソースの検証（§9.2）
│   ├── highlight.sh            # コードのシンタックスハイライト（§9.4）
│   ├── check-patch.sh          # 公開前のパッチ検査（§9.2）
│   ├── odai.sh                 # odai.txt からの言語ごとのお題抽選（§9.2）
│   └── sitemap.sh              # sitemap.xml の生成（§9.3）
├── sitemap.xml                 # 生成物。問題と同じcommitで更新される（§9.3）
├── robots.txt                  # sitemap.xml の場所を示すだけの1行（§9.3）
├── .github/
│   ├── workflows/
│   │   ├── namara-daily.yml    # 定期実行による問題の作成・検証・公開（§9.2）
│   │   └── sitemap.yml         # 手動push後などの sitemap.xml 追随（§9.3）
│   ├── actions/toolchains/     # 検証用ツールチェーンのセットアップ（composite action）
│   └── dependabot.yml          # SHA固定したActionsの更新提案
├── .claude/skills/namara-daily/
│   ├── SKILL.md                # 問題作成の手順（Claude Code Skill）
│   └── odai.txt                # お題の候補集
└── doc/
    ├── requirements.md
    └── basic-design.md
```

`{lang}/{type}.html` のような日付なしファイルは存在しない。`read/`・`write/`・`debug/` ディレクトリも、最初のアーカイブが作られるまでは存在せず、1日目にアーカイブを作った時点で生まれる。

---

## 5. URL設計（ファイルパスとURLの対応）

Cloudflare Pagesは `.html` 拡張子付きのURLへアクセスがあった場合、拡張子なしのURLへ自動的にリダイレクトする（[Serving Pages](https://developers.cloudflare.com/pages/configuration/serving-pages/)）。つまり `rust/debug.html` というファイルを置いても、最終的に生きるURLは `/rust/debug` になる。アーカイブページも同じ規則に従う。

したがって：

* **ファイルは `.html` 拡張子付きのまま置く**（エディタでの編集しやすさを優先。ファイル名変更は不要）
* **HTML内のリンク（`<a href="...">`）は最初から拡張子なしで書く**
* **日付ファイル名は `YYYY-MM-DD.html`（ISO 8601）で統一する**。辞書順に並べればそのまま時系列順になり、ソートのための特別なロジックが要らない

対応表（例）：

| ファイル | 公開URL |
|---|---|
| `index.html` | `/` |
| `c/read/2026-08-20.html` | `/c/read/2026-08-20` |
| `c/read/2026-08-21.html` | `/c/read/2026-08-21` |
| （`c/read.html` のようなファイルは存在しない） | `/c/read` ← §5.2のエイリアスで解決 |
| `c/read/archive.html` | `/c/read/archive`（全日付への一覧、§7.1a） |

（`write` / `debug` および他の3言語も同じパターン。日付つきアーカイブは各組み合わせにつき公開日の数だけ増えていく。`archive` は日付の正規表現にもマッチしないため、§5.1・§5.2 のミドルウェア判定はそのまま素通りし、他の静的ファイルと同じ経路で配信される。）

### 5.1 未来日URLの扱い

アーカイブは常に「今日以前」の日付しか作らない。未来日のURL（例: `/c/read/2099-01-01`）を直接叩かれた場合も、静的ファイルの有無にかかわらず404にする。

ページ1枚ごとに判定コードを書くのではなく、Cloudflare Pages Functionsの `functions/_middleware.js` で全リクエストの入り口を一括判定する。

```text
Request
   ↓
functions/_middleware.js（日付を見て、未来日なら404を返す）
   ↓ 問題なければ context.next()
静的HTML配信（今まで通り）
```

### 5.2 「今日」エイリアス（日付なしURL）

`/c/read` のような日付なしURLには、対応する静的ファイルが存在しない。代わりに `functions/_middleware.js` が、そのURLへのリクエストを「そのlang/typeで最新に公開されている日付ページ」の内容にすり替えて返す。

```text
GET /c/read
   ↓
functions/_middleware.js が c/read/archive.html を取得し、
先頭の <li> から最新の公開日 2026-08-21 を読み取る
   ↓
env.ASSETS.fetch("/c/read/2026-08-21") を取得し、そのままレスポンスとして返す
   （URLバーは /c/read のまま。リダイレクトではなく透過的な差し替え）
```

これにより、新しい日の問題を公開する作業は「日付つきファイルを1つ追加するだけ」になる（§9）。以前のように「今日ページ」を毎回上書きし、その直前の内容をアーカイブへコピー＆リネームする、という手順は不要になった。アーカイブページ自身の `<link rel="canonical">` は常に日付つきURLを指す（§7）ため、`/c/read` と `/c/read/2026-08-21` が同一内容を返しても検索エンジンからは重複コンテンツとして扱われない。

**「最新の公開日」は時計から計算するのではなく、`{lang}/{type}/archive.html` の先頭行から読み取る。** 以前は `today = Asia/Tokyoの現在日` を計算し、そのものずばりの日付ファイルだけを取りに行っていた。これだと、日付が変わった直後(例: 深夜0時1分)にまだその日の問題を公開していないと、前日まで確かに存在していたページが突然404になってしまう——読んでいる途中の人にとっては「さっきまであった今日の問題が消えた」ように見え、公開作業のタイミング(ワークフローがいつ起動し、いつ`script/content.sh new`を実行するか)がそのまま読者側の体験に漏れ出てしまう問題があった。archive.htmlは§7.1aの運用により常に先頭が最新の公開日なので、そこを参照すれば、公開作業が完了するまでは前回公開分がそのまま表示され続け、体験上の空白期間が生まれない。ミドルウェアが読みに行くのはarchive.htmlというすでに存在する1つの静的ファイルだけであり、新しい状態(「最新の日付はいつか」)を別途どこかに持たせる必要はない——archive.html自身がその一次情報源であることに変わりはない(§7.1a)。

未来日を返してしまうことだけは避ける。archive.htmlの先頭日付は通常は今日以前のはずだが(§9のフローでは`script/content.sh`が今日以前の日付しか書かない)、念のためミドルウェアは読み取った日付が今日より先ならエイリアスも404にする——直接の日付つきURL(§5.1)と同じ「未来日は出さない」というルールをここでも一貫させるためのガードであり、通常運用では発火しない。

そのlang/typeが1度も公開されていない(archive.htmlに`<li>`が1つも無い、あるいはarchive.html自体が存在しない)場合は、これまで通り404になる。「今日の問題が見えなくなる」事態そのものを防ぐのは、あくまで運用側(定期実行ワークフローが毎日公開に成功する)の責務であることは変わらない——ミドルウェアが直すのは「公開自体は済んでいるのに、日付が変わった一瞬だけ見えなくなる」という時計とのズレだけであり、「公開そのものを忘れている」ケースまで肩代わりするものではない。

これはCloudflareのエッジ（サーバー側）で動くコードであり、ブラウザに配信されるJSではない。したがって `_headers` の `script-src 'none'`（§3.3）とは無関係で、矛盾しない。**ブラウザにJSの実行能力を渡さない、という方針はこの先も変わらない。**

---

## 6. ルートページ（`/`）と `404.html`

以前の設計では、Cloudflare Pagesの `_redirects` を使って `/` を `/c/read` へ転送していた。**これはやめる。**

理由：

* リダイレクトだけのページは検索エンジンにとって実質空白であり、「Namaran」という名前や考え方そのもので見つけてもらう機会を捨てることになる
* 「今日の問題」はもともと12種類同時に存在する（§1）。`/c/read` を特別扱いしてデフォルトにする必然性は薄かった
* トップページに実コンテンツを置いたほうが、初めて来た人に「これは何のサイトか」を説明できる

`index.html` は、次の要素を持つ独立したページとする。

1. header（サイト名・タグライン）— 他ページと共通
2. 短い説明文（Namaranが何か、何をしないか。要件定義 §1〜§3 の要約）
3. 言語 × 種別への案内（4言語 × 3種別、12リンク）
4. footer

具体例（プレースホルダーではなく、そのまま使える文章として書いた）：

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="description" content="Namaran is a one-question-a-day coding drill in C, C++, Rust, and Haskell — for programmers who want to keep reading, writing, and fixing code by hand.">
<title>Namaran — Code daily. Without assist.</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div class="wrap">

<header class="masthead">
  <h1>Namaran</h1>
  <p class="tagline">Code daily. Without assist.</p>
</header>

<p class="lede">
  Namaran is a one-question-a-day coding drill for programmers who already know how to code, and want to make sure they still can.
</p>

<p>
  No compiler, no login, no score. Pick a language and an exercise type below, read a small piece of code, and see if you still reach the answer without help.
</p>

<section class="guide">
  <h2>Choose a drill</h2>
  <p><strong>C</strong> &mdash; <a href="/c/read">READ</a> &middot; <a href="/c/write">WRITE</a> &middot; <a href="/c/debug">DEBUG</a></p>
  <p><strong>C++</strong> &mdash; <a href="/cpp/read">READ</a> &middot; <a href="/cpp/write">WRITE</a> &middot; <a href="/cpp/debug">DEBUG</a></p>
  <p><strong>Rust</strong> &mdash; <a href="/rust/read">READ</a> &middot; <a href="/rust/write">WRITE</a> &middot; <a href="/rust/debug">DEBUG</a></p>
  <p><strong>Haskell</strong> &mdash; <a href="/haskell/read">READ</a> &middot; <a href="/haskell/write">WRITE</a> &middot; <a href="/haskell/debug">DEBUG</a></p>
</section>

<footer>
  <p>A daily maintenance routine for programmers.</p>
</footer>

</div>
</body>
</html>
```

以前は「`_redirects` が先に効くのでほぼ誰も見ない」という位置づけだったが、`_redirects` 自体をやめたので、`404.html` は純粋に「存在しないパスに来た人向け」の実用ページになる。

見た目は既存のコンポーネント（`.code-frame` / `pre.code` / `.question`）をそのまま流用し、コンパイラのエラー出力ふうに組む。新しいCSSは増やさない。

```html
<main>
  <h2>404</h2>

  <div class="code-frame">
    <p class="code-filename">not_found</p>
    <pre class="code"><code>error: page not found
 --&gt; the path you followed
  |
  = note: no such route in this crate
</code></pre>
  </div>

  <p class="question">
    That page doesn't exist. It may have moved, or never did.
  </p>

  <p><a href="/">&larr; Back to Namaran</a></p>
</main>
```

`.wrap` を使う（`.page` ではない）。404ページは特定の言語・種別に属さないため、nav も past ペインも持たない。

---

## 7. HTMLページ規約

### 7.1 問題ページ（例: `c/read/2026-08-21.html`）

問題ページは常に日付つきで、公開したら二度と編集しない（唯一の例外は §9.4 のハイライトの付け直しで、読者に見える文字列は変わらないことをスクリプト自身が保証する）。「今日ページ」という別種のファイルは存在しない——`/c/read` への日付なしアクセスは、ミドルウェアが最新の日付ページを差し替えて返すエイリアスである（§5.2）。そのため、ここで書く規約が全ての問題ページに一律で適用される。

構成要素の順番：

1. header（サイト名・タグライン）
2. language navigation
3. exercise navigation
4. code（ウィンドウ風の枠。タイトルバー中央にお題に沿ったファイル名を置く）
5. question
6. details（Answer / Reference）
7. past（他の日付へのリンク。まだ他になければ `Today` リンクだけになる）
8. footer

具体例：

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Namaran — C / READ — 2026-08-21</title>
<link rel="canonical" href="https://namara.jocarium.productions/c/read/2026-08-21">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div class="page">

<header class="masthead">
  <h1><a href="/">Namaran</a></h1>
  <p class="tagline">Code daily. Without assist.</p>
</header>

<nav class="lang-nav" aria-label="Language">
  <a href="/c/read/2026-08-21" class="active" aria-current="page">C</a>
  <a href="/cpp/read/2026-08-21">C++</a>
  <a href="/rust/read/2026-08-21">Rust</a>
  <a href="/haskell/read/2026-08-21">Haskell</a>
</nav>

<nav class="type-nav" aria-label="Exercise type">
  <a href="/c/read/2026-08-21" class="active" aria-current="page">READ</a>
  <a href="/c/write/2026-08-21">WRITE</a>
  <a href="/c/debug/2026-08-21">DEBUG</a>
</nav>

<main>
  <h2>2026-08-21</h2>

  <div class="code-frame">
    <p class="code-filename">compare.c</p>
    <pre class="code"><code>&lt;!-- ここにコード。&lt; &gt; &amp; は必ずHTMLエスケープする --&gt;
</code></pre>
  </div>

  <p class="question">
    ここに問い（例: 「この式は何に評価されるか」）
  </p>

  <details class="answer">
    <summary>Answer</summary>
    <p>ここに答えと最小限の解説</p>
  </details>
</main>

<aside class="past">
  <h2>Past</h2>
  <ul class="past-list">
    <li><a href="/c/read">Today</a></li>
    <li><a href="/c/read/archive">Archive</a></li>
  </ul>
</aside>

<footer>
  <p>A daily maintenance routine for programmers.</p>
</footer>

</div>
</body>
</html>
```

`<body>` 直下は `<div class="wrap">` ではなく `<div class="page">` を使う。`.page` はCSS Gridで「本体（header / nav / main / footer）＋ 右側のPastペイン」の2カラムを組む。52rem未満の画面では自動的に1カラムへ積み上がる（`main`の次に`past`、その次に`footer`という順）。これは要件定義 §18 のUIモックアップに、日付をクリックするとその日の問題が読める仕組みを足したもので、JSは使わない（CSS Gridのみ）。詳細は §8 を参照。

ルール：

* `<title>` は `Namaran — {言語} / {種別} — {日付}` に統一
* `<h2>` はその日付そのもの（例: `2026-08-21`）にする。何の問題かは nav・title・code-filename で分かるので、見出しは「いつのものか」を示せば十分
* `<html lang="en">` を使う（UI文言・問題文は英語で統一しているため）
* masthead の `<h1>` は `/`（ルートページ）へリンクする
* リンクはすべて拡張子なし（§5）。日付なしURL（`/c/read` 等）へのリンクは、書いた時点でその日の内容そのものを指しているわけではなく、常に「そのとき最新」を指すという点を意識する
* `lang-nav` / `type-nav` は同じ日付を保ったまま言語・種別だけを切り替える（例: `/c/write/2026-08-21` → `/rust/write/2026-08-21`）。現在地のリンクにだけ `class="active"` と `aria-current="page"` を手動で付ける
* コードは `<div class="code-frame">` で囲み、直下の `<p class="code-filename">` にお題に沿ったファイル名を、対象言語の命名規則で書く（C/C++/Rustはsnake_case、Haskellはモジュール名慣習のPascalCase）。以前あった `<p class="path">/* c/read */</p>` のようなコメント演出は廃止した
* WRITEページは `<summary>Answer</summary>` を `<summary>Reference</summary>` に変える（要件定義 §9 WRITEの節）
* コード内の `<` `>` `&` は `&lt;` `&gt;` `&amp;` に置換してから貼る
* コードを貼ったら `script/highlight.sh` でシンタックスハイライトを付ける（§9.4）。`<pre class="code"><code>` の中に置いてよいマークアップは、このスクリプトが書く `<span class="…">` だけで、手では書かない
* `past-list` は常に2行固定：`Today` リンク（日付なしURL）と `Archive` リンク（`/{lang}/{type}/archive`、§7.1a）。日付を直接列挙しない。これにより **この2行はどの日付のページでも同じ内容になり、公開後のページは本当に一度も編集しない**（旧版は全過去日付を降順で列挙しており、新しい日を公開するたびに既存アーカイブ全ページの編集が必要だった。§7.1a 参照）

### 7.1a アーカイブ一覧ページ（例: `c/read/archive.html`）

`{lang}/{type}` の組み合わせごとに1枚、その組み合わせの全アーカイブ日付を新しい順に列挙するページを置く（4言語 × 3種別 = 12枚）。日付ページからは `past-list` の `Archive` リンクでここへ来る。

構成要素は日付ページ（§7.1）とほぼ同じだが、次の点が異なる：

* `<main>` の中身は `code-frame` / `question` / `answer` ではなく、`<h2>Archive</h2>` と `past-list` 形式の `<ul>` のみ（`.past-list` はスコープなしのクラスなので `<aside>` の外でもそのまま使える。追加CSSは不要）
* この `<ul>` が全日付の一覧そのものなので、ページ自身は `<aside class="past">` を持たない（`.page:not(:has(.past))` により自動で1カラムへ戻る。§8）
* `lang-nav` / `type-nav` は日付を保持できないので、兄弟の archive ページ（例: `/rust/read/archive`）へリンクする
* JSON-LDは `BreadcrumbList` のみとし、`TechArticle` / `LearningResource` は付けない（ドリル本体ではなく索引のため）
* `<title>` は `Namaran — {言語} / {種別} — Archive`、`<h2>` は `Archive`

具体例：

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="description" content="Every past Namaran C READ drill, archived by date.">
<title>Namaran — C / READ — Archive</title>
<link rel="canonical" href="https://namara.jocarium.productions/c/read/archive">
<link rel="stylesheet" href="/style.css">
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  "itemListElement": [
    { "@type": "ListItem", "position": 1, "name": "Namaran", "item": "https://namara.jocarium.productions/" },
    { "@type": "ListItem", "position": 2, "name": "C / READ", "item": "https://namara.jocarium.productions/c/read" },
    { "@type": "ListItem", "position": 3, "name": "Archive" }
  ]
}
</script>
</head>
<body>
<div class="page">

<header class="masthead">
  <h1><a href="/">Namaran</a></h1>
  <p class="tagline">Code daily. Without assist.</p>
</header>

<nav class="lang-nav" aria-label="Language">
  <a href="/c/read/archive" class="active" aria-current="page">C</a>
  <a href="/cpp/read/archive">C++</a>
  <a href="/rust/read/archive">Rust</a>
  <a href="/haskell/read/archive">Haskell</a>
</nav>

<nav class="type-nav" aria-label="Exercise type">
  <a href="/c/read/archive" class="active" aria-current="page">READ</a>
  <a href="/c/write/archive">WRITE</a>
  <a href="/c/debug/archive">DEBUG</a>
</nav>

<main>
  <h2>Archive</h2>
  <ul class="past-list">
    <li><a href="/c/read/2026-08-21">2026-08-21</a></li>
    <li><a href="/c/read/2026-08-20">2026-08-20</a></li>
  </ul>
</main>

<footer>
  <p>A daily maintenance routine for programmers.</p>
  <p><a href="https://github.com/kokimiza/namara/issues">Spot a mistake? Fix it on GitHub.</a></p>
</footer>

</div>
</body>
</html>
```

新しい日を公開するたびに触るのはこのファイル**だけ**（対応する `{lang}/{type}` の archive.html 1枚に、新しい日付の `<li>` を先頭へ1行足す）。**これが「公開後は編集しない」の唯一かつ明示的な例外である。** それ以外の（日付つきの）アーカイブページは、公開後は本当に一度も編集されない。

> **原則：ページ間のHTML重複は意図的に許容する。** 12ページ間の重複（既出）に加えて、日付ページどうしの構造重複も同様に許容する。重複除去のためだけにビルド処理・テンプレートエンジン・JavaScriptを導入しない。

### 7.2 ルートページ（`index.html`）

§6 を参照。他の12ページと同じ `header` / `footer` は流用するが、`nav`（lang-nav / type-nav）は持たない。ルートページ自体はどの言語・種別にも属さないため。

---

## 8. スタイル設計（`style.css`）

優先順位は要件定義 §19 の通り：①コード可読性 → ②問題文可読性 → ③答え可読性 → ④モバイル → ⑤ブランド。

方針だけ決め、細部は実装時に詰める：

* 書体は役割で分ける：読む文章はセリフ（Georgia系、日本語は明朝系を続けて指定し、段落の中でゴシックが混ざらないようにする）、ラベルはシステムのサンセリフ、データ（日付・ファイル名・言語版・コード）は等幅。外部フォント読み込みはしない（§3.2）
* 配色は1つの固定テーマで、ライト/ダークの切り替えはしない。切り替えUIにはクライアントJSが要り（§3.3）、OS設定への追従だけでは読者が選べないためである。ページ本体は明るい暖色の紙、コードとフッターは寒色の暗い面にし、機械の出力とそれ以外を色面で分ける
* 余白は5段のスケール（0.5 / 1 / 2 / 3.5 / 6rem）だけを使い、段ごとに意味を固定する。各段の意味と「余白は下側の要素が持つ」という規則は `style.css` 冒頭のコメントにある
* `pre.code` はウィンドウ風にする：タイトルバーに3つのライトとファイル名。バーは背景で描き、要素は増やさない（公開済みページのマークアップはそのまま）。横スクロール可（`overflow-x: auto`）、折り返さない
* シンタックスハイライトは `script/highlight.sh`（§9.4）が書いた `<span>` のクラスに色を当てるだけ。トークン色は、背景に対して5:1以上のコントラストを保つ
* ルートページ・404ページ（`.wrap`）は1カラム、`max-width: 36rem` の中央寄せコンテナ
* 問題ページ（`.page`）は `max-width: 58rem`。CSS GridでPastペインを右側に置く。52rem未満の画面では自動的に1カラムへ積み上がる（「PC用CSSとモバイル用CSSを分ける」のではなく、2カラムという構造そのものが狭い画面には物理的に収まらないための、機能上必要な分岐）
* Pastペインが存在しない（アーカイブが1件もない）ページは、CSSの `:has()` で検知して自動的に1カラムへ戻す。HTML側で場合分けを書く必要はない
* アニメーション・トランジションなし
* ページ本体の色数は絞る（背景・文字・アクセント1色程度）。コード内のトークン色だけは例外
* `nav a.active` はインク色とアクセント色の下線で示す

ファイル冒頭には最小限のリセットを置く（`box-sizing: border-box`と、実際に使っている要素——`html` / `body` / `h1` / `h2` / `p`——の余白ゼロのみ）。Namaranのページに存在しない要素（画像・table・フォーム・リスト等）のリセットは書かない。将来使うかもしれない要素への予防的なリセットはしない。リセットは汎用部分として先頭にまとめ、Namaran固有のトークン適用（背景色・文字色・フォント）はその直後の「Base」セクションに分離する。

`past`（問題ページ）や `guide`（ルートページ）のセクションは、`h2` / `p` / `a` / `strong` の範囲に収まる。新しい要素（画像・リスト・テーブル等）を増やさずに書けるため、追加のリセットは不要。

CSSファイルは1枚のみとし、ページ側の `<link>` は共通で `/style.css` を指す。

---

## 9. コンテンツ運用フロー

```text
1. 問題を作る（言語・種別・code・question・answerを決める）
2. script/content.sh new を実行し、{lang}/{type}/{今日の日付}.html の雛形（§7.1の構造そのまま、
   code/question/answerはTODOプレースホルダー）を作らせ、対応する archive.html（§7.1a）にも
   同時に1行追加させる（例: script/content.sh new 2026-08-25 c/read）
   - TODOになっている code / question / answer を埋める
   - code-filename にお題に沿ったファイル名（対象言語の命名規則）を書く
   - コードは HTML エスケープし、script/highlight.sh でハイライトを付ける（§9.4）
   - script/verify.sh で、ページの形式と、コードの挙動（コンパイル・実行・静的解析）を検証する
3. git commit
4. git push
5. Cloudflare Pages が自動デプロイ
```

通常、この1〜5は人間の操作なしに毎日自動で行われる（§9.2）。問題の中身を書くのはAI（Claude Code、namara-daily Skill）で、何を今日の一問にするかは要件定義 §11・§24 の基準に沿ってAIが判断する。手元でSkillを使って同じ手順を踏むこともできる。

`script/content.sh`（§9.1）はローカル・CI共通の運用スクリプトであり、デプロイされるサイトの一部ではない——毎日同じnav・JSON-LD・footerをコピペする作業を機械的な処理に置き換えているだけで、code/question/answerの中身は作らない。中身を書くのはSkillの役割であり、スクリプトとの間の境界はTODOプレースホルダーである。

「今日ページ」という別ファイルは存在しないため、上書きするファイルは無い。手順2で新規作成したファイルは、以後二度と編集しない。`/c/read` のような日付なしURLは、ミドルウェア（§5.2）が常に最新の日付ページへ自動的に解決するので、公開のたびに触るのは「新しい日付のファイルを1つ追加する」ことと「対応する archive.html 1枚に1行足す」ことだけになる——過去日の日付ページ自体は増えても触らない（§7.1a）。

### 9.1 `script/content.sh`（運用スクリプト）

```text
script/content.sh new  [DATE] [LANG/TYPE ...]   # 雛形生成 + archive.html への追記
script/content.sh undo [DATE] [LANG/TYPE ...]   # その取り消し
```

* `DATE`省略時はAsia/Tokyoの今日（`functions/_middleware.js`の`todayInJapan()`と同じ基準）。`LANG/TYPE`省略時は12組全部が対象
* `new`は`script/template.html`から雛形を生成する。既存の日付付きファイルは上書きしない（公開後は編集しないという方針、§7.1と同じ理由）。archive.htmlに同じ日付の行がすでにあれば追記しない——何度実行しても安全（冪等）
* `undo`は`new`の逆で、生成したファイルとarchive.htmlの行を削除する。ただし安全装置として、ファイルの中に`TODO:`が1つも残っていない（＝すでに中身を書き始めている）場合は削除を拒否し、手動での判断に委ねる
* このスクリプト自身はCloudflare Pages上では一切動かない。配信されるのはこれまで通り生成済みの静的HTMLだけであり、「配信されるものを単純に保つ」ことと「それを作る手元の作業を自動化する」ことは別レイヤーの話である

### 9.2 定期実行による自動公開（`.github/workflows/namara-daily.yml`）

§9の手順1〜4（問題を作る・雛形を埋める・commit・push）を、GitHub Actionsの定期実行（毎日00:10 JST、手動実行も可）でClaude Codeに行わせる。§9.1と同じく作業側のレイヤーの自動化であり、配信されるサイトは何も変わらない——Cloudflare Pagesから見れば、これまで通り日付つきファイルが追加されたpushが1つ届くだけである。

```text
write ジョブ（読み取り権限のみ。Claudeが任意のコマンドを実行できるので、以降は信用しない）
  1. その日の日付ページがまだ無い組を調べる（公開済みの組には触らない）
  2. script/odai.sh が odai.txt から言語ごとにお題を1つ抽選する
  3. Claude Code が namara-daily Skill でページを書き、検証用ソースを置く
  4. 差分をパッチにし、検証用ソースと一緒に受け渡す
verify ジョブ（読み取り権限のみ。Claudeが触っていない新しいランナー。シークレットなし）
  5. script/check-patch.sh: パッチが変更してよいファイルと中身の形かを確認する
  6. パッチを当て、script/verify.sh（ゲート）でコンパイル・静的解析・実行結果・ハイライトを確認する
publish ジョブ（書き込み権限。Claudeも問題のコードも動かさない）
  7. パッチを再度 check-patch.sh にかけ、最新の main に日付ページを当てる
  8. archive.html の行は content.sh で入れ直し、sitemap.sh で sitemap.xml を作り直す
  9. commit・push → Cloudflare Pages が自動デプロイ（§9 の手順5）
```

設計上の判断：

* **外部のActionはコミットSHAで固定する。** タグは同じ名前のまま中身が変わりうる。更新は `.github/dependabot.yml` がPRで提案する。ワークフローの既定の権限は `permissions: {}` とし、ジョブごとに必要な分だけ与える
* **お題の抽選はスクリプトで行う。** モデルに「ランダムに選んで」と頼んでも実際にはランダムにならず、何を選んだかも後から追えない。`script/odai.sh` が抽選し、結果はワークフローのログとコミットメッセージに残る。odai.txtのラベルは言語名だけを見てバージョン部分は解釈しないので、言語標準の更新（CLAUDE.md）でodai.txtを書き換える必要はない
* **検証は、Claudeが動いたのとは別のランナーで行う。** Claudeは自分のジョブの中では何でも実行できるため、同じジョブの後続ステップ（`$GITHUB_ENV` への書き込みなど）にも手が届く。同じジョブで検証しても「検証したことにする」ことが可能になってしまうので、`verify` ジョブを分け、Claudeが一度も触っていない環境で `script/verify.sh` を走らせる。公開の条件になるのはその結果だけである。検証用ソースの規約（ok/ng/bug/stdout）とツールの設定は `script/verify.sh` の冒頭と namara-daily Skill §4 にある。ページに載ったコードの各行が検証用ソースに含まれていることも確認するので、「検証したコード」と「掲載したコード」がずれない
* **パッチの中身を、パッチでは変えられないコードで検査する。** `script/check-patch.sh` は「変更してよいのは対象日の新規ページと archive.html の追記だけ」「ページに `<script>`（JSON-LDを除く）・イベント属性・外部リンク・iframe等の動く要素が無い」ことを確認する。`verify` と `publish` はこのスクリプトを、パッチではなく自分の main のチェックアウトから実行する。CSPが同じものをブラウザ側でも止めるが（§3.3）、そもそも公開しない
* **Claudeには公開の権限を渡さない。** Claudeが動くジョブのトークンは読み取り専用で、入力はこのリポジトリ自身のファイルだけである。pushするのは、検査と検証を通ったパッチだけを受け取る別ジョブである。Bashのコマンドは許可リストで絞らない——問題を書くには自分で書いたコードをコンパイルして実行する必要があり（`verify.sh`もそれを実行する）、コマンド名のリストでは実行されるコードの中身を制限できないうえ、必要なコマンドが拒否されるとClaudeが作業を途中でやめてしまう（初回の実行で実際に起きた）。予定外のファイルが変わっていれば何も公開しない
* **サブエージェントを使わせない。** 非対話実行ではメインのターンが終わるとプロセスごと終了し、バックグラウンドのサブエージェントも打ち切られる。2026-09-17の実行では12問をサブエージェントに任せたまま「完了を待つ」とターンを終え、雛形しか残らなかった。ワークフローで `Agent` ツールを無効にし、Skillにも順番に書き切ってから報告するよう書いてある。パッケージ手順も、予定のページが1つでも欠けていればその場で失敗する（欠けたまま渡すと、check-patch.sh では「pages missing」としか言えない）
* **公開済みページを上書きしない（§7.1）。** 作るのはその日の日付ページがまだ無い組だけで、publish時に同じ日付のページが main に現れていればパッチの適用に失敗して止まる。archive.html の行だけはパッチから取らずに `content.sh` で入れ直すので、生成中に誰かが手で別の日を公開していても、一覧は日付順のまま衝突しない
* **人間の承認を待たない。** 検証を通った問題はそのまま公開する（要件定義 §21・§24）。PRを作って人がマージする形にはしない——承認待ちを挟むと、承認する人がいない日に「今日の問題」が止まり、毎日触れるという目的（要件定義 §1）が人の都合に左右されるからである
* 失敗した日は何も公開されず、`/c/read` などのエイリアスは前回の公開分を表示し続ける（§5.2）。その日の分は、ワークフローを日付指定で手動実行するか、手元でSkillを使って作ればよい

問題の良し悪しの判断（要件定義 §24）は、Skillと設計書に書かれた基準・odai.txt のお題・検証ゲートとして事前に固定されており、AIが毎日それに沿って判断する。基準に照らして問題の質が足りない回が出たら、個々のページを直すのではなく（公開後は編集しない）、要件定義・Skill・odai.txt・検証の方を直す。

### 9.3 `sitemap.xml` の生成（`script/sitemap.sh`）

`sitemap.xml` は静的ファイルとして生成し、問題と同じcommitで公開する。載せるのは正規URLだけ——ルートページ、各 `archive` ページ、公開済みの日付ページである。日付なしのエイリアス（`/c/read`）は、日付ページのバイト列をそのまま返し `canonical` も日付URLを指すので載せない。未来日の日付ページも、ミドルウェアが404を返す以上（§5.1）載せない。

生成する場所は3か所ある。いずれも `script/sitemap.sh` を呼ぶだけで、出力は「リポジトリの中身」と「Asia/Tokyoの今日」だけで決まるので、同じ状態なら何度実行しても差分は出ない。

* 日次の `publish` ジョブ（§9.2）——問題と同じcommitに入る
* `.github/workflows/sitemap.yml`——手でpushした場合と、公開時に未来日だったページがその日を迎えた場合のために、pushとスケジュールで走る。変更があるときだけcommitする
* 手元での `./script/sitemap.sh`（`--check` で最新かどうかだけ確かめられる）

**ミドルウェアで動的に生成しない。** 理由はセキュリティと可用性である。`/sitemap.xml` は誰でも叩ける公開エンドポイントで、リクエストのたびに12枚の `archive.html` を読んでXMLを組み立てることになる。1リクエストが十数リクエストに増幅されるので、無料枠のあるFunctionsでは負荷をかける側にとって都合がよく、枠を使い切れば「今日」エイリアス（§5.2）まで巻き添えで止まる。静的ファイルなら、配信時に動くコードは1行も増えず、生成物の中身も生成の時点で確定している。これは§3「攻撃対象領域を構造的に小さく保つ」の延長である。

生成側でも、読み取った文字列をそのままXMLに書き出すことはしない。言語・種別は固定のリスト、日付は `YYYY-MM-DD` として妥当で実在するファイルのものだけを使う。`archive.html` に何が書かれていても、出力はこの3種類のURLの形にしかならない。

`sitemap.xml` の上限は5万URLで、1日12ページのペースなら10年以上先である。

新しい言語・種別を追加することは v1 の想定に含まれない（要件定義 §8 で4言語固定、§9 で3種別固定）。

### 9.4 シンタックスハイライト（`script/highlight.sh`）

```text
script/highlight.sh [--check] FILE ...
```

問題ページの `<pre class="code"><code>` を字句解析し、トークンを `<span class="kw">` のようなクラス付きの `<span>` で包んで、ファイルをその場で書き換える。色は `style.css` 側で当てる。

* **ブラウザでは色付けしない。** クライアントJSはCSPで禁止している（§3.3）。ハイライトは書く側の作業として行い、結果の静的HTMLをcommitする。`content.sh` と同じ「作業側の自動化」で、ビルドツールではない——配信時に動くものも、デプロイ前に走る変換も増えない
* **何度実行しても同じ結果になる。** 既存の `<span>` を剥がしてから解析し直すので、コードを直したあとも、ハイライト済みのページに対しても、そのまま再実行すればよい
* **見える文字列は変えない。** ブロックごとに「spanを除き、実体参照を戻した文字列」が前後で同一であることをスクリプト自身が確認し、違えば書き込まずに止まる。出力でエスケープするのは `<` `>` `&` だけ（§7.1の規約と同じ）
* **公開の条件にする。** `script/verify.sh` は `--check` で、ページのハイライトがこのスクリプトの出力どおりかを確認する。ハイライトし忘れたページや、spanを手で書き換えたページは公開されない。`check-patch.sh` の許可リストは元から `<span class>` を含むので変更していない
* **字句解析は小さく、隅では間違える。** 言語ごとに正規表現数十行で、ネストしたブロックコメントやC++の文脈依存キーワードは扱わない。間違えたときに起きるのは「色が違う」ことだけで、文字列は変わらない

**公開後は編集しない（§7.1）の例外。** ハイライトは2026-09-16に導入し、その時点で公開済みだった全ページに一度だけ適用した。変わったのは `<pre class="code">` の中のマークアップだけで、各ページから span を除いたものは3ページを除き元のファイルとバイト単位で一致した。残る3ページは、元のHTMLが `&&` や `->` をエスケープせずに書いていた箇所がエスケープされただけで、表示される文字列は同じである。今後、字句解析を改善したときも同じ手順（全ページに再適用し、表示される文字列が変わらないことをスクリプトに確かめさせる）で付け直してよい。もう1つの例外は、2026-09-21のサービス名変更（旧名から「Namaran」へ）である。表示名はタイトル・マストヘッド・JSON-LDとして全ページに入っているため、公開済みページも含めて一括で置換した。置換したのは大文字始まりの表示名だけで、コード（`<pre class="code">` の中）には触れていない。ドメイン・GitHubリポジトリ名・Skill名・環境変数などの小文字の識別子は、DNSやリポジトリの変更を伴うため変えていない。これ以外の理由で公開済みページを編集しないという方針は変わらない。

---

## 10. Cloudflare Pages 設定

ビルドが実質不要な構成のため、UI上の項目は以下の方針で設定する。実際にCloudflare UIで確定した値は、このあと実測定値として本節を更新すること。

```text
Framework preset: None
Build command: 空欄（またはCloudflare UIが提示する推奨設定。値が必要な場合は `exit 0` 等の no-op でよい）
Build output directory: 静的ファイルを置いたディレクトリ（このリポジトリでは直下 = リポジトリルート想定）
Root directory: リポジトリルート
```

---

## 11. v1で作らないもの（確認のみ）

要件定義 §23 と一致。設計上ここに迷いを残さない。

```text
JavaScript
ビルドツール / テンプレートエンジン
バックエンド / API / DB
「今日の問題」自動選出ロジック
ユーザー管理・ログイン
実行環境（Run/Compiler/REPL等）
採点・スコア・Streak
ランキング・SNS機能
CMS
```

`sitemap.xml` と `robots.txt` は当初「作らない」に入れていた（手で維持するコストが割に合わないという理由）。公開が自動化された今は、公開するのと同じ手順の中で `script/sitemap.sh` が生成するので、維持コストは無い。§9.3 を参照。

なお、ここで作らない「履歴」はユーザー個人の解答履歴・進捗であり、問題コンテンツ自体のアーカイブ（§7.1、§9）とは別物である（要件定義 §17、§22）。

---

## 12. 最短で動かすための手順（Definition of Done）

以下が揃えば「動くNamaran」として成立する。中身の問題文はプレースホルダーでよく、後から差し替えれば良い。

1. `style.css` を1枚作る（§8の方針で最小限）
2. `index.html` を実コンテンツで作る（§6）
3. `_headers` を作る（§3.3）
4. `404.html` を最小限の内容で作る（§6）
5. `functions/_middleware.js` を作る（§5.1・§5.2：未来日404、および「今日」エイリアスの解決）
6. §7.1の規約を元に、12組（4言語 × 3種別）それぞれの初日のアーカイブページ（例: `c/read/2026-08-21.html`）をプレースホルダー内容で作成する。Past ペインは「Today」リンク＋現在地だけになる
7. GitHubリポジトリを作成し、上記一式をpush
8. Cloudflare PagesとGitHubリポジトリを接続し、§10の設定でデプロイ
9. `/` を開いて、Namaranの説明文と12個の案内リンクが表示されることを確認する
10. `/c/read`（ミドルウェアが最新の日付ページへ差し替えるエイリアス）と `/c/read/2026-08-21`（そのページ自体の固定URL）の両方に、`.html` なしで直接アクセスでき、同じ内容が表示されることを確認する
11. 画面幅が40rem以上のとき、問題ページの右側にPastペインが表示され、日付をクリックするとその日のページに切り替わることを確認する（JS不使用、ページ遷移のみ）
12. レスポンスヘッダに `Content-Security-Policy` 等が付与されていることを確認する（ブラウザの開発者ツール／`curl -I`）。手順10の `/c/read` エイリアス側でもヘッダが同様に付与されることを確認する

ここまでで公開可能。以降の作業は「問題の中身を良くしていくこと」だけになり、それは要件定義 §24 の言う通りNamaranの本質的な資産である。
