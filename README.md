# harness-kit

Claude Code（および同種のエージェント運用）で踏んだ不具合から起こした「門」の集まりです。
自分たちの AI 運用で実際に起きた失敗を、注意力や文章のルールではなく、機械が止める・機械が答える形に落としたものを、
社内固有の名前や数値を外して切り出しました。必要なものは bash・python3（3.8 以上）・GNU sed・git です。

- 門（機械が止める）: PreToolUse フック2本・Stop フック1本・git pre-commit
- 判定（機械が答える）: 人間ゲート判定・ループ停止スイッチ
- 検査を検査するもの: 変異検査・3値台帳・フック契約検査・`verify.sh`
- 任意: PII 検査・資格情報の棚卸し

「これを入れれば安全」という道具ではありません。すべて既知の型に対する決定論的なつまずき石で、境界ではありません（§既知の限界）。

## 5つの欠陥の型

個別の不具合を1つずつ直しても再発します。実際に出た不具合は、次の5つの型に収まりました。このキットは「機能を足す」のではなく、この型を潰す方向で組んであります。

### 型1: fail-open ── 壊れたのに緑になる

未処理が0件だと無出力になる検査は、壊れたスクリプトでも「契約どおり」で緑になります。
入力ファイルのタブ欠落・綴り違い・空ファイルが全部 exit 0 の「0件」になる。件数比較だけの網羅検査は、改名＋別名追加で未登録を隠せる。
スイートを足して配線を忘れると、緑のまま検査が消える。

共通点は「黙って通る／黙って止める」。異常が「何も起きない」の形で出ます。

対策の原則: **異常は必ず音を立てさせる。** 「0件」「無出力」「該当なし」は、正常の顔をした異常でありえます。
検査を書いたら必ず「壊したら赤くなるか」を変異で確かめる（§検査の3値と変異検査）。

### 型2: 助言型は効かない ── 文章で書いて満足する癖

規則を「案内1行」に落としたものは開かれず、推薦フックの追従率は数%だったという計測があります（出典: https://zenn.dev/activecore/articles/claude-code-resident-cost 、2026-09-03 取得）。
文脈ファイルの指示は守られても、成功率に有意差は無くコストだけ増えるという研究もあります（出典: https://arxiv.org/abs/2602.11988 、2026-09-03 取得）。
自分たちの運用でも、止める門だけが効きました。「書いたから守られる」は成立していません。

対策の原則: ルールは3つに分類して置き場所を変える。①門（機械が止める）＝フック・検査スクリプトへ。②判定（機械が答える）＝`gate_check.sh` 型へ。③記録（人が読む）＝文書へ。
文脈ファイルに残すのは①②の入口と、起動に要る最小限だけ。

### 型3: 二値の検査 ── 落ちる検査は消される

緑/赤の二値しか無いと、「たまに落ちる検査」を置く場所が無く、落ちる検査は消されるか無視されます。
Stop フックが1日十数回鳴れば、二値のままでは「うるさいから外す」に着地します。

対策の原則（Gemini CLI の release-confidence / behavioral-evals の考え方を借りています。出典: https://github.com/google-gemini/gemini-cli の release-confidence.md（docs 配下）、2026-09-03 取得）: 検査は `ALWAYS_PASSES / USUALLY_PASSES / USUALLY_FAILS` の3値で持ち、落ちることを承知で置く検査には期限を付ける（`tools/check_levels.tsv`）。
新しい検査を「必ず通る」から始めない。門には逃げ道を1つ刻む（`skip verify（理由）`）。逃げ道の無い門は摩耗して外されます。

### 型4: 孫引きを根拠にする

二次情報の「AはBを下げる」を原典に当たると有意差なし、「期限は X 日」を原典に当たると対象外、という取り違えが続きました。
どちらも原典に当たって初めて止まりました。

対策の原則: 数字と規範は、原典に当たった者だけが使う。二次情報は「そういう主張がある」までしか書けない。出典 URL と取得日を必ず添える。

### 型5: 測らずに議論する

常駐トークン量、営業の返信率、サブエージェントのモデル指定。どれも未測定のまま「重いのでは」「効いていないのでは」と議論していました。
測ると依存なし・1発で分かるものばかりでした。

対策の原則: 推測をやめて測る。撤退条件は、測る機構とセットにしないと存在しないのと同じ（`harness/stop_hook_stats.sh`）。

## 各部品

停止スイッチは原則 `rm` 1発（フックのファイルを消すか、`settings.json` の該当行を消す）です。例外は `.githooks/pre-commit` で、こちらは `git config --unset core.hooksPath` で外します。

