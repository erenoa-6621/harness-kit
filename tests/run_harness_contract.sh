#!/usr/bin/env bash
# フックの配線（settings.json.example）と入出力契約のスイート。
#
# なぜ在るか:
#   Stop フックが JSON を2行出力して壊れた事故がある。その事故が起きた**まさにその経路**に機械の検査が無かった。
#   「stop を叩いて JSON になるか」を生の状態で観察するだけの検査は、**差し戻す理由が無くなると無出力になり、
#   壊れたスクリプトでも『無出力＝契約どおり』で緑になる**（fail-open）。
#   だから状態に依存せず、**話さざるを得ない環境**と**黙るべき環境**を人工的に作って撃つ。
#
# 契約:
#   settings.json.example … 有効な JSON。command は "${CLAUDE_PROJECT_DIR}/…" だけを指す（$HOME の fallback を持たない）。
#                           指した先のファイルはキットに実在し、hooks/ の実体は全部配線されている。
#   Stop フック          … 差し戻すときは1オブジェクトの JSON（decision=block）／差し戻さないときは無出力
#   PreToolUse フック    … 止めるときは exit 2（stdout は空・理由は stderr）／通すときは exit 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SETTINGS="$ROOT/settings.json.example"
pass=0; fail=0
ng(){ echo "  🔴 $1"; fail=$((fail+1)); }
okk(){ echo "  🟢 $1"; pass=$((pass+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
is_one_json(){ printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,dict) else 1)' 2>/dev/null; }

echo "===== フック契約スイート ====="

# ── 1. settings.json.example の配線 ──
if [ -f "$SETTINGS" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" 2>/dev/null; then
  okk "settings.json.example は有効な JSON"
else
  ng "settings.json.example が無いか JSON として壊れている"; echo "-- フック契約: pass=$pass fail=$fail"; exit 1
fi
cmds=$(python3 - "$SETTINGS" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for ev,groups in (d.get("hooks") or {}).items():
    for g in groups:
        for h in g.get("hooks",[]):
            print(h.get("command",""))
PY
)
ncmd=$(printf '%s\n' "$cmds" | grep -c .)
[ "$ncmd" -gt 0 ] && okk "配線されたフックが ${ncmd} 本ある（0本の緑を信用しない）" || ng "配線されたフックが0本"
bad=$(printf '%s\n' "$cmds" | grep -v '\${CLAUDE_PROJECT_DIR}/' || true)
[ -z "$bad" ] && okk "全 command が \${CLAUDE_PROJECT_DIR}/ 起点" || { ng "\${CLAUDE_PROJECT_DIR}/ 起点でない command がある"; printf '%s\n' "$bad" | sed 's/^/     /'; }
bad=$(printf '%s\n' "$cmds" | grep -E '\$HOME|~/|:-' || true)
[ -z "$bad" ] && okk "command に \$HOME / ~ / :- の fallback が無い" || { ng "fallback を持つ command がある（別の場所のフックを黙って拾う）"; printf '%s\n' "$bad" | sed 's/^/     /'; }
missing=0; wired=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  rel=$(printf '%s' "$c" | grep -oE '\$\{CLAUDE_PROJECT_DIR\}/[^" ]+' | head -1 | sed 's|^\${CLAUDE_PROJECT_DIR}/||')
  [ -n "$rel" ] || continue
  wired="$wired $rel"
  [ -f "$ROOT/$rel" ] || { missing=1; echo "     └ 実体が無い: $rel"; }
done <<< "$cmds"
[ "$missing" -eq 0 ] && okk "command が指す先は全部キットに実在する" || ng "command が指す先に実体の無いものがある"
unwired=""
for f in "$ROOT"/hooks/*.sh "$ROOT"/hooks/*.py; do
  [ -f "$f" ] || continue
  case " $wired " in *" hooks/$(basename "$f") "*) ;; *) unwired="$unwired hooks/$(basename "$f")" ;; esac
done
[ -z "$unwired" ] && okk "hooks/ の実体は全部 settings.json.example に配線されている" || { ng "配線されていないフックがある（足して配線を忘れると緑のまま検査が消える）:$unwired"; }

# ── 2. Stop フックの契約（状態に依存させない。偽ルートを作る）──
HOOK="$ROOT/hooks/unfinished_action.py"
FR="$TMP/root"; mkdir -p "$FR/state"
printf 'epoch=%s\nred=0\nhead=x\n' "$(( $(date +%s) + 3600 ))" > "$FR/state/last_verify_result"
stop_out() {  # $1=最終メッセージ
  MSG="$1" python3 -c '
import json,os,sys
sys.stdout.write(json.dumps({"stop_hook_active":False,"session_id":"contract","last_assistant_message":os.environ["MSG"]}))' \
  | CLAUDE_PROJECT_DIR="$FR" UA_TEST=1 python3 "$HOOK" 2>/dev/null
}
# 2-a 黙るべき環境: 無出力でなければ赤（喋りすぎ方向は無防備になりやすい）
out=$(stop_out "記録しました。以上です。")
if [ -z "$out" ]; then okk "Stop: 差し戻す理由が無いときは無出力（黙るべきときに黙る）"
elif is_one_json "$out"; then ng "Stop: 黙るべき環境で喋った＝過検知: $(printf '%s' "$out" | head -c 120)"
else ng "Stop: 黙るべき環境で JSON でない出力: $(printf '%s' "$out" | head -c 100)"; fi
# 2-b 話さざるを得ない環境: **ここが本命**。2行出力ならここで落ちる
out=$(stop_out "起動します。")
if [ -z "$out" ]; then ng "Stop: 宣言があるのに無出力（検査が空振りする＝fail-open の再発）"
elif is_one_json "$out"; then
  okk "Stop: 差し戻すとき1オブジェクトの JSON を返す（2行出力ならここで赤）"
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" and d.get("reason") else 1)' \
    && okk "Stop: decision=block と reason を持つ" || ng "Stop: decision=block / reason が無い"
else ng "Stop: JSON として1オブジェクトでない（2行出力の再発を疑え）: $(printf '%s' "$out" | head -c 120)"; fi
# 2-c 壊れた入力でも例外を吐かず落ちない（stderr にトレースバックを出す＝フックが壊れて全 Stop が失敗する）
err=$(printf 'not json' | CLAUDE_PROJECT_DIR="$FR" UA_TEST=1 python3 "$HOOK" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$err" ] && okk "Stop: 壊れた入力でも exit 0・stderr 無し" || ng "Stop: 壊れた入力で rc=$rc / stderr: $(printf '%s' "$err" | head -c 100)"

# ── 3. PreToolUse フックの契約 ──
CONF="$TMP/harness.conf"; printf 'READONLY_AGENTS="kensho"\nGIT_NAME_EXPECTED="Some One"\nGIT_EMAIL_EXPECTED="someone@example.invalid"\n' > "$CONF"
pre() {  # $1=hook $2=agent_type $3=command → stdout を $TMP/out・stderr を $TMP/err に。rc を返す
  CMD="$3" ATYPE="$2" python3 -c '
import json,os,sys
d={"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}
if os.environ["ATYPE"]: d["agent_type"]=os.environ["ATYPE"]
sys.stdout.write(json.dumps(d))' | HARNESS_CONF="$CONF" bash "$ROOT/hooks/$1" >"$TMP/out" 2>"$TMP/err"
}
pre deny_mutations.sh kensho "rm -rf ./docs"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ] && okk "deny_mutations: 止めるときは exit 2・stdout 空・理由は stderr" \
  || ng "deny_mutations: 止める契約が崩れている（rc=$rc stdout=$(wc -c <"$TMP/out")B stderr=$(wc -c <"$TMP/err")B）"
pre deny_mutations.sh kensho "ls -l"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && okk "deny_mutations: 通すときは exit 0・stdout 空" || ng "deny_mutations: 通す契約が崩れている（rc=$rc）"
pre check_git_identity.sh "" "git -c user.email=BADMAIL commit -m x"; rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ] && okk "check_git_identity: 止めるときは exit 2・stdout 空・理由は stderr" \
  || ng "check_git_identity: 止める契約が崩れている（rc=$rc）"
pre check_git_identity.sh "" "git status"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && okk "check_git_identity: 通すときは exit 0・stdout 空" || ng "check_git_identity: 通す契約が崩れている（rc=$rc）"
# 壊れた入力（JSON でない）でも exit 0 で通す（フックの故障で全 Bash が止まらない）
printf 'not json' | HARNESS_CONF="$CONF" bash "$ROOT/hooks/deny_mutations.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && okk "deny_mutations: JSON でない入力は exit 0（故障で全 Bash を止めない）" || ng "deny_mutations: JSON でない入力で rc=$rc"

echo "-- フック契約: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
