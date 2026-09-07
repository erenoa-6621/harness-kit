#!/usr/bin/env bash
# verify.sh — harness-kit の完了判定。**完了はこれが緑のときだけ。**
#
#   1. 依存を確かめる（無ければ「判定不能」で赤。黙って緑にしない）
#   2. tests/run_*.sh を全部回す
#   3. tools/mutation_check.sh を回す（検査が壊れたら赤くなるか）
#   4. 「実際に走ったスイート数 = tests/run_*.sh の実体数」「変異台帳のスイート集合 = 実体」を突き合わせる
#   5. 結果を <STATE_DIR>/last_verify_result に残す（Stop フックが読む）
#   1本でも赤なら exit 1。**出力が空になることは無い**（0件・無出力は正常の顔をした異常でありうる）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1
CONF="${HARNESS_CONF:-$ROOT/harness.conf}"
STATE_DIR="state"
[ -f "$CONF" ] && . "$CONF"
case "$STATE_DIR" in /*) ;; *) STATE_DIR="$ROOT/$STATE_DIR" ;; esac

red=0
ok(){ echo "  🟢 $1"; }
ng(){ echo "  🔴 $1"; red=$((red+1)); }

echo "===== harness-kit verify ====="
echo "── 0. 依存（無ければ判定不能＝赤）"
for _loc in "${LC_ALL:-}" C.UTF-8 C.utf8 en_US.UTF-8 ja_JP.UTF-8; do
  [ -n "$_loc" ] || continue
  if printf 'あ' | LC_ALL="$_loc" wc -m 2>/dev/null | grep -q '^ *1$'; then export LC_ALL="$_loc"; break; fi
done
if printf 'あ' | wc -m 2>/dev/null | grep -q '^ *1$'; then ok "UTF-8 ロケール（LC_ALL=$LC_ALL）"
else ng "判定不能: UTF-8 ロケールが無い（日本語の判定が壊れる）"; fi
if sed --version 2>/dev/null | head -1 | grep -q 'GNU sed'; then ok "GNU sed"
else ng "判定不能: GNU sed が無い（変異検査の sed -i -E が動かない）"; fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)'; then ok "python3 $(python3 -c 'import sys; print(".".join(map(str,sys.version_info[:3])))')"
else ng "判定不能: python3 (>=3.8) が無い"; fi
if [ "$red" -ne 0 ]; then
  echo "== 赤 harness-kit verify: 依存が足りず判定できない（red=$red）=="; exit 1
fi

echo "── 1. スイート"
mapfile -t SUITES < <(ls tests/run_*.sh 2>/dev/null | sort)
n_real=${#SUITES[@]}
if [ "$n_real" -eq 0 ]; then ng "tests/run_*.sh が 0 本（0件の緑を信用しない）"; fi
ran=0; suite_red=0
for s in "${SUITES[@]}"; do
  out=$(bash "$s" 2>&1); rc=$?
  ran=$((ran+1))
  last=$(printf '%s\n' "$out" | grep -E '(pass=|fail=)' | tail -1)
  if [ "$rc" -eq 0 ]; then ok "$(basename "$s"): ${last:-（集計行なし）}"
  else
    ng "$(basename "$s") exit=$rc: ${last:-（集計行なし）}"; suite_red=$((suite_red+1))
    printf '%s\n' "$out" | grep -E 'NG|🔴' | head -10 | sed 's/^/       /'
  fi
done

echo "── 2. 変異検査"
mout=$(bash tools/mutation_check.sh 2>&1); mrc=$?
mlast=$(printf '%s\n' "$mout" | tail -1)
if [ "$mrc" -eq 0 ]; then ok "mutation_check: $mlast"
else ng "mutation_check exit=$mrc: $mlast"; printf '%s\n' "$mout" | grep -E '❌|⏭|⚠|赤' | head -15 | sed 's/^/       /'; fi

echo "── 3. 網羅の突き合わせ"
if [ "$ran" -eq "$n_real" ] && [ "$n_real" -gt 0 ]; then ok "走ったスイート ${ran} 本 = 実体 ${n_real} 本"
else ng "走ったスイート ${ran} 本 ≠ 実体 ${n_real} 本"; fi
real_set=$(printf '%s\n' "${SUITES[@]}" | sort -u)
reg_set=$(awk -F'\t' '!/^[[:space:]]*(#|$)/ {print $1}' tests/mutations.tsv 2>/dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$real_set") <(printf '%s\n' "$reg_set"))
ghost=$(comm -13 <(printf '%s\n' "$real_set") <(printf '%s\n' "$reg_set"))
if [ -z "$miss" ] && [ -z "$ghost" ] && [ -n "$reg_set" ]; then ok "変異台帳のスイート集合 = 実体（$(printf '%s\n' "$reg_set" | grep -c .) 本）"
else
  ng "変異台帳とスイートの実体が一致しない"
  [ -n "$miss" ]  && printf '%s\n' "$miss"  | sed 's/^/       └ 変異が未登録: /'
  [ -n "$ghost" ] && printf '%s\n' "$ghost" | sed 's/^/       └ 幽霊（台帳にあるが実体が無い）: /'
fi

echo "── 4. 結果の記録"
mkdir -p "$STATE_DIR" 2>/dev/null
head_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo -)
if printf 'epoch=%s\nred=%s\nhead=%s\n' "$(date +%s)" "$red" "$head_sha" > "$STATE_DIR/last_verify_result" 2>/dev/null; then
  ok "結果を書いた: $STATE_DIR/last_verify_result（red=$red）"
else ng "結果ファイルを書けない: $STATE_DIR/last_verify_result"; fi

echo "-----"
if [ "$red" -eq 0 ]; then echo "== 緑 harness-kit verify: suites=${ran}/${n_real} mutation=ok red=0 =="; exit 0
else echo "== 赤 harness-kit verify: suites=${ran}/${n_real} red=${red} =="; exit 1; fi
