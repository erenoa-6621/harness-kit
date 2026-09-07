#!/usr/bin/env bash
# check_git_identity.sh — コミット名義が期待値と一致しないコミットを実行前に止める PreToolUse フック。
#
# 型の由来: `git config --global` は正しいのに、`-c user.email=` や環境変数で名義が上書きされ、
#   個人メールがコミット履歴に載る事故。履歴の名義は**あとから取り消せない**ので事前に止める。
#
# 期待する名義は harness.conf の GIT_NAME_EXPECTED / GIT_EMAIL_EXPECTED から読む。
#   未設定のまま名義の上書きを含むコミットを打つと、判定できないので止まる（黙って通さない）。
#
# 位置づけ（誇張しない）: これも denylist であり、抜け道はある（環境変数を別の書き方で渡す等）。
#   コマンド文字列に現れない経路（cron・スクリプト内の git）には .githooks/pre-commit を併用する。
#   両方あって初めて意味がある。片方を「守れている」根拠にしない。
#
# 停止スイッチ: このファイルを rm するか、settings.json の該当行を消す。
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${HARNESS_CONF:-$KIT_ROOT/harness.conf}"
GIT_NAME_EXPECTED=""; GIT_EMAIL_EXPECTED=""
[ -f "$CONF" ] && . "$CONF"
WANT_NAME="$GIT_NAME_EXPECTED"
WANT_MAIL="$GIT_EMAIL_EXPECTED"

payload=$(cat)
# ヒアドキュメントの中身は「データ」であって実行されるコマンドではない。
# 回帰検体をヒアドキュメントで書いている最中に、この検査自身に止められた過検知があった。落とす。
cmd=$(printf '%s' "$payload" | python3 -c '
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
c=(d.get("tool_input") or {}).get("command") or ""
for m in re.finditer(r"<<-?\s*[\"\x27]?([A-Za-z_][A-Za-z0-9_]*)[\"\x27]?", c):
    tag = m.group(1)
    body = re.search(r"<<-?\s*[\"\x27]?" + re.escape(tag) + r"[\"\x27]?.*?^\s*" + re.escape(tag) + r"\s*$",
                     c, re.S | re.M)
    if body:
        c = c.replace(body.group(0), " <<" + tag + " " + tag + " ")
sys.stdout.write(c)
' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() {
  echo "🚫 コミット名義が期待値と一致しません: $1" >&2
  if [ -n "$WANT_NAME$WANT_MAIL" ]; then
    echo "   期待する名義は  $WANT_NAME <$WANT_MAIL>  です（harness.conf）。" >&2
  else
    echo "   harness.conf の GIT_NAME_EXPECTED / GIT_EMAIL_EXPECTED が未設定なので判定できません。設定してください。" >&2
  fi
  echo "   コミット履歴の名義は**あとから取り消せません**。個人メールが載ると永久に残ります。" >&2
  echo "   -c を付けないで実行すれば global 設定が使われます。" >&2
  exit 2
}

# 判定: コマンドを区切り（; && || | 改行）でセグメントに割り、各セグメント内で
#       「その git 呼び出しに掛かる上書き」だけを見る。代入は git の直前に連続している場合のみ掛かる。
#       離れた位置の環境変数代入（前段の別コマンドに掛かるもの）を結び付けない。
verdict=$(CMD="$cmd" WN="$WANT_NAME" WM="$WANT_MAIL" python3 <<'PYEOF'
import os, re, sys
cmd, WN, WM = os.environ["CMD"], os.environ["WN"], os.environ["WM"]
MUT = r'(commit|am|cherry-pick|revert|merge|tag)'

# 引用符で囲まれた「引数」は落とす。中身はデータであって実行されるコマンドではない。
# ただし `=` の直後の引用符は**値**なので残す（落とすと -c user.email="bad" が空になって抜け道になる）。
# 引用符を残すときも閉じ引用符まで必ず進める（開き引用符だけ残すと次の引用の始まりと誤認して素通りする）。
out, i, n = [], 0, len(cmd)
while i < n:
    ch = cmd[i]
    if ch in ("'", '"'):
        keep = (i > 0 and cmd[i-1] == '=')
        q = ch; j = i + 1
        while j < n and cmd[j] != q:
            if q == '"' and cmd[j] == "\\":
                j += 1
            j += 1
        span = cmd[i:min(j + 1, n)]
        out.append(span if keep else " ")
        i = j + 1
    else:
        out.append(ch); i += 1
cmd = "".join(out)

for seg in re.split(r'&&|\|\||[;\n|]', cmd):
    seg = seg.strip()
    m = re.search(r'(^|\s)((?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*)git\s+((?:-c\s+\S+\s+)*)' + MUT + r'(\s|$)', seg)
    if not m:
        continue
    assigns, cflags = m.group(2) or "", m.group(3) or ""
    scope = assigns + " " + cflags
    for pat, want, label in [
        (r'(?:user\.email|GIT_AUTHOR_EMAIL|GIT_COMMITTER_EMAIL)\s*=\s*["\']?([^\s"\';&|)]+)', WM, "メール"),
        (r'(?:user\.name|GIT_AUTHOR_NAME|GIT_COMMITTER_NAME)\s*=\s*["\']?([^\s"\';&|)]+)',   WN, "名前"),
    ]:
        for v in re.findall(pat, scope):
            if not want:
                print(f"{label} '{v}'（期待値が未設定）"); sys.exit(0)
            if v != want:
                print(f"{label} '{v}'"); sys.exit(0)
print("")
PYEOF
) || verdict=""
# 正当な用途（使い捨ての bare リポジトリで bot 名義と人間名義を作り分ける検査など）のために、
# **明示的な逃げ道**を1つ用意する。「やってよいが、そう言え」。黙って通す穴は作らない。
if [ -n "$verdict" ] && [ "${ALLOW_IDENTITY_OVERRIDE:-0}" = "1" ]; then
  echo "⚠ ALLOW_IDENTITY_OVERRIDE=1 により名義の上書きを許可した: $verdict" >&2
  exit 0
fi
[ -n "$verdict" ] && deny "$verdict"

exit 0
