#!/usr/bin/env bash
# mutation_check.sh — 「検査が、壊れたときに赤くなるか」を機械で確かめる。
#
# なぜ要るのか:
#   新設した検査が **fail-open** だった実測がある（未処理が0件だと無出力になり、壊れたスクリプトでも
#   「契約どおり」で緑）。変異を撃って初めて分かった。
#   **検査が緑であることは、検査が働いていることの証明ではない。**
#   検査が何も見ていなくても緑は出る。区別する方法は1つしかない：**対象をわざと壊して、赤くなることを確かめる。**
#
# なぜ「規律」ではなく機械なのか:
#   「変異で確かめること」を文章で書いても守られない。**変異を登録していない検査を赤にする**
#   （網羅性の突き合わせは verify.sh 側が持つ）。
#
# 使い方:
#   bash tools/mutation_check.sh            # 全件
#   bash tools/mutation_check.sh <suite名>  # 部分一致で絞る（開発中の1本だけ回す）
#
# 台帳: tests/mutations.tsv
#   列: スイート \t 変異対象 \t sed式 \t 説明
#   sed 式は `sed -i -E` にそのまま渡す。削除は '/pat/d'、置換は 's|a|b|' 。
#
# 【⚠ 実物を壊さない】
#   実ファイルを直接壊して走らせて戻す方式は、変異の最中に別のセッションが動くと**壊れた最中のファイルを掴む。**
#   PreToolUse フックを壊された最中に掴めば、そのセッションの Bash が全部落ちる。
#   さらに強制終了（SIGKILL）されれば trap が走らず、壊れたまま残る。
#   → 変異は**サンドボックス（一時ディレクトリへの写し）の中だけで行う。** 実物には一切触れない。
#     写しに無いものが要るスイートは変異前から赤になり、「判定不能」で赤に落ちる（fail-closed）。
#
# 【この検査が保証すること・しないこと】
#   保証する : 登録した変異について、その検査が赤を出せること
#   保証しない: **網羅性。** 登録していない壊し方は見ていない。
#              変異検査が緑でも「この検査はあらゆる欠陥を捕まえる」とは言わない。denylist を境界と呼ばないのと同じ性質である。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
TSV="$SRC/tests/mutations.tsv"
FILTER="${1:-}"

[ -f "$TSV" ] || { echo "赤: 変異台帳が無い: $TSV"; exit 1; }

SBX="$(mktemp -d)"
cleanup() { rm -rf "$SBX"; }
trap cleanup EXIT INT TERM

