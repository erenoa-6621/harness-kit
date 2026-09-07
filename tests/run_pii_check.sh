#!/usr/bin/env bash
# tools/pii_check.sh の回帰スイート。
#
# なぜ要るか: 公開候補パスの本文に個人メールが残っていた実測がある。置換はしたが検査が無く、再混入を止められない。
#   pii_check.sh がその唯一の機構なので、**判定の分かれ目に検体を置く**。
#
#   3本の分かれ目:
#     赤: 個人メール入りの偽ファイル（架空値のフリーメール。この注釈にもその形は書かない＝自分が引っかかる）
#     緑: プレースホルダ・noreply だけ（**過検知側**。ここが赤だと置換済みの実物まで落ちる）
#     赤: パターン局所ファイル不在（「検査不能」を黙って緑にしない）
#   加えて、旧ハンドル（局所パターン）・空振り（対象 0 件）・有効パターン 0 の3つ。
#
# 検体はすべて架空値。実在の個人メール・ハンドルはここにも書かない。
# 局所パターンは一時ファイルに架空値を書いて渡す。tools/.pii_patterns.local には触らない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="$HERE/../tools/pii_check.sh"
S="$HERE/pii_samples"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# 架空の局所パターン（旧ハンドルの形。実値ではない）
printf '# コメント行は無視される\n\nOLD-HANDLE-EXAMPLE\n' > "$TMP/pat"
: > "$TMP/empty_pat"
mkdir -p "$TMP/empty_dir"

run() {  # 期待exit 説明 -- 引数...
  local want="$1" note="$2"; shift 2
  local out got
  out=$(bash "$CHK" "$@" 2>&1); got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1))
  else
    fail=$((fail+1))
    printf '  NG %s\n     want=%s got=%s\n%s\n' "$note" "$want" "$got" "$(printf '%s\n' "$out" | sed 's/^/     | /')"
  fi
  # 値の非表示: 出力に検体の架空メールそのものが現れてはいけない（パス:行番号 だけ）
  if printf '%s' "$out" | grep -q 'someone@gmail'; then
    fail=$((fail+1)); printf '  NG 出力に一致文字列そのものが現れている [%s]\n' "$note"
  fi
}

echo "===== PII 検査の回帰スイート ====="
# 分かれ目 3本（発注の必須）
run 1 "赤: 個人メール入りの偽ファイル"                 -p "$TMP/pat" "$S/bad_personal_mail.md"
run 0 "緑: プレースホルダ・noreply だけ（過検知側）"     -p "$TMP/pat" "$S/ok_placeholder.md"
run 2 "赤: パターン局所ファイル不在＝検査不能"          -p "$TMP/does_not_exist" "$S/ok_placeholder.md"
# 追加
run 1 "赤: 旧ハンドル（局所パターン・大小無視）"        -p "$TMP/pat" "$S/bad_old_handle.md"
run 2 "赤: 空振り（対象ディレクトリが空）"              -p "$TMP/pat" "$TMP/empty_dir"
run 2 "赤: 対象が存在しない（glob 不展開）"             -p "$TMP/pat" "$S/no_such_file.md"
run 2 "赤: 有効パターンが 0 行＝検査不能"               -p "$TMP/empty_pat" "$S/ok_placeholder.md"
run 1 "赤: 角括弧の名義形 名前 <メール> を見逃さない"     -p "$TMP/pat" "$S/bad_angle_bracket_mail.md"
run 1 "赤: ディレクトリ再帰で検体4本中3本を拾う"        -p "$TMP/pat" "$S"
run 1 "赤: 局所ファイル不在でも組み込み層は走り、PII を報告する" -p "$TMP/does_not_exist" "$S/bad_personal_mail.md"

# ── -C（材料が原理的に無い層のスキップ。CI 用）──────────────────────────
# .pii_patterns.local は .gitignore 対象で CI には無い。無い材料を「検査の赤」と混ぜると CI が恒久赤になり、
# 赤が情報を持たなくなる。**緩める方向の変更なので、対になる検体を同じ場所に置く。**
run 0 "緑: -C＋局所ファイル不在＝スキップして続行（PII 無しの検体）"  -C -p "$TMP/does_not_exist" "$S/ok_placeholder.md"
run 1 "赤: -C でも組み込み層は走る（PII 入りの検体は赤のまま）"        -C -p "$TMP/does_not_exist" "$S/bad_personal_mail.md"
run 1 "赤: -C でも局所ファイルが在れば局所層は走る（旧ハンドル）"      -C -p "$TMP/pat" "$S/bad_old_handle.md"
run 0 "緑: -C＋対象の一部が不在＝スキップして残りを走査"              -C -p "$TMP/pat" "$S/no_such_file.md" "$S/ok_placeholder.md"
run 2 "赤: -C でも全対象が不在なら空振り検知は残る"                    -C -p "$TMP/pat" "$S/no_such_file.md"

# スキップは**黙って**行わない（1行出す）。出さないスキップは fail-open と同じ。
say_skip() { # 説明 -- 引数...
  local note="$1"; shift
  local out; out=$(bash "$CHK" "$@" 2>&1)
  if printf '%s' "$out" | grep -q '⏭'; then pass=$((pass+1))
  else fail=$((fail+1)); printf '  NG %s: ⏭ のスキップ行が出ていない\n%s\n' "$note" "$(printf '%s\n' "$out" | sed 's/^/     | /')"; fi
}
say_skip "局所ファイル不在のスキップを1行出す" -C -p "$TMP/does_not_exist" "$S/ok_placeholder.md"
say_skip "対象不在のスキップを1行出す"         -C -p "$TMP/pat" "$S/no_such_file.md" "$S/ok_placeholder.md"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== PII 検査の回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 PII 検査の回帰スイート pass=$pass fail=$fail =="; exit 1; fi
