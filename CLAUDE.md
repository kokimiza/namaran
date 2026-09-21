# CLAUDE.md

Namaranは1日1問のコーディングドリル静的サイト。作業前に必ず読むこと:

- [doc/requirements.md](doc/requirements.md) — 要件定義(Namaranが何をする/しないか)
- [doc/basic-design.md](doc/basic-design.md) — 基本設計(ディレクトリ構成・HTML規約・運用フロー)
- [.claude/skills/namara-daily/SKILL.md](.claude/skills/namara-daily/SKILL.md) — 日々のドリル作成手順

新しい問題を1つ作るときは `namara-daily` Skillを使う。`script/content.sh` の使い方やHTML規約はSkill側とbasic-design.md側の指示に従い、ここには重複させない。

## 対象言語のバージョン固定

各言語の問題は、以下のバージョン/エディションを前提に書く(`script/content.sh` の `lang_nav_label()` および `index.html` の言語見出しと一致させること)。問題の挙動を確認する際は、まずここのリファレンスを当たる。

| 言語 | 対象バージョン | 言語仕様リファレンス |
|---|---|---|
| C | C23(ISO/IEC 9899:2024) | 最終パブリックドラフト [N3220](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n3220.pdf) / 早見表 [cppreference — C23](https://en.cppreference.com/w/c/23) |
| C++ | C++26 | 現在の作業ドラフト(常に最新の内容に更新される) [eel.is/c++draft](https://eel.is/c++draft/) / 早見表 [cppreference — C++26](https://en.cppreference.com/w/cpp/26) |
| Rust | Rust 2024 edition | [The Edition Guide — Rust 2024](https://doc.rust-lang.org/edition-guide/rust-2024/index.html) / [The Rust Reference](https://doc.rust-lang.org/reference/) |
| Haskell | Haskell 2010 | [Haskell 2010 Language Report](https://www.haskell.org/onlinereport/haskell2010/) |

Haskellだけは後継の公式言語標準が存在しない(2010年の報告書が最新かつ唯一の言語標準)。GHCの拡張機能を使う場合は言語標準の範囲外であることを問題文か解説で明示する。

新しい言語標準が確定した場合(例: C++26の正式発行、次期Cの発行)、この表と `script/content.sh` の `lang_nav_label()`・`index.html` の言語見出し・`script/verify.sh` のコンパイラオプション(`-std=` / `--edition` / `-X`)を同時に更新すること。片方だけ更新するとサイト表示とこのドキュメントがずれ、検証も古い標準で行われてしまう。