# ── サンドボックスを作る ──
#   .git と state/ は検査に要らないので写さない。それ以外のキット直下を全部写す。
for pth in "$SRC"/* "$SRC"/.[!.]*; do
  [ -e "$pth" ] || continue
  case "$(basename "$pth")" in .git|state) continue ;; esac
  cp -a "$pth" "$SBX/" 2>/dev/null
done
# 写しを git 管理下にする（git リポジトリで在ること自体を必要とするスイートのため）。
# 名義は実物と揃える。取れなければキットの既定名義（harness-kit <harness-kit@example.invalid>）。
(
  cd "$SBX" || exit 0
  git init -q 2>/dev/null || exit 0
  git config user.name  "$(git -C "$SRC" config user.name  2>/dev/null || echo harness-kit)"
  git config user.email "$(git -C "$SRC" config user.email 2>/dev/null || echo harness-kit@example.invalid)"
) >/dev/null 2>&1

ROOT="$SBX"

# サンドボックスが作れていなければ、緑を返さない（0件の緑を信用しない）。
if [ ! -x "$ROOT/tools/mutation_check.sh" ] || [ ! -d "$ROOT/tests" ]; then
  echo "赤: サンドボックスの作成に失敗した（写しが不完全）。判定できないものを緑にはしない"
  exit 1
fi

echo "===== 変異検査（検査が壊れたときに赤くなるか）====="

pass=0; fail=0; skipped=0
declare -A BASELINE   # スイートごとの素の判定（緑でなければ変異検査は意味を持たない）

# 出力も取る（どれだけのアサーションが落ちたかを測るため）。
# ⚠ **コマンド置換 `$(run_suite …)` で呼んではいけない。** 置換は副シェルなので変数の代入が親に届かない。
#   → 戻り値も**グローバル変数**で返す。
SUITE_OUT=""; SUITE_RC=0
run_suite() { SUITE_OUT="$( (cd "$ROOT" && bash "$ROOT/$1" 2>&1) )"; SUITE_RC=$?; }

# 全殺しは「スイートが完全に死んでいない」ことしか証明しない。全殺しだけの登録は素通りと同じ。
# → **広い/局所を自己申告させない。落ちたアサーションの割合で機械が測る。**
#   局所（narrow）＝ 落ちたのが半分未満。全殺し（broad）＝ 半分以上。
# → **各スイートに局所の変異が最低1件要る**（下の判定）。
_ratio_kind() {   # スイートの出力から pass=/fail= を拾って kind を返す
  local o="$1" p f tot
  p=$(printf '%s' "$o" | grep -oE 'pass=[0-9]+' | tail -1 | cut -d= -f2)
  f=$(printf '%s' "$o" | grep -oE 'fail=[0-9]+' | tail -1 | cut -d= -f2)
  [ -z "${p:-}" ] || [ -z "${f:-}" ] && { echo "unknown"; return; }
  tot=$((p+f))
  [ "$tot" -eq 0 ] && { echo "unknown"; return; }
  if [ $((f*2)) -lt "$tot" ]; then echo "narrow"; else echo "broad"; fi
}

# `while read` は**最終行に改行が無いとその行を黙って捨てる。** 行数を数えて突き合わせ、捨てられたら赤にする。
tsv_rows=$(grep -vcE '^\s*(#|$)' "$TSV" 2>/dev/null || echo 0)
if [ "$(tail -c1 "$TSV" | wc -l)" -eq 0 ]; then
  echo "赤: 変異台帳の最終行に改行が無い（read が最後の1件を黙って捨てる）: $TSV"
  exit 1
fi
seen_rows=0

while IFS=$'\t' read -r suite target expr note; do
  case "${suite:-}" in ''|'#'*) continue ;; esac
  seen_rows=$((seen_rows+1))
  [ -n "$FILTER" ] && case "$suite" in *"$FILTER"*) ;; *) continue ;; esac

  if [ ! -f "$ROOT/$suite" ]; then
    echo "  ❌ スイートが無い: $suite"; fail=$((fail+1)); continue
  fi
  if [ ! -f "$ROOT/$target" ]; then
    echo "  ❌ 変異対象が無い: $target"; fail=$((fail+1)); continue
  fi

  # 前提: 変異前が緑であること。赤いスイートに変異を撃っても「赤いまま」で通ってしまう（変異検査そのものが fail-open する）。
  if [ -z "${BASELINE[$suite]:-}" ]; then
    run_suite "$suite"; BASELINE[$suite]="$SUITE_RC"
  fi
  if [ "${BASELINE[$suite]}" != "0" ]; then
    echo "  ⏭  前提不成立（変異前から赤）: $suite → 変異検査は判定不能"
    skipped=$((skipped+1)); continue
  fi

  # 退避（同一ファイルへ複数の変異があるので、1変異ごとに戻す）
  bak="$SBX/.bak_$(printf '%s' "$target" | tr '/' '_')"
  cp -p "$ROOT/$target" "$bak"
  before="$(sha256sum "$ROOT/$target" | cut -d' ' -f1)"

  # 変異を撃つ
  sed -i -E "$expr" "$ROOT/$target"
  after="$(sha256sum "$ROOT/$target" | cut -d' ' -f1)"

  if [ "$before" = "$after" ]; then
    # 何も変わっていない ＝ 変異が空振り。**これを緑にすると台帳が飾りになる。**
    echo "  ❌ 変異が空振り（対象が変わっていない）: $note"
    echo "     $target  式: $expr"
    fail=$((fail+1))
    cp -p "$bak" "$ROOT/$target"
    continue
  fi

  run_suite "$suite"; got="$SUITE_RC"
  cp -p "$bak" "$ROOT/$target"   # 次の変異のために必ず戻す（写しの中の話）

  if [ "$got" != "0" ]; then
    pass=$((pass+1))
    k=$(_ratio_kind "$SUITE_OUT")
    printf '%s\t%s\n' "$suite" "$k" >> "$SBX/.kinds"
  else
    fail=$((fail+1))
    echo "  ❌ 変異しても緑のまま（＝この検査は見ていない）: $note"
    echo "     スイート: $suite"
    echo "     対象    : $target"
    echo "     式      : $expr"
  fi
done < "$TSV"

echo "-----"
# 読み落としの検知。**「撃った件数」と「台帳の行数」が合わなければ赤。**
#   絞り込み（$FILTER）を使ったときは件数が合わなくて当然なので、そのときは見ない。
if [ -z "$FILTER" ] && [ "$seen_rows" -ne "$tsv_rows" ]; then
  echo "赤: 台帳 $tsv_rows 行のうち $seen_rows 行しか読めていない（read が行を捨てている）"
  exit 1
fi
# **各スイートに「局所（narrow）」の変異が最低1件あること。** 絞り込み実行のときは全体像が取れないので見ない。
broad_only=""
if [ -z "$FILTER" ] && [ -f "$SBX/.kinds" ]; then
  for sut in $(cut -f1 "$SBX/.kinds" | sort -u); do
    if ! awk -F'\t' -v s="$sut" '$1==s && $2=="narrow"{f=1} END{exit f?0:1}' "$SBX/.kinds"; then
      broad_only="$broad_only $sut"
    fi
  done
fi
if [ -n "$broad_only" ]; then
  echo "  ⚠ 局所の変異が無いスイート（全殺しだけでは「死んでいない」しか言えない）:"
  for x in $broad_only; do echo "     - $x"; done
  echo "     → **落ちたアサーションが半分未満**になる変異を1件以上足すこと。"
  fail=$((fail+1))
fi

if [ "$fail" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "== 変異検査 pass=$pass fail=0 =="; exit 0
else
  echo "== 赤 変異検査 pass=$pass fail=$fail 判定不能=$skipped =="; exit 1
fi
