#!/usr/bin/env bash
# 検査の3値台帳（tools/check_levels.tsv）の健全性スイート。
#
# なぜ要るか:
#   3値にすること自体が目的ではない。**「落ちる検査を置く場所」を作ったら、
#   そこが物置になって二度と片付かない**のが最大の risk である。
#   だから台帳には**期限**を持たせ、期限を過ぎた USUALLY_FAILS を赤にする。
#   「**新しい検査を ALWAYS_PASSES から始めてはならない**」を lint で強制するのと同じ発想。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
TSV="tools/check_levels.tsv"
pass=0; fail=0
ok(){ echo "  🟢 $1"; pass=$((pass+1)); }
ng(){ echo "  🔴 $1"; fail=$((fail+1)); }

echo "===== 検査の3値台帳スイート ====="
[ -f "$TSV" ] || { ng "台帳が無い: $TSV"; echo "-----"; echo "== 赤 検査の3値台帳スイート pass=0 fail=1 =="; exit 1; }

# 1. 値が3つのいずれかであること
bad_lvl=$(awk -F'\t' '!/^#/ && NF>=2 && $2!="ALWAYS_PASSES" && $2!="USUALLY_PASSES" && $2!="USUALLY_FAILS" {print $1" → "$2}' "$TSV")
[ -z "$bad_lvl" ] && ok "水準の値がすべて3値のいずれか" || { ng "水準の値が想定外"; printf '%s\n' "$bad_lvl" | sed 's/^/     /'; }

# 2. **USUALLY_FAILS には期限が要る。** 期限の無い「落ちてよい検査」は、ただの放置である。
no_due=$(awk -F'\t' '!/^#/ && $2=="USUALLY_FAILS" && ($3=="-" || $3=="") {print $1}' "$TSV")
[ -z "$no_due" ] && ok "USUALLY_FAILS にはすべて期限が入っている" || { ng "期限の無い USUALLY_FAILS がある（放置になる）"; printf '%s\n' "$no_due" | sed 's/^/     /'; }

# 3. **期限を過ぎた USUALLY_FAILS は赤。** 「期限までに緑へ動くか」が判定。
today=$(date +%Y-%m-%d)
over=$(awk -F'\t' -v t="$today" '!/^#/ && $2=="USUALLY_FAILS" && $3!="-" && $3!="" && $3<t {print $1" (期限 "$3")"}' "$TSV")
[ -z "$over" ] && ok "期限切れの USUALLY_FAILS は無い" || { ng "期限を過ぎた USUALLY_FAILS がある。**検査ではなく願望なので消すか、閾値を引き直すこと**"; printf '%s\n' "$over" | sed 's/^/     /'; }

# 4. 台帳とスイートの実体を突き合わせる（登録漏れを許さない。自分自身も含める）
real=$(ls tests/run_*.sh 2>/dev/null | xargs -r -n1 basename | sort -u)
reg=$(awk -F'\t' '!/^#/ && $1 ~ /\.sh$/ {print $1}' "$TSV" | sort -u)
miss=$(comm -23 <(printf '%s\n' "$real") <(printf '%s\n' "$reg"))
ghost=$(comm -13 <(printf '%s\n' "$real") <(printf '%s\n' "$reg"))
if [ -z "$miss" ] && [ -z "$ghost" ]; then ok "スイート $(printf '%s\n' "$real" | grep -c .) 本すべてが台帳に水準を持つ"
else
  ng "台帳とスイートの実体が一致しない"
  [ -n "$miss" ]  && printf '%s\n' "$miss"  | sed 's/^/     └ 水準が未登録: /'
  [ -n "$ghost" ] && printf '%s\n' "$ghost" | sed 's/^/     └ 幽霊（台帳にあるが実体が無い）: /'
fi

# 5. **新しい検査を ALWAYS_PASSES から始めてはならない**、の代替として、
#    「ALWAYS_PASSES なのに根拠欄が空」を赤にする。**なぜ常に緑であるべきかを言えないなら、言えていない。**
no_why=$(awk -F'\t' '!/^#/ && NF>=2 && ($4=="" ) {print $1}' "$TSV")
[ -z "$no_why" ] && ok "全行に根拠が書かれている" || { ng "根拠欄が空の行がある"; printf '%s\n' "$no_why" | sed 's/^/     /'; }

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== 検査の3値台帳スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 検査の3値台帳スイート pass=$pass fail=$fail =="; exit 1; fi
