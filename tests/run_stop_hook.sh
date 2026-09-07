#!/usr/bin/env bash
# Stop フック（hooks/unfinished_action.py）の回帰スイート。
#
# なぜ要るか: このフックは「勝手に止まる」への唯一の機構である。
#   transcript ファイルだけを読む版は、書き込みが間に合わないと「no assistant text」で黙って素通りした。
#   公式仕様では Stop の入力に `last_assistant_message` が入るので、そちらを第一情報源にしている。
#
#   **過検知の検体を必ず含める。** 誤って鳴ると、止まってよい場面で止まれなくなる。
#
# 状態はキットの state/ に触れず、一時ディレクトリを CLAUDE_PROJECT_DIR として渡す（結果ファイルはそこに置く）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/unfinished_action.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/root"; mkdir -p "$FAKE/state" "$FAKE/hooks"
RES="$FAKE/state/last_verify_result"
export CLAUDE_PROJECT_DIR="$FAKE"
pass=0; fail=0

run() { # 期待decision | last_assistant_message | stop_hook_active | verify結果 | 説明
  local want="$1" msg="$2" active="$3" res="$4" note="$5" got
  printf '%s' "$res" > "$RES"
  # OLD の検体だけ、結果ファイルの mtime を13時間前にする（**書き込みの後**でないと上書きされる）
  if [ "$res" = "$OLD" ]; then touch -d "13 hours ago" "$RES"; fi
  # ⚠ 環境変数は python3 の**前**に置く。後ろに書くと python への引数になり、os.environ から読めない。
  got=$(HOOK="$HOOK" MSG="$msg" ACT="$active" python3 -c '
import json,os,subprocess,sys
p=subprocess.run(["python3",os.environ["HOOK"]],
  input=json.dumps({"stop_hook_active":os.environ["ACT"]=="1",
                    "session_id":"testsuite","last_assistant_message":os.environ["MSG"]}),
  capture_output=True,text=True,env={**os.environ,"UA_TEST":"1"})
try: sys.stdout.write(json.loads(p.stdout)["decision"] if p.stdout.strip() else "-")
except Exception: sys.stdout.write("PARSE-ERR")
')
  if [ "$got" = "$want" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf '  NG %s\n     want=%s got=%s  msg=%s\n' "$note" "$want" "$got" "$msg"; fi
}

NOW=$(date +%s)
# ⚠ 言語判定を切り分ける検体では、epoch を**未来**にする。
#   現在時刻にすると「直前に hooks/ を編集した瞬間だけ落ちる」不安定なテストになる。
#   **再実行すれば緑になるテストは、緑を信じられなくする。** 決定論にする。
GREEN="epoch=$((NOW+3600))
red=0
head=x"
RED="epoch=${NOW}
red=3
head=x"
# STALE（緑判定の後に検査が変わった）: 偽ルートの hooks/ に1ファイル置き、その mtime − 1 秒を epoch にする。
#   NOW-99999 のような相対値だと、誰も検査を触らなかった日に n=0 となって落ちる。
touch "$FAKE/hooks/changed_after_green.sh"
NEWEST=$(stat -c %Y "$FAKE/hooks/changed_after_green.sh")
STALE="epoch=$((NEWEST-1))
red=0
head=x"
# OLD: **成果物が検証されていない**状態。12時間より古い緑は「いまの成果物についての緑」ではない（13時間前）。
#   ⚠ STALE（epoch が古い）と紛らわしいが別物：STALE は「緑判定の後に検査が変わった」、OLD は「緑判定そのものが古い」。
#     **片方だけ直すと静かに穴が開く**ので両方を検体に持つ。OLD は mtime で作る（epoch を古くすると STALE 側も鳴って変異が素通りする）。
OLD="epoch=$((NOW+3600))
red=0
head=old-marker"

echo "===== Stop フック回帰スイート ====="
# A. 言語判定（状態は緑）
run block "検証に回させます。"                      0 "$GREEN" "宣言 → 差し戻す"
run block "起動します。"                            0 "$GREEN" "宣言（短文）→ 差し戻す"
run -     "完了しました。verify は全緑です。"        0 "$GREEN" "過検知: 完了報告"
run -     "Cの着地を待ちます。"                      0 "$GREEN" "過検知: 待機"
run -     "公開は人間ゲートで判断します。"            0 "$GREEN" "過検知: 他者が主語（人間ゲート）"
run -     "再判定を待っている状態です。"              0 "$GREEN" "過検知: 待機の明示"
# B. stop_hook_active（二度は鳴らない＝止まれなくならない）
run -     "起動します。"                            1 "$GREEN" "二度目は鳴らない（無限ループ防止）"
# C. 状態判定（言語は無害）
run -     "記録しました。以上です。"                 0 "$GREEN" "緑＋無害 → 通す"
run block "記録しました。以上です。"                 0 "$RED"   "検査が赤のまま止まろうとした → 差し戻す"
run block "記録しました。以上です。"                 0 "$STALE" "全緑判定の後に検査が変わっている → 差し戻す"

# ── 成果物の検証 ──
run block "記録しました。以上です。"                 0 "$OLD"   "直近の全緑が13時間前 → 成果物を検証していない"
run -     "記録しました。以上です。"                 0 "$GREEN" "対: 直近の緑が新しければ通す"
# ── 逃げ道は明示的に1つだけ。**理由が記録に残る形にする**（隠れた逃げ道は門を摩耗させる）
run -     "記録しました。skip verify（人間ゲート待ちで、いま回しても意味がない）"  0 "$OLD" "skip verify と書けば通る"
run -     "記録しました。skip verify(公開待ちのため)"                            0 "$OLD" "半角括弧でも通る"
run -     "Skip Verify （大小は問わない）"                                       0 "$OLD" "大小文字を問わない"
# ⚠ 逃げ道は**状態由来の差し戻しにだけ**効く。「やります」と言って止まるのは別問題なので止め続ける。
run block "skip verify（回す必要が無い）。記事を書かせます。"  0 "$OLD" "逃げ道があっても、次アクションの宣言は差し戻す"
# D. 入力が空でも落ちない
run -     ""                                        0 "$GREEN" "最終出力が空 → 素通り（落ちない）"

# ── 本番の block を1件ずつ判定した結果、宣言由来6件のうち4件が誤検知だった。その4件を検体として固定する。
#    **過検知はノイズを生み、やがてフックごと外される。** 実文言の形をそのまま使う（作文しない）。
run -     "書かせますか。"                                                        0 "$GREEN" "誤検知: 疑問文は宣言ではない"
run -     "指示があれば別のことを先にやります。"                                    0 "$GREEN" "誤検知: 条件付き＝相手に機会を渡している"
run -     "止めなければ、記事5本の画像追加と長さの戻しから着手します。"                0 "$GREEN" "誤検知: 停止の機会を渡している"
run -     "**来月からは**、同じ検索式で貼ってもらえば集計スクリプトがこの表を機械で出します。" 0 "$GREEN" "誤検知: 未来の説明であって着手宣言ではない"
# ── 対（本物の宣言は今も止まること）。ここを緩めすぎると、フックの存在意義が消える。
run block "すぐ着手します。"                                                      0 "$GREEN" "本物: 即時の着手宣言"
run block "最優先と指定されたので、このまま移設に着手します。"                        0 "$GREEN" "本物: 条件語が無い着手宣言"

# E. バックグラウンド待ちなら絶対に差し戻さない。「待っている」は未完了ではない。
bgrun() { # 期待decision | 追加payload(JSON) | 説明
  local want="$1" extra="$2" note="$3" got
  printf 'epoch=%s\nred=0\nhead=x' "$((NOW+3600))" > "$RES"
  got=$(HOOK="$HOOK" EXTRA="$extra" python3 -c '
import json,os,subprocess,sys
d={"stop_hook_active":False,"session_id":"bgtest","last_assistant_message":"検証に回させます。"}
d.update(json.loads(os.environ["EXTRA"]))
p=subprocess.run(["python3",os.environ["HOOK"]],input=json.dumps(d),capture_output=True,text=True,
                 env={**os.environ,"UA_TEST":"1"})
try: sys.stdout.write(json.loads(p.stdout)["decision"] if p.stdout.strip() else "-")
except Exception: sys.stdout.write("PARSE-ERR")
')
  if [ "$got" = "$want" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf '  NG %s\n     want=%s got=%s\n' "$note" "$want" "$got"; fi
}
bgrun block '{}'                              "背景タスク無し＋宣言 → 差し戻す"
bgrun -     '{"background_tasks":[{"id":"t1"}]}'            "**背景タスク待ち → 差し戻さない**"
bgrun -     '{"background_tasks":[{"id":"a"},{"id":"b"}]}'  "背景タスク複数 → 差し戻さない"
bgrun -     '{"session_crons":[{"id":"c1"}]}'               "cron 生存 → 差し戻さない"
bgrun block '{"background_tasks":[]}'                       "空配列は待機ではない → 差し戻す"

# F. ログは偽ルートの state/ に書かれる（キットの state/ を汚さない・記録が測れる形である）
if [ -f "$FAKE/state/unfinished_action.log" ] && awk -F'\t' 'NF<5{bad=1} END{exit bad}' "$FAKE/state/unfinished_action.log"; then
  pass=$((pass+1))
else fail=$((fail+1)); echo "  NG ログが STATE_DIR に5列で書かれていない"; fi

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== Stop フック回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 Stop フック回帰スイート pass=$pass fail=$fail =="; exit 1; fi