| 部品 | 何を止める／答えるか | 止め方 |
|---|---|---|
| `hooks/deny_mutations.sh` | 読み取り専用の役（`harness.conf` の `READONLY_AGENTS`）が Bash で行う変更操作（リダイレクト・rm/mv/mkdir/rsync…・`sed -i`・`sort -o`・`patch`・`find -delete/-exec`・`bash -c "…"`/`eval "…"` の中身・git/gh の変更系・python/node 経由の書き込み・subprocess 経由の変更系）を exit 2 で止める。一時領域（`/tmp/` `$TMPDIR`）への書き込みは通す。主セッション（agent_type 無し）は対象外 | `rm hooks/deny_mutations.sh` |
| `hooks/check_git_identity.sh` | コミット名義が `harness.conf` の `GIT_NAME_EXPECTED` / `GIT_EMAIL_EXPECTED` と一致しない上書き（`-c user.email=` や環境変数）を含む `git commit` を止める。期待値が未設定なら判定できないので止める | `rm hooks/check_git_identity.sh` |
| `.githooks/pre-commit` | 同じ名義検査を git の経路で行う（cron やスクリプト内の git はフックの文字列検査に現れないため）。`git config core.hooksPath .githooks` で有効化 | `git config --unset core.hooksPath` |
| `hooks/unfinished_action.py` | Stop フック。最終メッセージが「〜します」等の一人称の行動宣言で終わっているとき、一度だけ差し戻す。加えて `verify.sh` の結果が赤／12時間より古いまま止まろうとしたら一度だけ差し戻す。語彙は `hooks/unfinished_vocab.txt`。逃げ道は `skip verify（理由）` | `rm hooks/unfinished_action.py` |
| `harness/stop_hook_stats.sh` | Stop フックの本番発火数・block 数を数える。閾値（既定10）に達したら人に誤検知率の判定を求める。本番で一度も呼ばれていないことも検知する | ― |
| `tools/gate_check.sh` | 「その一手は人間ゲートか」を答える。0=裁量 / 1=人間ゲート / 2=判定できない（人間ゲート扱い）。語彙は `tools/gate_vocab.conf` | ― |
| `tools/loop_guard.sh` | ループの停止スイッチ。状態ファイル（`LOOP_STATE_DIR/<名前>.run`）が無ければ次の周回で止まる。連続失敗3回で自動停止 | `rm <LOOP_STATE_DIR>/<名前>.run` |
| `tools/mutation_check.sh` | `tests/mutations.tsv` の変異を一時ディレクトリの写しに撃ち、検査が赤になることを確かめる。空振り・変異前から赤・全殺しだけ、を赤にする | ― |
| `tools/check_levels.tsv` + `tests/run_check_levels.sh` | 検査の3値台帳。期限の無い `USUALLY_FAILS`・期限切れ・登録漏れ・根拠なしを赤にする | ― |
| `settings.json.example` + `tests/run_harness_contract.sh` | フックの配線と入出力契約。`${CLAUDE_PROJECT_DIR}` 起点であること、指す先が実在すること、hooks/ の実体が全部配線されていること、Stop が「黙るべきとき無出力・差し戻すとき1オブジェクト」であること | ― |
| `verify.sh` | 上記すべてを回し、走ったスイート数と実体を突き合わせ、結果を `state/last_verify_result` に残す | ― |
| 任意 `tools/pii_check.sh` | 公開候補パスに個人メール・旧ハンドルが無いことを検査する。値は出さない（パス:行番号だけ）。局所パターンは `tools/.pii_patterns.local`（gitignore 対象） | ― |
| 任意 `tools/audit_credentials.sh` | 資格情報の棚卸し。値を絶対に出さない（件数・位置・長さ・指紋8桁だけ）。自己テストが赤なら exit 3 | ― |

## 導入手順

1. キットの中身をプロジェクト直下に置く（`hooks/ tools/ tests/ harness/ .githooks/ harness.conf.example settings.json.example verify.sh`）。
   サブディレクトリに置く場合は `settings.json` のパスをそれに合わせる。
2. `cp harness.conf.example harness.conf` して編集する（`harness.conf` は `.gitignore` 済みで追跡しない）。
   `harness.conf` が無いときフックは fail-closed で、読み取り専用の役の Bash と名義を上書きするコミットは止まる（黙って通さない）。

   ```
   READONLY_AGENTS="chosa kansa kensho hisho eigyo"   # 読み取り専用の役名（agent_type）。この5つは例
   GIT_NAME_EXPECTED="Your Name"
   GIT_EMAIL_EXPECTED="you@example.invalid"
   LOOP_STATE_DIR="state/loops"
   STATE_DIR="state"
   VERIFY_WATCH_DIRS="hooks tools tests .claude"
   ```

3. `settings.json.example` の `hooks` を `.claude/settings.json` に貼る。command はすべて `"${CLAUDE_PROJECT_DIR}/..."` で、`$HOME` の fallback を持たない。

   ```json
   {
     "hooks": {
       "Stop": [
         { "hooks": [ { "type": "command", "command": "python3 \"${CLAUDE_PROJECT_DIR}/hooks/unfinished_action.py\"", "timeout": 10 } ] }
       ],
       "PreToolUse": [
         { "matcher": "Bash", "hooks": [
           { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/hooks/deny_mutations.sh\"" },
           { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/hooks/check_git_identity.sh\"" }
         ] }
       ]
     },
     "env": { "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP": "8" }
   }
   ```

