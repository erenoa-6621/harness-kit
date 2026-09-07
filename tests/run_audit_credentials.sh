#!/usr/bin/env bash
# tools/audit_credentials.sh の回帰スイート。
#
# 分かれ目:
#   赤: 644 の .env は「他人から読める」として1行出る（旧実装は固定7パスで .env を見ず、
#       かつ書き込みビットしか判定しておらず 644 が素通りしていた）
#   緑: 600 の .netrc は出ない
#   stderr: 秘密パターン不一致のファイルがあっても stderr が空（旧: integer expression error ×3）
# 検体は架空値。値は表示しない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="$HERE/../tools/audit_credentials.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
printf 'EXAMPLE_FLAG=1\n' > "$TMP/.env";   chmod 644 "$TMP/.env"
printf 'machine example\n' > "$TMP/.netrc"; chmod 600 "$TMP/.netrc"
out=$(bash "$CHK" "$TMP" 2>"$TMP/err")
sec3=$(printf '%s\n' "$out" | sed -n '/── 3\./,/── 4\./p')
if printf '%s' "$sec3" | grep -q '/\.env  権限:644'; then pass=$((pass+1)); else fail=$((fail+1)); echo "  NG 644 の .env が検出されない"; fi
if printf '%s' "$sec3" | grep -q '/\.netrc'; then fail=$((fail+1)); echo "  NG 600 の .netrc が誤検出"; else pass=$((pass+1)); fi
if [ -s "$TMP/err" ]; then fail=$((fail+1)); echo "  NG stderr が空でない:"; sed 's/^/     | /' "$TMP/err"; else pass=$((pass+1)); fi
echo "-----"
if [ "$fail" -eq 0 ]; then echo "== 資格情報監査の回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 資格情報監査の回帰スイート pass=$pass fail=$fail =="; exit 1; fi
