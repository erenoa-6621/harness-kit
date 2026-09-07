#!/usr/bin/env bash
# deny_mutations.sh — 読み取り専用の役（サブエージェント）が Bash で変更操作を行うのを機構で止める PreToolUse フック。
#
# 型の由来: 「書き手と検証者の分離」を文章で書いても、Write を持たない役が Bash を持てば
#   `sed -i` も `git commit` も `rm` も `> file` も実行できる。分離は**散文の規律**であって、機構ではなかった。
#   モデルの判断に関わらず行動を止めるには、PreToolUse フックで exit 2 を返す。
#
# 位置づけ（誇張しない）:
#   これは **既知の書き込み構文に対する決定論的なつまずき石**である。
#   「読み取り専用の強制」でも「決定的な境界」でもない。そう呼ばないこと。
#   実測では、発火しない（配線が赤）→ python3/node/ed/sed の経路がすり抜ける → 塞ぐと別の経路が見つかる、
#   を繰り返した（os.system・pathlib の touch・tempfile.mkstemp・open の別名渡し・node の openSync・API 名の文字列連結）。
#   denylist の拡張はいたちごっこで、ラウンドを重ねるほど「塞いだ」という誤った安心が育つ。
#   恒久策は環境層（permissions.deny / sandbox）であって自作の層ではない。
#   それでもこの層を残す理由: 素の書き込み構文は確実に止まり、多層防御の一層としては有効だから。
#   単独で「守れている」根拠にしないだけである。
#
# 過検知について: **過検知は「安全側」ではない。** 検査の検体を作れなくなり、測れない分だけ未検証領域が増える。
#   これまでに解消した過検知（いずれも実測。対になる「止める側」の検体を tests/run_hooks.sh に置いてある）:
#     (a) ヒアドキュメント本体・コメント中の `>=` `->` を「リダイレクト」と読んだ → 本体とコメントをシェル構文の判定から外す
#     (b) 同一コマンド内で代入した変数（S=/tmp/…; mkdir -p $S/x）を展開せず、$S が /tmp に合わず止めた → 展開してから判定
#     (c) open(変数,'w') を「判定不能＝止める」にしていた → 同一コード内の代入を辿る。辿れなければ warn を出して通す
#     (d) `git stash list` を「git 変更系」で止めた → list/show は読み取りとして通す
#     (e) `subprocess.` というトークンが在るだけで止めた → 起動されるコマンドで判定する
#     (f) `$(mktemp -d)` 配下・`chmod +x`・`str.replace`・`echo sed -i` を止めた → それぞれ判定を絞った
#     (g) `sed` の呼び出しと `w` の在処を別々に見て、ループ変数 `w` で止めた → sed のスクリプト部だけを見る
#     (h) 一時領域の写しへの `sed -i` を止めた → 書き先が全部一時領域なら通す
#   **まだ通るもの（正直に書く。塞いだと言わない）**:
#     `from subprocess import run` のように `subprocess.` を経ない呼び出し／`os.popen` `os.exec*` `os.spawn*`／
#     起動先が自作スクリプトや `python3 script.py`（中身を静的に読めない→warn を出して通す）／
#     `bash -c "$VAR"`・`eval "$VAR"`・`find … -exec 自作スクリプト`（同じく静的に読めない→warn を出して通す）／
#     `shell=True` で一時領域だけを触る変更系（シェル判定と同じく通る。argv リストで書くと止まる非対称がある）。
#
# 対象の役は harness.conf の READONLY_AGENTS（空白区切りの agent_type）。
# 停止スイッチ: このファイルを rm するか、settings.json の該当行を消す。
set -uo pipefail

payload=$(cat)

# 読み取り専用の役だけを対象にする。
# settings.json の PreToolUse から呼ばれると主セッションにも入力が来るため、agent_type で絞る。
# agent_type が無い（＝主セッション）ときは何もしない。
#   --force : サブエージェント定義(frontmatter)から呼ばれた。定義自体が対象を限定しているので無条件に検査する。
#   引数なし: settings.json から呼ばれた。agent_type が READONLY_AGENTS のときだけ検査する。
# ⚠ 「agent_type が空なら素通り」を取り違えると、**主セッションで git commit も rm も全部 exit 2 で止まる**。
#   ゲートを足すときは「対象でない者に何が起きるか」を必ず先に試すこと（tests/run_hooks.sh F節）。
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${HARNESS_CONF:-$KIT_ROOT/harness.conf}"
READONLY_AGENTS=""
[ -f "$CONF" ] && . "$CONF"
MODE="${1:-gated}"
if [ "$MODE" != "--force" ]; then
  atype=$(printf '%s' "$payload" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
sys.stdout.write(str(d.get("agent_type") or d.get("subagent_type") or ""))
' 2>/dev/null) || atype=""
  # agent_type が取れない＝主セッション。ここで止めない（止めると全部が動かなくなる）
  [ -n "$atype" ] || exit 0
  # 設定が無ければ判定できない。黙って通さない（サブエージェントの Bash は止まる。直すのは harness.conf）
  if [ -z "$READONLY_AGENTS" ]; then
    echo "🚫 deny_mutations: harness.conf の READONLY_AGENTS が空か、harness.conf が無い（$CONF）。判定できないので止める。" >&2
    echo "   READONLY_AGENTS を設定するか、このフックを settings.json から外すこと。" >&2
    exit 2
  fi
  case " $READONLY_AGENTS " in
    *" $atype "*) ;;      # 対象。検査を続ける
    *) exit 0 ;;          # 書く役は対象外
  esac
fi

cmd=$(printf '%s' "$payload" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti=d.get("tool_input") or {}
sys.stdout.write(ti.get("command") or "")
' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() {
  echo "🚫 読み取り専用の役割では、この操作は実行できません: $1" >&2
  echo "   あなたは対象を変更しない役です（README §各部品）。" >&2
  echo "   変更が必要なら、呼び出し元へ『変更が要る』と事実を報告して差し戻してください。" >&2
  echo "   自分で直さないことが、あなたの価値です（書き手と検証者の分離）。" >&2
  exit 2
}

