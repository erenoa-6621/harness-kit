#!/usr/bin/env bash
# tools/mutation_check.sh の回帰スイート。
#
# なぜ要るか:
#   mutation_check.sh は「その検査は壊したら赤くなるか」を確かめる道具である。
#   **この道具自身が fail-open したら、検査全部の信用が同時に消える。**
#   検査を検査する道具ほど、静かに壊れたときの被害が大きい。
#
#   実物のリポジトリを直接壊して走らせて戻す設計は、変異の最中に別のコマンドが**壊れた最中の PreToolUse フックを掴んで
#   そのセッションの Bash が全部落ちる**事故を起こす。強制終了されれば壊れたまま残る。
#   → サンドボックス（一時ディレクトリへの写し）方式。**その3点をここで固定する。**
#
# 検体は本物の mutations.tsv を使わない。**小さな偽リポジトリを一時領域に作って撃つ。**
#   本物を使うと遅いうえ、台帳が増えるたびにこのスイートが遅くなる。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC="$HERE/../tools/mutation_check.sh"
pass=0; fail=0
ok(){ echo "  🟢 $1"; pass=$((pass+1)); }
ng(){ echo "  🔴 $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 偽リポジトリを作る。mutation_check.sh は tools/.. を SRC と見て tests/mutations.tsv を読むので、その形に置く。
mkfake() {  # $1=行き先  $2=台帳の中身
  local d="$1"
  mkdir -p "$d/tools" "$d/tests"
  cp -p "$MC" "$d/tools/mutation_check.sh"
  # 対象: 4種類の危険語を見る小さな検査器。
  #   **1語だけ壊す変異が「局所（narrow）」になるように、複数のアサーションを持たせる。**
  #   1アサーションしか無い検体だと、どんな変異も「全殺し」に分類されてしまう。
  cat > "$d/tools/toy.sh" <<'T'
#!/usr/bin/env bash
for w in DANGER PERIL HAZARD RISK; do
  grep -q "$w" "$1" && { echo "🔴 $w"; exit 1; }
done
echo "🟢 安全"; exit 0
T
  cat > "$d/tests/run_toy.sh" <<'T'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
for w in DANGER PERIL HAZARD RISK; do
  f=$(mktemp); echo "$w" > "$f"
  bash "$HERE/../tools/toy.sh" "$f" >/dev/null 2>&1; rc=$?; rm -f "$f"
  if [ "$rc" -eq 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  NG $w を検出できない"; fi
done
if [ "$fail" -eq 0 ]; then echo "== toy pass=$pass fail=0 =="; exit 0; fi
echo "== 赤 toy pass=$pass fail=$fail =="; exit 1
T
  chmod +x "$d/tools/toy.sh" "$d/tests/run_toy.sh" "$d/tools/mutation_check.sh"
  printf '%s\n' "$2" > "$d/tests/mutations.tsv"
}

echo "===== 変異検査器の回帰スイート ====="

# 1. 素直な変異 → 緑（この道具が普通に働くこと）
A="$TMP/a"; mkfake "$A" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	検出語を消す'
if out=$(bash "$A/tools/mutation_check.sh" 2>&1); then ok "有効な変異は pass になる"
else ng "有効な変異なのに赤: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

# 2. **空振りの変異は赤**（撃ったつもりの飾りを許さない）
#    ⚠ ここで**自分の検体を fail-open させた**実測がある。
#      台帳の「説明」欄に「空振りの式」と書き、出力全体から `grep -q "空振り"` していたため、
#      **空振り検知を殺す変異を撃っても、説明欄の文字が grep に当たって緑のまま**だった。
#      → 検体の説明に、判定に使う語を入れない。判定はメッセージの**全文**で見る。
B="$TMP/b"; mkfake "$B" 'tests/run_toy.sh	tools/toy.sh	s/NOTHING_MATCHES_THIS/x/	対象に当たらない式'
out=$(bash "$B/tools/mutation_check.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "変異が空振り（対象が変わっていない）"; then
  ok "空振りの変異を赤にする"
else ng "空振りの変異が緑になった（exit=$rc）＝台帳が飾りになる: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

# 3. **変異前から赤いスイートは判定不能で赤**（赤に赤を撃っても通ってしまう）
C="$TMP/c"; mkfake "$C" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	検出語を消す'
sed -i 's/for w in DANGER PERIL HAZARD RISK/for w in NEVER1 NEVER2 NEVER3 NEVER4/' "$C/tools/toy.sh"   # 先に壊しておく
out=$(bash "$C/tools/mutation_check.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "前提不成立（変異前から赤）"; then
  ok "変異前から赤いスイートを判定不能で赤にする"
else ng "赤いスイートに変異を撃って緑を返した（exit=$rc）＝この道具自身の fail-open"; fi

# 4. **変異が緑のまま通ったら赤**（見ていない検査を見つけられること＝本来の仕事）
D="$TMP/d"; mkfake "$D" 'tests/run_toy.sh	tools/toy.sh	s/^echo "🟢 安全"/echo "🟢 安全 "/	検出に関係ない場所を変える'
out=$(bash "$D/tools/mutation_check.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "変異しても緑のまま（＝この検査は見ていない）"; then
  ok "赤にならない変異を赤として報告する"
else ng "検査が見ていないのに緑を返した（exit=$rc）＝本来の仕事をしていない"; fi

# 5. 台帳が無ければ緑にしない
E="$TMP/e"; mkfake "$E" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	x'
rm -f "$E/tests/mutations.tsv"
bash "$E/tools/mutation_check.sh" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "台帳が無ければ赤（0件の緑を信用しない）" || ng "台帳が無いのに緑"

# 5-b **台帳の最終行に改行が無いと read がその行を黙って捨てる。**
#     実測で「最後の1件が実行されないのに pass=1 fail=0 で緑」になった。
#     網羅の突き合わせは grep（不完全行も数える）で読むので、**登録は在るのに撃たれない**ズレが起きる。
E2="$TMP/e2"; mkfake "$E2" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	検出語を消す'
printf 'tests/run_toy.sh\ttools/toy.sh\ts/PERIL/CALM/\t別の検出語を1つ消す（局所）' > "$E2/tests/mutations.tsv"  # 末尾に改行なし
out=$(bash "$E2/tools/mutation_check.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "最終行に改行が無い"; then
  ok "台帳の最終行に改行が無ければ赤（黙って行を捨てない）"
else ng "改行の無い最終行を黙って捨てて緑になった（exit=$rc）: $(printf '%s' "$out" | tail -1)"; fi

# 5-c **全殺しの変異しか登録していないスイートを赤にする。**
#     全殺しは「スイートが完全に死んでいない」ことしか証明しない。実際に
#     「是正の半分が一度も測られていない」が出た。広い/局所は**自己申告させず、
#     落ちたアサーションの割合で機械が測る**（半分未満＝局所）。
E3="$TMP/e3"; mkfake "$E3" 'tests/run_toy.sh	tools/toy.sh	s/^for w in DANGER PERIL HAZARD RISK/for w in Z1 Z2 Z3 Z4/	検出語を全部消す（全殺し）'
out=$(bash "$E3/tools/mutation_check.sh" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "局所の変異が無いスイート"; then
  ok "全殺しの変異しか無いスイートを赤にする"
else ng "全殺しだけで緑になった（exit=$rc）＝網羅の門が緩いままになる: $(printf '%s' "$out" | tail -1)"; fi
E4="$TMP/e4"; mkfake "$E4" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	1語だけ消す（局所）'
bash "$E4/tools/mutation_check.sh" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "局所の変異が1件あれば通る（過検知になっていない）" \
  || ng "局所の変異があるのに赤＝局所判定が過検知している"

# 6. **実物を壊さない**（初版の事故。ここが本スイートの主目的）
#    変異対象のハッシュを、変異検査の前後で比べる。
F="$TMP/f"; mkfake "$F" 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	検出語を消す'
h_before=$(sha256sum "$F/tools/toy.sh" | cut -d' ' -f1)
bash "$F/tools/mutation_check.sh" >/dev/null 2>&1
h_after=$(sha256sum "$F/tools/toy.sh" | cut -d' ' -f1)
[ "$h_before" = "$h_after" ] && ok "変異検査のあと、対象ファイルが元のまま（サンドボックス方式）" \
  || ng "変異が実物に残った＝初版の事故の再発"

# 7. 実行中も実物が変わらないこと（別セッションが壊れた最中を掴む事故の再発防止）。
#    走らせながら 0.2 秒おきにハッシュを取り、1度でも変われば赤。
G="$TMP/g"; mkfake "$G" "$(printf 'tests/run_toy.sh	tools/toy.sh	s/DANGER/SAFE/	検出語を1つ消す（4件中1件だけ落ちる＝局所）\ntests/run_toy.sh	tools/toy.sh	s/PERIL/CALM/	別の検出語を1つ消す（局所）')"
h0=$(sha256sum "$G/tools/toy.sh" | cut -d' ' -f1)
bash "$G/tools/mutation_check.sh" >/dev/null 2>&1 &
mcpid=$!
changed=0
while kill -0 "$mcpid" 2>/dev/null; do
  [ "$(sha256sum "$G/tools/toy.sh" | cut -d' ' -f1)" = "$h0" ] || changed=1
  sleep 0.2
done
wait "$mcpid" 2>/dev/null
[ "$changed" -eq 0 ] && ok "実行中も対象ファイルが一度も変わらない" \
  || ng "実行中に対象が書き換わった＝別セッションが壊れた最中を掴みうる"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== 変異検査器の回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 変異検査器の回帰スイート pass=$pass fail=$fail =="; exit 1; fi