4. `git config core.hooksPath .githooks`（名義検査を git 側にも入れる場合）。
5. `bash verify.sh` を回す。全緑で exit 0。依存（UTF-8 ロケール・GNU sed・python3）が無ければ「判定不能」で赤になる。
6. フックは配線したセッションでは発火しないことがある。新しいセッションで `bash harness/stop_hook_stats.sh` を見て、本番で呼ばれていることを確かめる。

## 人間ゲート

不可逆な操作は人、それ以外は機械、という線引きです。

- 人間ゲート（人の確認が要る）: 対外送信・公開・納品・課金・不可逆な削除・本番デプロイ＝新規の対外公開、および公開の配線を「押す」こと。
- 裁量（機械が進めてよい）: 内部の開発・検証・private への commit と PR・検証が緑の PR マージ・配線（ワークフロー/cron/CI/公開窓）の変更・公開済み資産の内容更新・運用ルールの改訂。

この線引きは、ある一人会社が自分たちの運用で決めた既定値です。組織ごとに `tools/gate_vocab.conf` で語彙を変えてください。

裁量には2つの条件が掛かります。欠けたら裁量に含まれません。

1. 検査が緑であること
2. `hold` ラベル等で人間が即時停止できる経路を残すこと

配線を変えてよいのであって、公開を押してよいわけではありません。判定に迷ったら `bash tools/gate_check.sh "<その一手>"` に聞きます（0=裁量 / 1=人間ゲート / 2=判定不能＝人間ゲート扱い）。
これは denylist であって境界ではないので、0 が返っても疑わしければ止まってかまいません。判断は人が持ちます。
機械が自分の権限を自分で広げてはいけません。範囲を変えるときは人の言葉を引用して書き換えます。

## 検査の3値と変異検査の理由

検査が緑であることは、検査が働いていることの証明ではありません。何も見ていなくても緑は出ます。
区別する方法は1つだけで、対象をわざと壊して赤くなることを確かめることです（`tools/mutation_check.sh`）。
変異は一時ディレクトリの写しにだけ撃ちます。実物を壊して戻す方式は、変異の最中に別のセッションが壊れた PreToolUse フックを掴んで全 Bash が落ちる事故を起こしました。

台帳（`tests/mutations.tsv`）の規律:

- 各スイートに最低1件、しかも「局所」（落ちるアサーションが半分未満）の変異を置く。全殺しだけの登録は「スイートが全く死んでいない」ことしか証明しません。広い/局所は自己申告ではなく機械が分類します。
- 空振り（対象が1バイトも変わらない）は赤。変異前から赤いスイートは「判定不能」で赤。
- 変異を1つも登録していないスイートは `verify.sh` が赤にします。

検査の水準は3値です（`tools/check_levels.tsv`）。`USUALLY_FAILS` には期限が要り、期限を過ぎたら赤です。落ちることを承知で置いた検査が期限までに緑へ動かないなら、それは検査ではなく願望なので消します。

## 既知の限界

- どの門も denylist であって境界ではありません。`deny_mutations.sh` は既知の書き込み構文に対する決定論的なつまずき石で、`from subprocess import run`・`os.popen`・自作スクリプト経由・`bash -c "$VAR"` や `find … -exec 自作スクリプト` のように中身を静的に読めないもの（警告を出して通す）などは通ります（ファイル冒頭に「まだ通るもの」を列挙してあります）。独立検証で素通りが実測された `rsync`・`find -delete`・`bash -c "…"`・`eval "…"`・`sort -o`・`patch` は塞ぎ、検体を `tests/run_hooks.sh` O 節に置きました。それでも列挙は列挙です。単独で「守れている」根拠にしないでください。
- 二重引用符の中のコマンド置換（`echo "$(rm -rf x)"`）は通ります。引用リテラルを目印に潰す掃除が中身を判定から外すためです（引用符なしの `$(…)` は止まります）。現状の挙動を `tests/run_hooks.sh` P 節に記録してあり、塞いだらその検体の期待値を 2 に変えます。
- コマンド置換でコマンド名を作る形（`$(echo rm) -rf x`）も通ります。展開後の語を判定していないためです（変数経由の `r=rm; $r -rf x` は止まります）。同じく P 節に記録してあります。
- OS 層の隔離（sandbox・permissions.deny）は別途必要です。このキットはその代わりにはなりません。
- `gate_check.sh` は日本語と英語の語彙に依存します。言い換えは尽きないので、未知の外向き操作は素通りしえます。
- 過検知は安全側の失敗ではありません。検査の検体を作れなくし、測れない領域を増やします。過検知を見つけたら、通す検体と止める検体を対で足してください。
- Stop フックは「宣言して実行しない」を見ます。「宣言せずに黙って止まる」は状態（検査の結果ファイル）でしか見ていません。

## ライセンス

MIT（`LICENSE`）。

## 問い合わせ

（準備中）
