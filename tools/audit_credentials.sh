#!/usr/bin/env bash
# audit_credentials.sh — 資格情報の棚卸し（値を絶対に出さない）
#
# なぜ決定論スクリプトなのか: 監査の走査は全て固定手順で、LLM の判断を要したのは所見の言語化だけだった。
#   定型の探索・監視は LLM を使わない。回した量は成果ではない。
#
# なぜ「マスクして表示」をやめたのか:
#   同じ日に、独立した2者が同じ手法でマスク漏れを起こした実測がある。
#   どちらも `s/(gh[pous]_)[A-Za-z0-9]+/\1****/g` 型で、`_` が文字クラスに無いためトークン本体が漏れた。
#   正規表現を1文字間違えるだけで無防備になり、気づくのは出力された後である。手法そのものが不適切。
#   本スクリプトは値を一切出さない。出すのは以下4種の「値でない事実」だけ:
#     存在   : grep -c   （件数）
#     位置   : パス:行番号
#     長さ   : wc -c
#     同一性 : sha256sum の先頭8桁（複数箇所が同じ値かの判定に十分）
#
# 使い方: bash tools/audit_credentials.sh [走査ルート(既定: $HOME)]
# 終了コード:
#   0 = 棚卸しが正常に走った（所見の有無では変えない。所見は人が読む）
#   3 = **自己テストが赤**（＝値を漏らしているかもしれない）。ここだけは必ず非0を返す。
#
# ⚠ 自己テストは「出力に秘密値そのものが含まれていないこと」を確かめる層である。
#   それが赤の状態で緑を返す版があった。**最も安全側であるべき箇所に、最悪の形の握り潰しがあった。**
set -u
ROOT="${1:-$HOME}"
SELFTEST_ONLY="${SELFTEST_ONLY:-0}"

# 秘密らしき値のパターン（本体は絶対に出力しない。ヒットの有無だけに使う）
PAT_RE='(gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
EXCLUDE_RE='/(node_modules|\.git/objects|\.cache|\.npm|\.nvm|vendor|dist|\.next|__pycache__)/'

fingerprint() {  # 値を受け取り、8桁の指紋だけを返す（値は返さない）
  printf '%s' "$1" | sha256sum | cut -c1-8
}

# ─────────────────────────────────────────────────────────
# 自己テスト（検査対象より先に、検査そのものを検査する）
#   ダミーPATを含むフィクスチャに対して走査し、標準出力にPAT本体が現れないことを機械で確認する。
#   ここが赤なら以降の所見は信用できないので即停止する。
# ─────────────────────────────────────────────────────────
selftest() {
  local tmp out rc=0
  tmp=$(mktemp -d) || { echo "❌ SELFTEST: 一時領域を作れない"; return 1; }
  # 実在しないダミー。形式には一致するが失効も何もしない文字列。
  # ⚠ 接頭辞＋本体の並びをこのファイルに**書かない**（リポジトリを公開すると secret scanning が反応しうる）。
  #   実行時に文字列連結で組み立てる。
  local gh_pfx aws_pfx zeros
  gh_pfx="gh"; gh_pfx="${gh_pfx}p_"
  aws_pfx="AK"; aws_pfx="${aws_pfx}IA"
  zeros=$(printf '0%.0s' $(seq 1 34))
  printf 'export GITHUB_TOKEN=%s%sab\n' "$gh_pfx" "$zeros" > "$tmp/.bashrc_fixture"
  printf '%s%s\n' "$aws_pfx" "${zeros:0:16}" >> "$tmp/.bashrc_fixture"

  out=$(scan_files "$tmp" 2>&1)
  # ① 出力にPAT本体（20文字以上の連なり）が1つも無いこと
  if printf '%s' "$out" | grep -Eqc "$PAT_RE" >/dev/null 2>&1 && printf '%s' "$out" | grep -Eq "$PAT_RE"; then
    echo "❌ SELFTEST: 出力に秘密値そのものが含まれている（この検査は使ってはいけない）"; rc=1
  fi
  # ② そのうえで、ちゃんと検出できていること（出さないだけで見逃すのでは意味がない）
  if ! printf '%s' "$out" | grep -q '.bashrc_fixture'; then
    echo "❌ SELFTEST: フィクスチャを検出できていない（見逃し）"; rc=1
  fi
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "✅ 自己テスト緑：値を出さず、かつ見逃さない"
  return $rc
}

