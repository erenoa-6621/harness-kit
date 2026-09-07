#!/usr/bin/env bash
# pii_check.sh — 公開候補パスに個人情報（個人メール・旧ハンドル等）が無いことを検査する。値は出さない。
#
# 型の由来: 公開する予定のスクリプトや文書の**本文コメント**に、個人メールが平文で残っていた実測。
#   コミット名義の検査はあっても、ファイル本文の PII は誰も検査していなかった。
#   置換はしても、**検査が無ければ再混入を止められない。**
#
# 設計:
#   1. 判定する値（実際の個人メール・旧ハンドル）は**このスクリプトに平文で書かない**。
#      公開候補パスの検査器そのものが PII を運ぶのは本末転倒である。
#      値は tools/.pii_patterns.local（.gitignore 対象）に置く。**無ければ「検査不能」で赤**。黙って緑にしない。
#   2. 加えて汎用の正規表現（フリーメール宛先の形）を組み込みで持つ。局所ファイルが無くても、この層は必ず走る。
#      `noreply@...` と `<...>` プレースホルダは除外する。
#   3. 出力は **パス:行番号 だけ**。一致した文字列は出さない（マスクして表示も禁止。正規表現を1文字間違えるだけで漏れる）。
#   4. 空振り検知: 走査したファイルが 0 件なら赤（対象パスの綴り違い・glob 不展開を緑にしない）。
#      存在しない対象を渡されたときも赤。
#   5. 秘密ファイル（`*.local`・`.env*`・secrets/・鍵）は**走査対象から外す**。
#      grep -f で読むだけでも「フィルタ経由で秘密ファイルを開く」ことになる。
#
# ── tools/.pii_patterns.local の作り方 ──
#   1行1パターン。**固定文字列**（正規表現ではない）・大文字小文字は区別しない。
#   `#` で始まる行と空行は無視する。有効な行が 0 なら「検査不能」で赤。
#     $ printf '%s\n' '<個人メールの実値>' '<旧ハンドルの実値>' > tools/.pii_patterns.local
#   .gitignore に載っている。**コミットしない。**
#
# 使い方:
#   bash tools/pii_check.sh [-p PATTERNS_FILE] [-x EXCLUDE_REGEX] [-C] TARGET...
#     TARGET はファイルまたはディレクトリ（ディレクトリは再帰）。
#     -p 省略時は $PII_PATTERNS_FILE、それも無ければ tools/.pii_patterns.local。
#     -x は走査から外すパスの正規表現（既定の除外に追加される）。
#     -C は「供給されない層モード」（CI 用）。**局所パターンファイルの不在**と
#        **対象パスの不在**を、赤ではなく ⏭ スキップ1行にする。組み込み層は必ず走る。
#        黙ってスキップしない（必ず1行出す）。全対象が不在で走査 0 件なら -C でも赤（空振り検知は残す）。
#
#   ⚠ -C は「検査を緩めるスイッチ」ではなく「その層の材料が原理的に無い環境」でだけ使う。
#     局所ファイルは .gitignore 対象で CI に存在しえない。材料の不在を「検査の赤」と混ぜると、
#     CI が恒久的に赤くなり、赤が情報を持たなくなる（狼少年）。ローカル（材料が在るべき環境）では -C を付けない。
# 終了コード:
#   0 = 全対象に PII 無し
#   1 = PII らしき行がある（パス:行番号 を出す）
#   2 = 検査不能（パターン局所ファイル無し／有効パターン 0／対象 0 件／対象が存在しない／grep 失敗）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAT_FILE="${PII_PATTERNS_FILE:-$HERE/.pii_patterns.local}"
EXTRA_EXCLUDE=""
SOFT=0   # -C: 材料が原理的に無い層を ⏭ スキップにする（CI 用）
while getopts "p:x:C" opt; do
  case "$opt" in
    p) PAT_FILE="$OPTARG" ;;
    x) EXTRA_EXCLUDE="$OPTARG" ;;
    C) SOFT=1 ;;
    *) echo "usage: $0 [-p PATTERNS_FILE] [-x EXCLUDE_REGEX] [-C] TARGET..." >&2; exit 2 ;;
  esac
done
shift $((OPTIND-1))
[ "$#" -ge 1 ] || { echo "🔴 検査不能: 対象パスが指定されていない"; exit 2; }

# 組み込みの汎用パターン（フリーメールの宛先の形）。個人の実値は含まない。
BUILTIN_RE='[A-Za-z0-9._%+-]+@(gmail|yahoo|outlook|icloud|hotmail)\.[a-z.]+'
# 除外: `<...>` プレースホルダと noreply@ は照合の前に取り除く（行番号は保たれる）。
#   ⚠ プレースホルダとして除くのは **@ を含まない** `<...>` だけ。`<[^<>]*>` を丸ごと除くと、
#   git 名義の形 `名前 <実メール>` に入った実メールを見逃す（実測あり）。
#   「角括弧で囲まれている」はプレースホルダの証拠ではない。
STRIP_SED='s/<[^<>@]*>//g; s/[A-Za-z0-9._%+-]*noreply@[A-Za-z0-9.-]+//g'
# 走査から外すパス。秘密ファイルは「フィルタ経由でも開かない」。
DEFAULT_EXCLUDE='(/\.git/|/node_modules/|/__pycache__/|\.local$|/\.env(\.|$)|/secrets/|\.pem$|\.key$|/state/)'