# ─────────────────────────────────────────────────────────
# 判定本体（実測の過検知を受けて2度書き直した）
#
# 旧版は生のコマンド文字列を grep していたため、**引用符の中身**まで見てしまい
# 監査の役が過検知を5件実測した:
#     echo 'A -> B' / ls -l >/dev/null / awk '{if(a>b)print}'
#     git log --format='%an <%ae>' / crontab -l
# とくに `crontab -l` の阻止は実害だった。**監査の役が cron の配線（停止＝配線ごと止める運用）を
# 点検できなくなった。ガードがガードの検査を妨げていた。**
#
# 直し方: 引用符で囲まれた literal を落としてから判定する。
#         出力抑止（>/dev/null）と fd 複製（2>&1）は書き込みではないので通す。
#         読み取り専用のサブコマンド（crontab -l 等）は明示的に通す。
#
# 現在の構造: 文字列を2系統に分けて見る。
#   shell 系（c）  = ヒアドキュメント本体・コメント・引用符の中身を落とし、変数を展開したもの。④⑤⑦ のシェル構文判定に使う。
#   code  系（code）= 変数展開だけした生の文字列（ヒアドキュメント本体・引用符の中身を含む）。⑥ のインタプリタ判定に使う。
# ─────────────────────────────────────────────────────────
verdict=$(CMD="$cmd" python3 <<'PYEOF'
import os, re, sys

cmd = os.environ.get("CMD", "")
warns = []

# ⓪ 行継続（バックスラッシュ＋改行）は1行に戻す。
#   実測: `mkdir -p /tmp/.../a \` + 改行 + `/tmp/.../b` が「mkdir」で止まった。
#   原因: 後段の SEGS が改行でセグメントを割るので、1行目が `mkdir -p /tmp/.../a \` になり、
#   末尾の `\` が書き先の引数として数えられて TMP_RE に合わず、全部 /tmp なのに落ちた。
#   継続行は同一コマンドなので、割る前に繋ぐ。
cmd_joined = re.sub(r'\\\n', ' ', cmd)

# ⓪-a ヒアドキュメント本体を shell 系から外す（過検知 (a)）。
#   `python3 - <<'EOF' … likes>=20 … EOF` の本体は python に渡る**データ**であって、シェルが解釈するリダイレクトではない。
#   check_git_identity.sh と同じ原則。ただし受け手が bash/sh/eval のときは本体がそのまま実行されるので落とさない
#   （`bash <<EOF … rm -rf docs … EOF` を通してしまわないため）。
_HEREDOC_RE = re.compile(r"<<-?\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\1")
_SHELL_CONSUMER = re.compile(r'^(?:(?:ba|z|da|k)?sh|eval|source|\.)$')
def _strip_heredocs(text):
    out = text
    for _ in range(20):                       # 無限ループ保険
        m = _HEREDOC_RE.search(out)
        if not m:
            break
        tag = m.group(2)
        eol = out.find("\n", m.end())
        if eol < 0:
            break                             # 本体が無い（最終行）
        endm = re.compile(r"^\s*" + re.escape(tag) + r"\s*$", re.M).search(out, eol + 1)
        if not endm:
            break                             # 終端タグが無い＝ヒアドキュメントとして成立していない。そのまま見る
        body = out[eol + 1:endm.start()]
        # 受け手＝この `<<` が属するセグメントの先頭語（VAR=x の環境前置は飛ばす）
        seg_start = max(out.rfind(x, 0, m.start()) for x in ("\n", ";", "&", "|", "("))
        words = [w for w in out[seg_start + 1:m.start()].split() if not re.match(r'^\w+=', w)]
        first = words[0].rsplit("/", 1)[-1] if words else ""
        keep = bool(_SHELL_CONSUMER.match(first))
        out = out[:m.start()] + " " + out[m.end():eol + 1] + (body + "\n" if keep else "") + out[endm.end():]
    return out

shell_text = _strip_heredocs(cmd_joined)

# ⓪-b 同一コマンド内の単純代入を展開する（過検知 (b)）。
#   `S=/tmp/…/scratchpad; mkdir -p $S/x` は全部一時領域なのに、`$S` が TMP_RE に合わず止まっていた。
#   Bash 呼び出しごとにシェル状態は消えるので、判定に使える代入は同一コマンド内のものだけ。
#   展開できない変数はそのまま残す（→ 一時領域と認めない。従来どおり止まる側）。
# ⓪-b-1 `$(mktemp -d)` を一時領域のリテラルとして先に潰す（過検知 (f)）。
#   過検知の実測: `D=$(mktemp -d); mkdir -p $D/mut` が exit 2 だった。
#   代入の値の正規表現は `)` を含められないので `$(mktemp -d)` は `$` で切れ、
#   TMP_RE に合わず「一時領域と認めない」側へ落ちていた。
#   **これは検証の役の変異検証（実物を読んで /tmp に写しを書く）そのものの形を塞いでいた。**
#
#   ただし mktemp は **常に /tmp とは限らない**。テンプレートにディレクトリを含む形
#   （`mktemp -d /home/x/XXXX`）や `-p` / `--tmpdir=` で行き先を指定した形は
#   **展開しない＝従来どおり止める**（fail-closed 側に残す）。
shell_text_raw = shell_text          # TMPDIR の検出は、置換する前の生テキストで行う
_MKTEMP_SUB_RE = re.compile(r'\$\((\s*mktemp\b[^()]*)\)|`(\s*mktemp\b[^`]*)`')
def _mktemp_is_default_tmp(argstr):
    a = argstr.strip()
    if re.search(r'(^|\s)(-p|--tmpdir)(=|\s|$)', a):
        return False                          # 行き先を明示している → 判定しない
    # 独立検証の実測: **mktemp の行き先は TMPDIR で変わる。**
    #   実測: `export TMPDIR=$HOME/project; D=$(mktemp -d); mkdir -p $D/evil` が
    #   一時領域と判定されて通っていた（mktemp 是正で作り込んだ退行）。
    #   同一コマンド内で TMPDIR が一時領域以外に設定されていたら、展開しない。
    m = re.search(r'\bTMPDIR=("[^"]*"|\'[^\']*\'|[^\s;&|)]*)', shell_text_raw)
    if m:
        v = m.group(1).strip('"\'')
        if not re.match(r'^(/tmp/|/tmp$|/var/tmp/|/var/tmp$)', v):
            return False                      # TMPDIR が一時領域の外 → 判定しない
    for tok in a.split()[1:]:
        if tok.startswith('-'):
            continue
        if '/' in tok:
            return False                      # テンプレートにディレクトリが入っている
    return True
def _sub_mktemp(m):
    arg = m.group(1) or m.group(2)
    return '/tmp/__mktemp__' if _mktemp_is_default_tmp(arg) else m.group(0)
shell_text = _MKTEMP_SUB_RE.sub(_sub_mktemp, shell_text)
cmd_joined = _MKTEMP_SUB_RE.sub(_sub_mktemp, cmd_joined)

_ASSIGN_RE = re.compile(r'(?:^|[;&|\n(]\s*|\bexport\s+)([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\'[^\']*\'|[^\s;&|)]*)')
_VAR_RE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')
shell_vars = {}
def _expand(s):
    if not shell_vars:
        return s
    return _VAR_RE.sub(lambda m: shell_vars.get(m.group(1) or m.group(2), m.group(0)), s)
for m in _ASSIGN_RE.finditer(shell_text):
    name, val = m.group(1), m.group(2)
    if len(val) >= 2 and val[0] in "\"'" and val[-1] == val[0]:
        val = val[1:-1]
    if name in ("TMPDIR",):
        continue                              # TMPDIR は TMP_RE 側で扱う。上書きは展開しない
    shell_vars[name] = _expand(val)
shell_text = _expand(shell_text)
code = _expand(cmd_joined)                    # ⑥ 用（ヒアドキュメント本体・引用符の中身を含む）

# ① 引用符の中身を落とす（中の記号を構文として誤読しないため）
#   ただし **中身が素のパスなら残す**（検証の役の実測）。
#   `mkdir -p "/tmp/.../a" "/tmp/.../b"` は引用符ごと空白に潰されて書き先が 0 個になり、
#   `_all_tmp([])` が False で止まった。全部 /tmp なのに落ちる 2 つ目の原因。
#   残す条件は厳格にする: 記号を含まず（空白・> < | ; & ( ) 等が無い）、かつ
#   `/` を含むか `$`/`~` で始まる。`'rm'` や `'a>b'` や `'npm ci'` は今までどおり潰す
#   （残すと `grep 'rm' src/` が rm の実行に見える）。
PATH_LITERAL = re.compile(r'^[A-Za-z0-9_./~$%@:+=,{}-]+$')
# 引用符で囲まれた「パスでない」リテラルを潰した跡に置く目印。
#   実測の過検知: `sed -i '/^tests\/x\t/d' /tmp/…/f` が止まった。スクリプト部が `^` `\` を含むため
#   空白に潰され、_inplace_targets が最初の非オプション語（＝ファイル /tmp/…）を「スクリプト」と数えて
#   書き先が 0 個になっていた（`'s/a/b/'` は `/` を含む素のパス扱いで残るので通っていた）。
#   → 「ここに引用リテラルが在った」ことだけを残す。書き先としては数えない（_targets が飛ばす）。
QLIT = "__QLIT__"
def _keep_literal(lit):
    if not PATH_LITERAL.match(lit):
        return False
    return "/" in lit or lit[:1] in ("$", "~")

def _strip_quoted(text):
    """引用符で囲まれた literal を落とす（素のパスだけは残す）。subprocess の起動先にも掛けるため関数にしてある。"""
    stripped, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch in ("'", '"'):
            q = ch; i += 1
            buf = []
            while i < n and text[i] != q:
                if q == '"' and text[i] == "\\":
                    i += 1
                if i < n:
                    buf.append(text[i])
                i += 1
            i += 1
            lit = "".join(buf)
            if _keep_literal(lit):
                stripped.append(lit)
            else:
                stripped.append(" " + QLIT + " " if lit else " ")   # パスでない literal は目印に潰す（空文字は空白）
        else:
            stripped.append(ch); i += 1
    return "".join(stripped)

c = _strip_quoted(shell_text)

# ③ 読み取り専用と分かっているサブコマンドは通す（監査の役が点検に使う）
#   過検知 (d): `git stash list|show` を追加。stash の他のサブコマンドは後段の「git 変更系」で止まる。
READ_ONLY = [
    r'\bcrontab\s+-l\b',
    # 過検知 (f) の近傍: is-system-running / is-enabled / is-failed / list-timers を追加。
    #   実測で `systemctl is-system-running`（WSL で systemd の有無を見るだけ）が止まっていた。
    r'\bsystemctl\s+(status|list-units|list-timers|list-unit-files|is-active|is-enabled|is-failed|is-system-running|show|cat)\b',
    # 過検知 (h): git merge-base は読み取りだけの問い合わせだが、
    #   下の変更系パターンの `git merge` に前方一致で誤爆していた。読み取り側に明示する。
    #   ⚠ この一手は**二重に効かせてある**：ここの読み取り許可と、
    #     下の変更系パターンの `merge(?!-)`（merge の直後がハイフンなら変更系と数えない）。
    #     どちらか片方を壊しても通るので、**この過検知は単一の変異では再現できない。**
    #     ＝ 変異台帳に登録していない（登録しても必ず「壊しても緑」になる）。
    #     二重にしたのは、正規表現の前方一致は他の語でも起きうるからである。
    r'\bgit\s+merge-base\b', r'\bgit\s+merge-tree\b',
    r'\bgit\s+(log|show|diff|status|blame|rev-parse|rev-list|ls-files|for-each-ref|config\s+--get|branch\s+--show-current|remote\s+-v|describe|cat-file|check-ignore|stash\s+(list|show))\b',
    r'\bgh\s+\w+\s+(view|list|status)\b',
]

def _clean_shell(t):
    """シェル構文の判定に掛ける前の掃除。subprocess の起動先にも同じ掃除を掛けるため関数にしてある。"""
    # ①-b シェルコメント（行頭または空白の後の # から行末）と算術式 ((…)) は構文判定から外す（過検知 (a)）。
    #   `ls  # a -> b` の `->` がリダイレクトに見えていた。`$#` `${#x}` は前が空白でないので残る。
    t = re.sub(r'(^|\s)#[^\n]*', r'\1', t)
    t = re.sub(r'\(\([^()]*\)\)', ' ', t)
    # ② 出力抑止と fd 複製は書き込みではない。先に除去する。
    t = re.sub(r'\d?>>?\s*/dev/(null|stderr|stdout)\b', ' ', t)
    t = re.sub(r'\d?>&\d', ' ', t)
    t = re.sub(r'\d?<&\d', ' ', t)
    # ③
    for r in READ_ONLY:
        t = re.sub(r, ' ', t)
    return t

c = _clean_shell(c)

# ③-b 一時領域への書き込みは通す
#   制約は「**対象を変更しない**」であって「どこにも書かない」ではない。
#   検証・監査の役は中間結果の保存に一時ファイルが要る。実際に、監査の役が
#   「curl -o でスクラッチパッドに5本書いた。指示に抵触した可能性がある」と自己申告した例がある。
#   **仕事に要るものを禁じると、規律を破るか任務を落とすかの二択になる。** どちらも悪い。
#   /tmp と セッションのスクラッチパッド配下だけを許す。リポジトリ配下は許さない。
TMP_OK = r'(/tmp/|\$TMPDIR|\${TMPDIR)'
def _tmp_ok(t):
    """独立検証の実測: リダイレクト先の判定にも `..` 拒否を掛ける。
    実測: `echo x > /tmp/../home/user/project/README.md` が素通りしていた。
    TMP_OK は**部分一致**（re.search）なので、先頭が /tmp でなくても当たる点にも注意。"""
    if not t:
        return False
    if '/../' in t or t.endswith('/..') or t.startswith('../'):
        return False
    return bool(re.match(r'^(/tmp/|/var/tmp/|\$TMPDIR|\$\{TMPDIR)', t))
def _tmp_only(expr):
    """リダイレクト先がすべて一時領域なら True"""
    tgts = re.findall(r'>>?\s*([^\s&(|;]+)', expr)
    return bool(tgts) and all(_tmp_ok(t) for t in tgts)

hits = []

# ─────────────────────────────────────────────────────────
# 【全面改訂】検証の役が過検知を4件実測した。
#   「安全側の失敗」ではない。**検証の網羅性を直接下げた**
#   （検体を作れず、supply-chain 走査の4項目が実測されないまま報告に残った）。
#
#   ① 一時領域の除外が**リダイレクトにしか効いていなかった**。
#      `rm -f /tmp/.../x` `cp a /tmp/.../b` `touch /tmp/.../x` `mkdir -p /tmp/.../s` が全部止まった。
#   ② `sed -i` の正規表現が**コマンド区切りを越えていた**。
#      `sed -n '1,5p' f | grep -i foo` が「sed -i」として止まった。
#
#   直し方：**セグメントに割ってから判定する**（check_git_identity.sh と同じ原則）。
#   そのうえで「そのコマンドが触る先が全部一時領域なら通す」を、リダイレクトだけでなく
#   コマンド引数にも適用する。
# ─────────────────────────────────────────────────────────
# 独立検証の実測: **`..` を含むパスを一時領域と認めない。**
#   実測: `rm -rf /tmp/../home/user/project/docs` など8形中7形が素通りしていた。
#   TMP_RE は先頭一致だけを見ており、パスを正規化していなかった。
#   正規化して判定するのが本筋だが、`$VAR` を含む未展開のパスは正規化できない。
#   **正規化できないものを許可側に置かない**＝`..` を含むなら一時領域と認めない（fail-closed）。
_TMP_HEAD_RE = re.compile(r'^(/tmp/|/var/tmp/|\$TMPDIR|\$\{TMPDIR)')
class _TmpRe:
    @staticmethod
    def match(x):
        if not x:
            return None
        if '/../' in x or x.endswith('/..') or x.startswith('../'):
            return None                       # 上へ抜ける形は許可しない
        return _TMP_HEAD_RE.match(x)
TMP_RE = _TmpRe

# コマンドごとに「どれが**書き先**か」が違う。
#   cp a b / mv a b / ln a b / install a b … **最後の引数だけ**が書き先（前は読み元）
#   dd of=X                              … of= が書き先
#   rm / touch / mkdir / chmod / chown … 引数すべてが対象
# 以前はこれを区別せず「全引数が /tmp なら通す」としたため、
# `cp /etc/hosts /tmp/.../h` が止まった（読み元 /etc のせい）。
# **読むだけの引数を、書き先として数えない。**
_LAST_ARG_IS_TARGET = {"cp", "mv", "ln", "install", "rsync"}

# 過検知 (f) の近傍: chmod / chown は**第1引数がパスではない**。
#   過検知の実測: `chmod +x /tmp/.../mut.sh` が exit 2。`+x` を書き先のパスと数え、
#   TMP_RE に合わないので「一時領域だけではない」と判定していた。
#   `755` `u+w` `a-x` `--reference=f` も同じ。chown は `user:group`。
#   **モード語を書き先として数えない。** ただし判定できない形は従来どおり数える（fail-closed）。
_MODE_RE  = re.compile(r'^[0-7]{3,4}$|^[ugoa]*([+-=][rwxXstugo]*)+$')
_OWNER_RE = re.compile(r'^[A-Za-z_][\w.-]*(:[A-Za-z_][\w.-]*)?$|^:[A-Za-z_][\w.-]*$')

def _targets(seg, cmdname):
    """そのコマンドが**書き込む先**とみられる引数を返す。"""
    toks = seg.split()
    out = []
    seen = False
    first_operand = True
    for t in toks:
        if not seen:
            if t == cmdname or t.endswith("/" + cmdname):
                seen = True
            continue
        if t in ("&&", "||", "|", ";"):
            break
        if t.startswith("of="):          # dd
            out.append(t[3:]); continue
        if t.startswith("-") or t == QLIT:
            continue
        if first_operand:
            first_operand = False
            if cmdname == "chmod" and _MODE_RE.match(t):
                continue                 # モード語。パスではない
            if cmdname == "chown" and _OWNER_RE.match(t) and "/" not in t:
                continue                 # user:group。パスではない
        out.append(t)
    if cmdname in _LAST_ARG_IS_TARGET and len(out) >= 2:
        return out[-1:]                  # 書き先は最後の1つだけ
    return out

def _all_tmp(paths):
    return bool(paths) and all(TMP_RE.match(x) for x in paths)

# 独立検証で素通りが実測された4経路（rsync は _targets で見る）:
#   `sort -o FILE FILE`（-o の先に書く）／`patch -p1 < diff`（書き先は diff の中身で決まり、静的には読めない）／
#   `find … -delete`／`find … -exec CMD {} ;`（起点パス配下を書き換える）。
#   find の判定は subprocess の argv 側（_judge_argv）にだけあり、シェル文字列側には無かった＝一度も呼ばれていなかった。
#   find のセグメントは find 専用の判定だけに掛ける（`-exec rm {}` の rm を CMDS で先に拾うと、起点が一時領域でも止まる）。
_FIND_SEG_RE = re.compile(r'^\s*(?:\S*/)?find(?:\s|$)')
def _sort_targets(seg):
    """sort の書き先（-o FILE / -oFILE / --output=FILE）。無ければ [] ＝ 読み取り。"""
    toks = seg.split()
    out, seen, nxt = [], False, False
    for t in toks:
        if not seen:
            if t == "sort" or t.endswith("/sort"):
                seen = True
            continue
        if nxt:
            out.append(t); nxt = False; continue
        if t in ("-o", "--output"):
            nxt = True; continue
        if t.startswith("--output="):
            out.append(t[len("--output="):]); continue
        if t.startswith("-o") and not t.startswith("--") and len(t) > 2:
            out.append(t[2:]); continue
    return out

def _patch_targets(seg):
    """patch の書き先。--dry-run なら None（書かない）。-d/--directory・-o/--output の値と、最初の位置引数（元ファイル）。
    どれも無ければ [] ＝ 書き先は diff の中身で決まり静的に読めない → 一時領域と認めない（fail-closed）。"""
    toks = seg.split()
    if "--dry-run" in toks or "--check" in toks:
        return None
    out, seen, nxt, first = [], False, None, None
    for t in toks:
        if not seen:
            if t == "patch" or t.endswith("/patch"):
                seen = True
            continue
        if nxt:
            if nxt in ("-d", "--directory", "-o", "--output"):
                out.append(t)
            nxt = None; continue                     # -i の値（読み元）は飛ばす
        if t in ("-d", "--directory", "-o", "--output", "-i", "--input"):
            nxt = t; continue
        if t.startswith("--directory=") or t.startswith("--output="):
            out.append(t.split("=", 1)[1]); continue
        if t == "<" or t.startswith("<"):            # `< diff` の diff は読み元
            nxt = "<" if t == "<" else None; continue
        if t.startswith("-") or t == QLIT:
            continue
        if first is None:
            first = t
    if first is not None:
        out.append(first)
    return out

def _find_roots(seg):
    """find の起点パス。無ければ `.`（＝カレント＝対象）。"""
    toks = seg.split()
    roots, seen = [], False
    for t in toks:
        if not seen:
            if t == "find" or t.endswith("/find"):
                seen = True
            continue
        if t.startswith("-") or t in ("(", "!", "\\(", "\\!") or t == QLIT:
            break
        roots.append(t)
    return roots or ["."]

def _find_action(seg):
    """find に書き込み系のアクションがあるか。-delete → 常に。-exec/-execdir/-ok/-okdir → 起動先で判定。
    返り値: ラベル / None（読み取り）/ "?"（起動先が自作スクリプト等で判定できない）"""
    toks = seg.split()
    if "-delete" in toks:
        return "find -delete"
    for i, t in enumerate(toks):
        if t not in ("-exec", "-execdir", "-ok", "-okdir"):
            continue
        sub = []
        for u in toks[i + 1:]:
            if u in (";", "\\;", "+", "\\"):
                break
            sub.append(u)
        if not sub:
            return "?"
        head = sub[0].rsplit("/", 1)[-1]
        line = " ".join(sub)
        if head in CMDS or _SHELL_CONSUMER.match(head):
            return "find %s %s" % (t, head)
        for pat, label in _MUT_PATTERNS:
            if re.search(pat, line):
                return "find %s %s" % (t, label)
        if head in _ARGV_READ_ONLY or head == "find":
            continue
        return "?"
    return None

# ⑤ 変更系コマンド
CMDS = ['rm','rmdir','mv','cp','install','truncate','shred','dd','tee',
        'chmod','chown','ln','touch','mkdir','crontab','systemctl','ed','ex',
        # 独立検証で素通りが実測された経路。rsync は cp と同じ「最後の引数が書き先」。
        # sort / patch / find は書き先の取り方が特殊なので、下の専用関数で見る。
        'rsync','sort','patch']
_MUT_PATTERNS = [
    (r'(^|[\s(])sed(\s+[^\s]+)*?\s+-[a-zA-Z]*i(\s|$)', 'sed -i'),
    (r'(^|[\s(])perl\s+-[a-z]*i(\s|$)', 'perl -i'),
    # 過検知 (h): merge の直後にハイフンが続く形（merge-base / merge-tree）を変更系と数えない
    (r'(^|[\s(])git\s+(add|commit|push|checkout|switch|restore|reset|clean|stash|rebase|merge(?!-)|tag|rm|mv|apply|cherry-pick)\b', 'git 変更系'),
    (r'(^|[\s(])gh\s+\w+\s+(create|edit|merge|close|delete|comment|ready|dispatch|run)\b', 'gh 変更系'),
    (r'(^|[\s(])(npm\s+(install|i|ci|publish)|pip\s+install|apt(-get)?\s+install)', 'パッケージ導入'),
]

# 過検知 (h): sed -i の書き先を見ていなかった。/tmp の写しへの sed -i まで止まり、
#   「一時領域の写しで挙動を確かめよ」という指示そのものを妨げた。
#   しかも mutation_check.sh は内部で同じ sed -i を写しに撃つので、
#   スクリプト経由なら通り、人が手で撃つと止まるという非対称になっていた。
#   -> cp/mv と同じ扱いにする: 触る先が全部一時領域なら通す。
def _inplace_targets(seg):
    toks = seg.split()
    out = []
    skip_next = False
    seen_cmd = False
    seen_script = False
    for t in toks:
        if not seen_cmd:
            if t in ("sed", "perl") or t.endswith("/sed") or t.endswith("/perl"):
                seen_cmd = True
            continue
        if skip_next:
            skip_next = False
            continue
        if t in ("-e", "-f", "--expression", "--file"):
            skip_next = True
            seen_script = True
            continue
        if t.startswith("-"):
            continue
        if not seen_script:                 # 最初の非オプション語がスクリプト部（引用リテラルの目印 QLIT もここで消費される）
            seen_script = True
            continue
        out.append(t)
    return out

def _shell_hits(c):
    """シェルとして実行される文字列（_strip_quoted＋_clean_shell 済み）を判定してラベル列を返す。
    subprocess の `shell=True` / `bash -c` の中身にも同じ判定を掛けるため関数にしてある。"""
    hits = []
    SEGS = [x.strip() for x in re.split(r'&&|\|\||[;\n|]', c) if x.strip()]

    # ④ リダイレクト＝実ファイルへの書き込み（一時領域だけなら通す）
    #   `>=` がトップレベルに残っていれば bash は「`=` という名のファイルへの書き込み」と解釈する。止める側で正しい。
    if re.search(r'(^|[^0-9&<>])>>?\s*[^\s&(|]', c) and not _tmp_only(c):
        hits.append("リダイレクトによる書き込み")

    # 過検知 (f) の近傍: `echo` / `printf` の引数は**データであってコマンドではない**。
    #   実測で `echo sed -i is dangerous` が「sed -i」として止まっていた。
    #   ただしコマンド置換（`$(...)` / バッククォート）を含む場合は**中身が実行される**ので
    #   除外しない（fail-closed 側に残す）。リダイレクトは上の ④ が全文で見ているので影響しない。
    def _is_pure_echo(seg):
        if re.search(r'\$\(|`', seg):
            return False
        return bool(re.match(r'^\s*(echo|printf)(\s|$)', seg))

    # ⑤ **セグメントごとに**見る。触る先が全部一時領域なら通す。
    for seg in SEGS:
        if _is_pure_echo(seg):
            continue
        if _FIND_SEG_RE.match(seg):
            act = _find_action(seg)
            if act is None:
                continue              # -delete / -exec の無い find は読み取り
            if act == "?":
                warns.append("find -exec の起動先を静的に判定できない。通すが、対象を変更していれば規律違反。")
                continue
            if _all_tmp(_find_roots(seg)):
                continue              # 起点が全部一時領域＝通す
            hits.append(act); break
        for name in CMDS:
            if re.search(r'(^|[\s;&|(])' + name + r'(\s|$)', seg):
                label = name
                if name == "sort":
                    tg = _sort_targets(seg)
                    if not tg:
                        continue      # -o が無い sort は読み取り
                    label = "sort -o"
                elif name == "patch":
                    tg = _patch_targets(seg)
                    if tg is None:
                        continue      # --dry-run は書かない
                elif name == "rsync" and re.search(r'(^|\s)(--dry-run|-[a-zA-Z]*n[a-zA-Z]*)(\s|$)', seg):
                    continue          # rsync -n / --dry-run は書かない
                else:
                    tg = _targets(seg, name)
                if _all_tmp(tg):
                    continue          # 触る先が全部一時領域＝通す
                hits.append(label); break
        if hits:
            break

    for seg in SEGS:
        if _is_pure_echo(seg) or _FIND_SEG_RE.match(seg):
            continue                  # find は上で判定済み（-exec sed -i を二重に見ない）
        for pat, label in _MUT_PATTERNS:
            if re.search(pat, seg):
                # 過検知 (h): その場書き換えは、書き先が全部一時領域なら通す（cp/mv と同じ扱い）
                if label in ('sed -i', 'perl -i') and _all_tmp(_inplace_targets(seg)):
                    continue
                hits.append(label); break
        if hits:
            break
    return hits

hits = _shell_hits(c)

# ④-b `bash -c "rm -rf docs"` / `eval "rm -rf docs"` ── 引用符の中身はシェルとして**実行される**。
#   独立検証で素通りが実測された。① が引用リテラルを潰すので、中身が判定に掛かっていなかった。
#   引用符の無い `eval rm -rf docs` は ⑤ がそのまま見るので、ここでは引用符付きの形だけを見る。
#   中身が変数（`bash -c "$X"`）なら静的に読めない → warn を出して通す（open / subprocess と同じ扱い）。
_SHELL_C_RE = re.compile(r'(?:^|[\s;&|(])(?:(?:ba|z|da|k)?sh)(?:\s+-[a-zA-Z]+)*\s+-c\s+(?=[\'"])|(?:^|[\s;&|(])eval\s+(?=[\'"])')
def _quoted_at(text, i):
    q = text[i]; j = i + 1; buf = []
    while j < len(text) and text[j] != q:
        if q == '"' and text[j] == "\\":
            j += 1
        if j < len(text):
            buf.append(text[j])
        j += 1
    return "".join(buf)
def _shell_c_hits(text):
    for m in _SHELL_C_RE.finditer(text):
        body = _quoted_at(text, m.end())
        if not body.strip():
            continue
        if re.fullmatch(r'\$\{?\w+\}?', body.strip()):
            warns.append("sh -c / eval の中身を静的に判定できない（変数）。通すが、対象を変更していれば規律違反。")
            continue
        h = _shell_hits(_clean_shell(_strip_quoted(body)))
        if h:
            return ["sh -c / eval → " + h[0]]
    return []
if not hits:
    hits = _shell_c_hits(shell_text)

# ⑥ インタプリタ経由の書き込み（code 系＝ヒアドキュメント本体・引用符の中身を含む生の文字列を見る）
#
# 検証の役の実測: `python3 - <<EOF ... os.makedirs('/tmp/.../scratchpad/...') ... EOF` が
# 「os.*」で止まった。除外に使っていた _tmp_only はリダイレクト先しか見ておらず、
# 関数引数のパス（os.makedirs('/tmp/...') / open('/tmp/...','w')）を見ていなかった。
#
# 過検知 (c) で判定を「書き先の位置」に限定した。旧版は**コマンド中の絶対パスをすべて**集めて「全部 /tmp か」を見たため、
# 読み元 `/home/.../photos` が同居するだけで scratchpad への open(w) が止まった。加えて
#   - open(変数,'w') を「判定不能＝止める」にしていた → 同一コード内の代入（p='…' / with open(…) as f）を辿る。
#     辿れないときは **warn を stderr に1行出して通す**。止めると調査の役の全 python が使えなくなる。
#     これは「見えないものを許す」のであって「安全」ではない。そう呼ばないこと。
#   - `sys.stdout.write(` を書き込みと読んでいた → 受け手が sys.stdout/stderr ならファイルでない。
#   - `> /tmp/…` が1つあれば ⑥ を丸ごと飛ばしていた（抜け道。実証済み）→ 撤去。
#   - shutil.copy(src, dst) の dst を見ていなかった → 書き先は最後の引数。
#
# os.system / subprocess.* の引数はシェルコマンドであってパスではないので、常に止める。
_TMP_LIT_HEAD_RE = re.compile(r'^(/tmp/|/var/tmp/|\$TMPDIR|\$\{TMPDIR)')
class _TmpLitRe:                              # python 側にも同じ `..` 拒否を掛ける
    @staticmethod
    def match(x):
        if not x:
            return None
        if '/../' in x or x.endswith('/..') or x.startswith('../'):
            return None
        return _TMP_LIT_HEAD_RE.match(x)
TMP_LIT_RE = _TmpLitRe
_STRTOK = re.compile(r'(?P<pfx>[rbRBfFuU]{0,2})(?P<q>["\'])(?P<s>(?:\\.|(?!(?P=q)).)*)(?P=q)', re.S)

def _paren_content(s, i):
    """s[i] == '(' から対応する ')' までの中身を返す。引用符の中は数えない。閉じなければ末尾まで。"""
    depth, j, n = 0, i, len(s)
    while j < n:
        ch = s[j]
        if ch in "\"'":
            m = _STRTOK.match(s, j - 0)
            if m and m.start() == j:
                j = m.end(); continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    return s[i + 1:], n

def _split_args(s):
    """トップレベルのカンマで引数を割る。"""
    args, depth, cur, j, n = [], 0, [], 0, len(s)
    while j < n:
        ch = s[j]
        if ch in "\"'":
            m = _STRTOK.match(s, j)
            if m and m.start() == j:
                cur.append(m.group(0)); j = m.end(); continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            args.append("".join(cur).strip()); cur = []
        else:
            cur.append(ch)
        j += 1
    if "".join(cur).strip():
        args.append("".join(cur).strip())
    return args

# 同一コード内の代入: NAME = <式>  /  with <式> as NAME
py_assigns = {}
for m in re.finditer(r'(?:^|[;\n"\'])\s*([A-Za-z_]\w*)\s*=(?!=)\s*([^;\n]+)', code):   # -c "p='…'; …" の先頭代入も拾う
    py_assigns.setdefault(m.group(1), m.group(2).strip())
for m in re.finditer(r'\bwith\s+(.+?)\s+as\s+([A-Za-z_]\w*)\s*:', code):
    py_assigns.setdefault(m.group(2), m.group(1).strip())

_NONPATH_RE = re.compile(r'^sys\.(?:__)?(?:stdout|stderr)(?:__)?(?:\.buffer)?$')

def _resolve(expr, depth=0):
    """式 → ("path", 文字列) / ("nonpath", None) / ("unknown", None)"""
    expr = (expr or "").strip()
    if not expr or depth > 4:
        return ("unknown", None)
    if _NONPATH_RE.match(expr):
        return ("nonpath", None)
    m = _STRTOK.match(expr)
    if m and m.end() == len(expr):
        s = m.group("s")
        if "f" in m.group("pfx").lower():
            head = s.split("{", 1)[0]
            return ("path", head) if TMP_LIT_RE.match(head) else ("unknown", None)
        return ("path", s)
    if m:                                       # 'lit' + x / 'lit' % x / 'lit'.format(...)
        rest = expr[m.end():].lstrip()
        if rest[:1] in ("+", "%") or rest.startswith(".format("):
            return ("path", m.group("s"))
    m = re.match(r'^(?:pathlib\.)?Path\s*\(', expr)
    if m:
        inner, _ = _paren_content(expr, m.end() - 1)
        a = _split_args(inner)
        return _resolve(a[0], depth + 1) if a else ("unknown", None)
    m = re.match(r'^os\.path\.join\s*\(', expr)
    if m:
        inner, _ = _paren_content(expr, m.end() - 1)
        a = _split_args(inner)
        return _resolve(a[0], depth + 1) if a else ("unknown", None)
    m = re.match(r'^(?:io\.|codecs\.)?open\s*\(', expr)
    if m:
        inner, end = _paren_content(expr, m.end() - 1)
        # 過検知 (f) の近傍: `open(...).read()` は**文字列**であってパスではない。
        #   過検知の実測: `s = open("…/verify.sh").read()` のあと
        #   `open("/tmp/…","w").write(s.replace("a","b"))` が exit 2 で止まった。
        #   `s.replace(` を Path.replace と読み、`s` を open() の引数まで辿って
        #   「/home/… に書く」と判定していた。**読んだ中身を、読み元のパスと取り違えている。**
        if re.match(r'^\s*\.\s*(read|readlines|readline|decode|splitlines)\b', expr[end:]):
            return ("nonpath", None)
        a = _split_args(inner)
        return _resolve(a[0], depth + 1) if a else ("unknown", None)
    if re.fullmatch(r'[A-Za-z_]\w*', expr) and expr in py_assigns:
        return _resolve(py_assigns[expr], depth + 1)
    return ("unknown", None)

def _is_write_mode(mode_expr):
    """open()/openSync() の mode。None=読み取り / True=書き込み / "unknown" """
    if mode_expr is None:
        return None
    m = _STRTOK.match(mode_expr)
    if m and m.end() == len(mode_expr):
        return True if re.search(r'[wax+]', m.group("s")) else None
    return "unknown"

interp_targets = []     # (label, kind, path)
def _add(label, kind, path):
    interp_targets.append((label, kind, path))

# パスを引数に取る API: (正規表現, ラベル, 書き先の引数位置リスト, mode を見るか)
_PATH_APIS = [
    (r'\b(?:io\.|codecs\.)?open\s*\(',                                   'open(write)', [0], True),
    (r'\bos\.(?:makedirs|mkdir|remove|unlink|rmdir)\s*\(',               'os.*',        [0], False),
    (r'\bos\.(?:rename|replace)\s*\(',                                   'os.*',        [0, 1], False),
    (r'\bshutil\.(?:copy|copyfile|copy2|move|copytree)\s*\(',            'shutil.*',    [-1], False),
    (r'\bshutil\.rmtree\s*\(',                                           'shutil.*',    [0], False),
    (r'\b(?:writeFileSync|appendFileSync|mkdirSync|createWriteStream|rmSync|unlinkSync)\s*\(', 'node fs.*', [0], False),
    (r'\brenameSync\s*\(',                                               'node fs.*',   [0, 1], False),
    (r'\bopenSync\s*\(',                                                 'node fs.*',   [0], True),
]
for pat, label, idxs, check_mode in _PATH_APIS:
    for m in re.finditer(pat, code):
        inner, _ = _paren_content(code, m.end() - 1)
        args = _split_args(inner)
        if not args:
            continue
        if check_mode:
            mode = None
            if len(args) >= 2 and "=" not in args[1].split("(")[0]:
                mode = args[1]
            else:
                mm = re.search(r'\b(?:mode|flags)\s*=\s*(.+)$', ",".join(args[1:]))
                if mm:
                    mode = _split_args(mm.group(1))[0]
            w = _is_write_mode(mode)
            if w is None:
                continue                                   # 読み取り open
            if w == "unknown":
                _add(label, "unknown", None); continue
        for ix in idxs:
            try:
                kind, path = _resolve(args[ix])
            except IndexError:
                continue
            _add(label, kind, path)

# 受け手が書き込みメソッドを呼ぶ形: <式>.write_text( / .write( / Path(...).mkdir( など
_RECV_RE = re.compile(
    r'(?P<recv>(?:[A-Za-z_][\w.]*)(?:\((?:[^()]|\([^()]*\))*\))?)\s*'
    r'\.(?P<meth>write_text|write_bytes|writelines|write|touch|mkdir|unlink|rmdir|rename|replace)\s*\(')
for m in _RECV_RE.finditer(code):
    recv, meth = m.group("recv"), m.group("meth")
    if recv.split("(")[0] in ("os", "shutil", "fs", "sys") and meth not in ("write", "writelines"):
        continue                                            # os.mkdir 等は上で見た
    # 過検知 (f) の近傍: `.replace(` は **str.replace が引数2つ、Path.replace は1つ**。
    #   引数が2つ以上あるなら文字列置換であって、ファイルの置き換えではない。
    #   `s.replace("a","b")` を止めていたのが過検知3件の1つ（＝変異検証そのものの形）。
    if meth == "replace":
        _inner, _e = _paren_content(code, m.end() - 1)
        if len(_split_args(_inner)) >= 2:
            continue
    kind, path = _resolve(recv)
    if kind == "nonpath":
        continue                                            # sys.stdout.write
    label = '.write(' if meth in ("write", "writelines") else 'pathlib.*'
    if kind == "unknown" and re.fullmatch(r'[A-Za-z_]\w*', recv) and recv not in py_assigns and meth in ("write", "writelines"):
        # 未知の名前の .write（例: logger.write / resp.write）。ファイルかどうか分からない
        _add(label, "unknown", None); continue
    _add(label, kind, path)

if interp_targets:
    bad = [(l, p) for l, k, p in interp_targets if k == "path" and not TMP_LIT_RE.match(p)]
    unknown = [l for l, k, p in interp_targets if k == "unknown"]
    if bad:
        hits.append(bad[0][0])
    elif unknown:
        warns.append("%s の書き先を静的に判定できない（変数など）。通すが、一時領域以外に書いていれば規律違反。" % unknown[0])

# os.system の引数はシェルコマンドであってパスではない。**引数によらず止める**（従来どおり。検体 E / H-2 で固定）。
if re.search(r'\bos\.system\s*\(', code):
    hits.append('os.*')

# ⑥-b subprocess.*（過検知 (e)）
#   旧版は `subprocess.` というトークンが在るだけで止めていた。**起動されるコマンドを見ていなかった。**
#   実測: `subprocess.run(['bash','tools/verify.sh'], capture_output=True)`（書き先は /tmp のみ）が exit 2。
#   検証の役は迂回せず bash ループへ書き換えて同じ検証を通した（正しい振る舞い）が、**その分だけ計測経路が減った**。
#   過検知は安全側ではない。
#   直し方: 起動されるコマンドで判定する。
#     - 第1引数がリスト literal → 先頭要素（＝起動されるプログラム）を見る。読み取りと分かるものは通し、
#       変更系（rm/mv/mkdir/… ・git 変更系・gh 変更系・sed -i・パッケージ導入）は**引数によらず止める**（os.system と同じ扱い）。
#     - 第1引数が文字列（`shell=True` 等） / `bash -c '…'` → その文字列を通常のシェル判定（_shell_hits）に掛ける。
#     - どちらでもない（変数などで辿れない）→ **warn を1行出して通す**。open に入れたのと同じ扱い。
#       止めると「対象スクリプトを起動して出力を比較する」という調査・検証の主要な形が丸ごと使えなくなる。
#       これは「見えないものを許す」のであって「安全」ではない。そう呼ばないこと。
_ARGV_READ_ONLY = {
    "cat","ls","head","tail","grep","egrep","fgrep","rg","wc","sort","uniq","cut","awk","sed","diff","cmp",
    "file","stat","date","echo","printf","pwd","which","basename","dirname","jq","tr","column","true","false",
    "uname","id","whoami","df","du","ps","nl","tac","xxd","od","realpath","find",
}
_ARGV_UNKNOWN = "?"

def _judge_argv(items):
    """argv（文字列リスト。辿れなかった要素は None）→ ラベル / None（通す） / "?"（判定不能）"""
    toks = [t for t in items]
    i = 0
    while i < len(toks) and toks[i] is not None and (toks[i] == "env" or re.match(r'^\w+=', toks[i])):
        i += 1                                   # env / VAR=VAL の前置を飛ばす
    toks = toks[i:]
    if not toks or toks[0] is None:
        return _ARGV_UNKNOWN
    head = toks[0].rsplit("/", 1)[-1]
    line = " ".join(t for t in toks if t is not None)
    if head in ("git", "gh", "crontab", "systemctl"):
        for r in READ_ONLY:                      # git log / crontab -l / systemctl status …
            if re.search(r, line):
                return None
    for pat, label in _MUT_PATTERNS:             # sed -i / git 変更系 / gh 変更系 / パッケージ導入
        if re.search(pat, line):
            return label
    if head == "find" and any(t in ("-delete", "-exec", "-execdir", "-ok", "-okdir") for t in toks if t):
        return "find -delete/-exec"
    if head == "sort" and any(t == "-o" or t.startswith("--output") or (t.startswith("-o") and not t.startswith("--")) for t in toks if t):
        return "sort -o"
    if head in CMDS:
        return head                              # rm/mv/mkdir/dd/… は一時領域でも通さない（os.system と同じ扱い）
    if _SHELL_CONSUMER.match(head):
        if "-c" in toks:
            ix = toks.index("-c")
            if ix + 1 < len(toks) and toks[ix + 1] is not None:
                h = _shell_hits(_clean_shell(_strip_quoted(toks[ix + 1])))
                return h[0] if h else None
        return _ARGV_UNKNOWN                     # bash script.sh 等。中身は静的に読めない
    if head in _ARGV_READ_ONLY:
        return None
    return _ARGV_UNKNOWN                         # python3 script.py / ./tool 等

_SUBPROC_RE = re.compile(r'\bsubprocess\.(?:run|call|Popen|check_call|check_output)\s*\(')
for m in _SUBPROC_RE.finditer(code):
    inner, _ = _paren_content(code, m.end() - 1)
    args = _split_args(inner)
    if not args:
        continue
    first = args[0]
    if re.fullmatch(r'[A-Za-z_]\w*', first) and first in py_assigns:
        first = py_assigns[first].strip()        # cmd=['rm','-rf','./docs']; subprocess.run(cmd)
    label = _ARGV_UNKNOWN
    if first[:1] in ("[", "("):
        body = first[1:-1] if first[-1:] in ("]", ")") else first[1:]
        vals = []
        for it in _split_args(body):
            kind, val = _resolve(it)
            vals.append(val if kind == "path" else None)
        label = _judge_argv(vals) if vals else _ARGV_UNKNOWN
    else:
        kind, val = _resolve(first)              # "…", shell=True / 変数
        if kind == "path":
            h = _shell_hits(_clean_shell(_strip_quoted(val)))
            label = h[0] if h else None
    if label is None:
        continue
    if label == _ARGV_UNKNOWN:
        warns.append("subprocess.* が起動するコマンドを静的に判定できない（変数など）。通すが、対象を変更していれば規律違反。")
        continue
    hits.append('subprocess.* → ' + label)
    break

# ⑦ sed の w コマンド（スクリプト部は引用符の中にあるので code 系を見る）
#
# 過検知 (g)（検証の役が検証中に2回踏んだ）:
#   実測で止まったもの（**書き込みは1バイトも無い**）:
#     for w in alpha beta; do printf '%s\n' "$w"; done ; sed -n '1,1p' README.md
#     echo "for w in を消したら通るか"（sed が同じコマンドのどこかに在れば発火した）
#   原因は2つ:
#     ① `[^'"]*` が**改行を含む**ため、引用符が1つあれば離れた行の `w ` にまで届いていた
#     ② `sed` の在処と `w` の在処を**別々に**見ていた（同じ sed 呼び出しの中かを見ていない）
#   → **sed の呼び出しに続くスクリプト部だけ**を見る。ループ変数 `w` や文中の `w` に当てない。
#   ⚠ これは「事故の防止であって、意図的な回避への防御ではない」という既定の範囲内の緩和である。
#     `sed -f script.sed` のようにスクリプトを外部化されたら、この検査は何も見ていない。
_SED_SCRIPT_RE = re.compile(
    r"""(?:^|[\s;&|(])sed\b(?P<args>(?:\s+-[a-zA-Z-]+)*)\s+(?P<q>['"])(?P<body>(?:\\.|(?!(?P=q))[^\n])*)(?P=q)""")
def _sed_writes(body):
    """sed スクリプト本体に `w <ファイル>` があるか。
    **コマンド位置の w だけ**を見る。置換の中の文字 w や、ループ変数の w には当てない。
      止める: `1,5w out`  `/x/w out`  `$w out`  `s/a/b/w out`  `s/a/b/; w out`
      通す  : `1,1p`  `s/foo/bar w baz/`  `-n '1,5p'`
    """
    for cmd in re.split(r"[;\n]", body):
        c2 = cmd.strip()
        if not c2:
            continue
        # 先頭のアドレス（行番号・$・/正規表現/・範囲・否定 !）を剥がす
        c2 = re.sub(r"^(?:\d+|\$|/(?:\\.|[^/])*/)(?:\s*,\s*(?:\d+|\$|/(?:\\.|[^/])*/))?\s*!?\s*", "", c2)
        if re.match(r"^w\s+\S", c2):
            return True
        # s///w file / y///w file のフラグ位置の w
        if re.match(r"^[sy](.)(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[gpi0-9]*w\s+\S", c2):
            return True
    return False

for _m in _SED_SCRIPT_RE.finditer(code):
    if _sed_writes(_m.group("body")):
        hits.append('sed の w コマンド'); break

for w in warns[:1]:
    sys.stderr.write("⚠ deny_mutations: %s\n" % w)
print(hits[0] if hits else "")
PYEOF
) || verdict=""
[ -n "$verdict" ] && deny "$verdict"

exit 0