# ─────────────────────────────────────────────────────────
# 走査本体（値を出さない）
# ─────────────────────────────────────────────────────────
scan_files() {
  local root="$1" n=0
  while IFS= read -r f; do
    case "$f" in */.git/*|*/node_modules/*) continue ;; esac
    [ -f "$f" ] || continue
    local hits
    hits=$(grep -Ec "$PAT_RE" "$f" 2>/dev/null); hits=${hits:-0}
    [ "${hits:-0}" -gt 0 ] || continue
    # 位置（行番号のみ）と、値の指紋（先頭8桁）だけを出す
    local lines fp
    lines=$(grep -En "$PAT_RE" "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
    fp=$(fingerprint "$(grep -Eo "$PAT_RE" "$f" 2>/dev/null | head -1)")
    printf '  %s  行:%s  件数:%s  指紋:%s\n' "$f" "$lines" "$hits" "$fp"
    n=$((n+1))
  done < <(find "$root" -maxdepth 6 -type f \
             \( -name '.bashrc' -o -name '.zshrc' -o -name '.profile' -o -name '.bash_profile' \
                -o -name '.gitconfig' -o -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' \
                -o -name '.git-credentials' -o -name 'config.json' -o -name '*.env' -o -name '.env' \
                -o -name '*_fixture' \) 2>/dev/null | grep -Ev "$EXCLUDE_RE")
  return 0
}

echo "═══ 資格情報の棚卸し（値は一切出力しない）"
echo "走査ルート: $ROOT   実行: $(date '+%F %T')"
echo
echo "── 0. 自己テスト（ここが赤なら以降は信用しない）"
selftest || { echo; echo "🔴 自己テストが赤。走査を中止する（値を漏らす恐れがあるため）。"; exit 3; }
[ "$SELFTEST_ONLY" = "1" ] && exit 0
echo

echo "── 1. 秘密らしき文字列を含むファイル（パス・行番号・件数・指紋の8桁のみ）"
found=$(scan_files "$ROOT")
if [ -n "$found" ]; then echo "$found"; else echo "  （なし）"; fi
echo
echo "  ※ 指紋が同じ行は同じ値である。別物として片方だけ失効させる事故を防ぐための欄"
echo

echo "── 2. git remote に userinfo（user:pass@）が埋まっているリポジトリ"
c=0
while IFS= read -r g; do
  d=$(dirname "$g")
  if grep -Eq 'url *= *[a-z]+://[^/@]+:[^/@]+@' "$g" 2>/dev/null; then
    ln=$(grep -En 'url *= *[a-z]+://[^/@]+:[^/@]+@' "$g" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
    echo "  $d  行:$ln"; c=$((c+1))
  fi
done < <(find "$ROOT" -maxdepth 5 -type f -path '*/.git/config' 2>/dev/null | grep -Ev "$EXCLUDE_RE")
[ "$c" -eq 0 ] && echo "  （なし）"
echo

echo "── 3. 他人から読める資格情報ファイル（world/group readable）"
c=0
# 固定パスではなく、セクション1と同じファイル集合（.env 系を含む）の権限を見る
while IFS= read -r f; do
  [ -f "$f" ] || continue
  m=$(stat -c '%a' "$f" 2>/dev/null) || continue
  # 見出しどおり「他人から読める」を判定する（旧: 書き込みビットしか見ておらず 644 が素通りしていた）
  case "${m: -2}" in 00) ;; *) echo "  $f  権限:$m  （600 推奨）"; c=$((c+1)) ;; esac
done < <(find "$ROOT" -maxdepth 6 -type f \
             \( -name '.bashrc' -o -name '.zshrc' -o -name '.profile' -o -name '.bash_profile' \
                -o -name '.gitconfig' -o -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' \
                -o -name '.git-credentials' -o -name 'config.json' -o -name '*.env' -o -name '.env' \) 2>/dev/null \
           | grep -Ev "$EXCLUDE_RE")
[ "$c" -eq 0 ] && echo "  （なし）"
echo

echo "── 4. 秘密鍵の権限（.ssh）"
c=0
if [ -d "$ROOT/.ssh" ]; then
  for f in "$ROOT"/.ssh/*; do
    [ -f "$f" ] || continue
    case "$f" in *.pub|*known_hosts*|*config) continue ;; esac
    m=$(stat -c '%a' "$f" 2>/dev/null) || continue
    [ "$m" = "600" ] || { echo "  $f  権限:$m  （600 であるべき）"; c=$((c+1)); }
  done
fi
[ "$c" -eq 0 ] && echo "  （なし）"
echo

echo "── 5. 保存済み認証の所在（中身は開かない。存在の有無のみ）"
for f in "$ROOT/.docker/config.json" "$ROOT/.netrc" "$ROOT/.git-credentials" "$ROOT/.npmrc" "$ROOT/.pypirc" "$ROOT/.config/gh/hosts.yml"; do
  if [ -f "$f" ]; then echo "  存在: $f  （$(wc -c < "$f" | tr -d ' ') bytes）"; fi
done
echo
echo "═══ 棚卸し終了。値は1つも出力していない。"
echo "   失効が必要な場合、実行は人間ゲート（README §人間ゲート）。機械は所在の提示までを行う。"