TMP=$(mktemp -d) || { echo "🔴 検査不能: 一時領域を作れない"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── 1. パターン局所ファイル（無ければ検査不能） ──
unfit=0
if [ ! -f "$PAT_FILE" ]; then
  if [ "$SOFT" -eq 1 ]; then
    # CI には .gitignore 対象の局所ファイルが原理的に無い。組み込み層だけで走る。
    echo "⏭ 局所パターン層はスキップ（-C／パターン局所ファイルが無い: $PAT_FILE）。組み込み層は走る"
  else
    echo "🔴 検査不能: パターン局所ファイルが無い: $PAT_FILE"
    echo "   1行1固定文字列で置くこと（作り方はこのスクリプト冒頭のコメント）。黙って緑にはしない。"
    unfit=1
  fi
else
  grep -Ev '^[[:space:]]*(#|$)' "$PAT_FILE" > "$TMP/pat" 2>/dev/null
  if [ ! -s "$TMP/pat" ]; then
    echo "🔴 検査不能: パターン局所ファイルに有効な行が無い: $PAT_FILE"
    unfit=1
  fi
fi

# ── 2. 対象ファイルの列挙（空振り検知） ──
missing=0
: > "$TMP/files"
for t in "$@"; do
  if [ -d "$t" ]; then
    find "$t" -type f -print 2>/dev/null >> "$TMP/files"
  elif [ -f "$t" ]; then
    printf '%s\n' "$t" >> "$TMP/files"
  elif [ "$SOFT" -eq 1 ]; then
    echo "⏭ 対象が無いのでスキップ（-C）: $t"
  else
    echo "🔴 検査不能: 対象が存在しない: $t（glob が展開されていないか、パスの綴り違い）"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || unfit=1
if [ -n "$EXTRA_EXCLUDE" ]; then
  grep -Ev "$DEFAULT_EXCLUDE" "$TMP/files" | grep -Ev "$EXTRA_EXCLUDE" > "$TMP/files2"
else
  grep -Ev "$DEFAULT_EXCLUDE" "$TMP/files" > "$TMP/files2"
fi
nfiles=$(grep -c . "$TMP/files2" 2>/dev/null); nfiles=${nfiles:-0}
if [ "$nfiles" -eq 0 ]; then
  echo "🔴 検査不能: 走査対象が 0 件（対象パスが全て除外されたか、空）。0 件の緑は信用しない"
  unfit=1
fi

# ── 3. 走査（出すのは パス:行番号 だけ） ──
hits=0; grep_fail=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # テキストファイルだけ。バイナリは -I で読み飛ばす
  grep -Iq . "$f" 2>/dev/null || continue
  # 3-a 組み込み正規表現（プレースホルダと noreply を取り除いてから照合）。
  #     grep の終了コードは $(...) の中では取れない（PIPESTATUS が消える）ので、一時ファイル経由で見る。
  sed -E "$STRIP_SED" "$f" 2>/dev/null > "$TMP/stripped"
  grep -En "$BUILTIN_RE" "$TMP/stripped" > "$TMP/hit" 2>/dev/null; rc=$?
  [ "$rc" -ge 2 ] && grep_fail=1
  for ln in $(cut -d: -f1 "$TMP/hit"); do echo "🔴 PII(組み込み: フリーメール形式): $f:$ln"; hits=$((hits+1)); done
  # 3-b 局所パターン（固定文字列・大小無視）
  if [ -s "$TMP/pat" ]; then
    grep -Fin -f "$TMP/pat" "$f" > "$TMP/hit" 2>/dev/null; rc=$?
    [ "$rc" -ge 2 ] && grep_fail=1
    for ln in $(cut -d: -f1 "$TMP/hit"); do echo "🔴 PII(局所パターン): $f:$ln"; hits=$((hits+1)); done
  fi
done < "$TMP/files2"

if [ "$grep_fail" -ne 0 ]; then
  echo "🔴 検査不能: grep が失敗した。判定できないものを緑にはしない"
  unfit=1
fi

echo "走査 ${nfiles} ファイル / PII らしき行 ${hits} / パターン局所ファイル $([ -s "$TMP/pat" ] && echo 有 || echo 無)"
if [ "$hits" -gt 0 ]; then exit 1; fi
if [ "$unfit" -ne 0 ]; then exit 2; fi
echo "🟢 公開候補パスに PII 無し"
exit 0
