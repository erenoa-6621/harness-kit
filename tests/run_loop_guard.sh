#!/usr/bin/env bash
# tools/loop_guard.sh の回帰スイート。
#
# なぜ要るか:
#   これは**人が `rm` 一発でループを止める経路**である。機械への委譲の条件②
#   （人間が即時停止できる経路）を供給しているのはこの1本だけ。
#   **ここが静かに壊れると、止めたつもりのループが回り続ける。**
#   停止経路は「在る」ではなく「効く」を確かめる。
#
# 状態ファイルはキットの state/ に触れず、一時ディレクトリを LOOP_STATE_DIR に指す harness.conf を渡す。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$HERE/../tools/loop_guard.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DIR="$TMP/loops"
printf 'LOOP_STATE_DIR="%s"\n' "$DIR" > "$TMP/harness.conf"
export HARNESS_CONF="$TMP/harness.conf"
N="testsuite_$$"
F="$DIR/$N.run"
pass=0; fail=0
ok(){ echo "  🟢 $1"; pass=$((pass+1)); }
ng(){ echo "  🔴 $1"; fail=$((fail+1)); }

echo "===== ループ停止スイッチの回帰スイート ====="

# 1. 開始していないループは回らない（**既定は「止まっている」**）
bash "$G" "$N" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "開始していないループは回らない（既定は停止）" || ng "開始していないのに回ってよいと返した"

# 2. --arm で回るようになる。状態ファイルは harness.conf の LOOP_STATE_DIR に置かれる
bash "$G" "$N" --arm >/dev/null 2>&1
bash "$G" "$N" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "--arm すれば回る" || ng "--arm しても回らない"
[ -f "$F" ] && ok "状態ファイルは harness.conf の LOOP_STATE_DIR に置かれる" || ng "状態ファイルが LOOP_STATE_DIR に無い（設定を読んでいない）: $F"

# 3. ★本命：**状態ファイルを消したら次の周回で止まる**（人の停止経路）
rm -f "$F"
bash "$G" "$N" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "状態ファイルを rm したら止まる（人の停止経路）" || ng "rm しても止まらない＝停止経路が効いていない"

# 4. --stop でも止まる
bash "$G" "$N" --arm >/dev/null 2>&1
bash "$G" "$N" --stop >/dev/null 2>&1
bash "$G" "$N" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "--stop で止まる" || ng "--stop が効かない"
[ ! -f "$F" ] && ok "--stop は状態ファイルを実際に消す" || ng "--stop しても状態ファイルが残っている"

# 5. 連続失敗が上限に達したら自動で止まる
bash "$G" "$N" --arm >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
r3=$(bash "$G" "$N" --fail 2>&1); rc3=$?
if [ "$rc3" -ne 0 ] && printf '%s' "$r3" | grep -qF "計画の欠陥"; then
  ok "連続失敗3回で自動停止し、理由を『計画の欠陥』と述べる"
else ng "連続失敗3回で止まらない（exit=$rc3）: $(printf '%s' "$r3" | tail -1)"; fi
[ ! -f "$F" ] && ok "自動停止は状態ファイルを消す（fail safe）" || ng "自動停止したのに状態ファイルが残っている"

# 6. --ok で連続失敗がリセットされる（**成功を挟めば止まらない**。過検知の対）
bash "$G" "$N" --arm >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
bash "$G" "$N" --ok   >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
bash "$G" "$N" --fail >/dev/null 2>&1
bash "$G" "$N" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "成功を挟めば連続失敗はリセットされる（過検知の対）" || ng "成功を挟んでも止まった＝過検知"
bash "$G" "$N" --stop >/dev/null 2>&1

# 7. 止まっているループへの --fail / --ok は「既に止まっている」を返す（黙って復活させない）
bash "$G" "$N" --ok >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "止まっているループを --ok で復活させない" || ng "止まっているのに --ok が成功した＝停止が覆る"
[ ! -f "$F" ] && ok "--ok は状態ファイルを作らない" || ng "--ok が状態ファイルを作った＝rm で止めても復活する"

# 8. ループ名にパス区切りを渡せない（状態ディレクトリの外に書かせない）
bash "$G" "../../etc/evil" --arm >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "ループ名にパス区切りを拒む" || ng "パス区切りを含む名前を受け付けた"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== ループ停止スイッチの回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 ループ停止スイッチの回帰スイート pass=$pass fail=$fail =="; exit 1; fi
