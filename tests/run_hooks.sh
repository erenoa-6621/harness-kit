#!/usr/bin/env bash
# フック2本（hooks/deny_mutations.sh・hooks/check_git_identity.sh）の回帰スイート。
#
# なぜ要るか:
#   この2本は、実測で穴が出続けた当のコンポーネントでありながら、回帰検体が1本も無い時期があった。
#   「evals が無い」のではなく「**最も失敗実績のあるフックに検体が無い**」のが問題だった。
#   正しい対策は **穴が出た場所に検体を置く** こと。
#
#   **過検知側の検体を必ず含める。** 過検知は偶然踏んで見つかるものではなく、測っていないから見つからないだけである。
#
# 検体のパス:
#   リポジトリ内を表す絶対パスは $REPO（既定 $HOME/project）で作る。実在しなくてよい。
#   $HOME が /tmp 配下だと「一時領域＝通す」に化けて検体の意味が反転するので、そのときは赤にする。
#   設定は一時ディレクトリの harness.conf を HARNESS_CONF で渡す（キットの harness.conf に依存しない）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENY="$HERE/../hooks/deny_mutations.sh"
IDENT="$HERE/../hooks/check_git_identity.sh"
pass=0; fail=0
REPO="$HOME/project"
case "$REPO" in /tmp/*|/var/tmp/*) echo "  🔴 HOME が一時領域（$HOME）。検体の意味が反転するので判定しない"; exit 1 ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/harness.conf" <<'C'
READONLY_AGENTS="chosa kansa kensho hisho eigyo"
GIT_NAME_EXPECTED="Some One"
GIT_EMAIL_EXPECTED="someone@example.invalid"
C
export HARNESS_CONF="$TMP/harness.conf"

run() {  # script agent_type command 期待exit 説明
  local script="$1" atype="$2" cmd="$3" want="$4" note="$5" payload got
  payload=$(CMD="$cmd" ATYPE="$atype" python3 -c '
import json,os,sys
d={"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}
if os.environ["ATYPE"]: d["agent_type"]=os.environ["ATYPE"]
sys.stdout.write(json.dumps(d))')
  printf '%s' "$payload" | bash "$script" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1))
  else
    fail=$((fail+1))
    printf '  NG %s\n     cmd : %s\n     want=%s got=%s  [%s]\n' "$note" "$cmd" "$want" "$got" "$(basename "$script")"
  fi
}

echo "===== フック回帰スイート ====="

# A. 過検知の検体（監査の役が実測で踏んだ5件。ここが赤だと部下が仕事をできなくなる）
run "$DENY" kansa "echo 'A -> B'"                0 "過検知: 引用符内の矢印"
run "$DENY" kansa "ls -l >/dev/null"             0 "過検知: 出力抑止"
run "$DENY" kansa "awk '{if(a>b)print}' f"       0 "過検知: 引用符内の比較演算子"
run "$DENY" kansa "git log --format='%an <%ae>'" 0 "過検知: メールアドレス表記"
run "$DENY" kansa "crontab -l"                   0 "過検知: crontab -l（監査の役が cron 配線の点検に要る）"

# B. 読み取りは通る
run "$DENY" kensho "bash tools/some_check.sh"  0 "読取: 検査スクリプトの実行"
run "$DENY" kensho "grep -rn foo . | head -20"    0 "読取: grep"
run "$DENY" kensho "git status --porcelain"       0 "読取: git status"
run "$DENY" kensho "python3 -c \"print(open('/etc/hosts').read()[:40])\"" 0 "読取: python3 の read()"
run "$DENY" kensho "curl -s -o /dev/null -w '%{http_code}' https://example.com" 0 "読取: curl の疎通確認"
run "$DENY" kensho "systemctl status foo"         0 "読取: systemctl status"

# C. 素の書き込みは止まる
run "$DENY" kensho "echo a > b.txt"               2 "阻止: リダイレクト"
run "$DENY" kensho "mkdir -p ./newdir"            2 "阻止: mkdir（対象内）"
run "$DENY" kensho "mkdir -p /tmp/z"              0 "一時領域の mkdir は通す（検証の役の指摘）"
run "$DENY" kensho "rm -rf ./docs"                2 "阻止: rm（対象内）"
run "$DENY" kensho "rm -rf /tmp/z"                0 "一時領域の rm は通す"
run "$DENY" kensho "git commit -m x"              2 "阻止: git commit"
run "$DENY" kensho "printf x | dd of=README.md"   2 "阻止: dd（対象内）"
run "$DENY" kensho "printf x | dd of=/tmp/z"      0 "一時領域の dd は通す"

run "$DENY" kensho "grep -n 'npm ci' package.json"        0 "過検知: 引用符内のコマンド名（検証の役が実測）"
run "$DENY" kensho "grep -E 'a>b' f"                        0 "過検知: 正規表現内の >（検証の役が実測）"
run "$DENY" kensho "echo x > /tmp/scratch.txt"              0 "一時領域は許す（対象を変更しない≠どこにも書かない）"
run "$DENY" kensho "curl -s https://example.com -o /tmp/x"  0 "一時領域: curl -o"
run "$DENY" kensho "echo x > /tmp/a && echo y > README.md"  2 "混在: 一時領域と対象が混じれば止める"
run "$DENY" kensho "echo x > README.md"                     2 "阻止: 対象への書き込み"

run "$DENY" kensho "cp /etc/hosts /tmp/x/h"                 0 "読み元が対象でも書き先が一時領域なら通す"
run "$DENY" kensho "cp /tmp/x/a ./README.md"                2 "書き先が対象なら止める"
run "$DENY" kensho "mv /tmp/x/a /tmp/x/b"                   0 "一時領域内の mv"
run "$DENY" kensho "touch /tmp/x/f"                         0 "一時領域の touch"
run "$DENY" kensho "sed -n '1,5p' f | grep -i foo"          0 "区切りを越えて -i を拾わない"
run "$DENY" kensho "sed 's/a/b/' f | sort -i"               0 "同上"
run "$DENY" kensho "rm -f /tmp/claude-1000/x/scratchpad/t"   0 "一時領域の rm -f（検証の役が実際に踏んだパス）"
run "$DENY" kensho "mv /tmp/x/a ~/project/x"                 2 "書き先が対象なら止める（mv）"
run "$DENY" kensho "touch README.md"                        2 "阻止: touch（対象内）"
run "$DENY" kensho "sed -i 's/a/b/' f"                      2 "阻止: sed -i（上の過検知2件の対になる本命。ここが緑だと -i を一切見ていない）"
run "$DENY" kensho "mkdir -p ~/project/newdir"               2 "阻止: ~/ 配下の mkdir（/tmp でないので通さない）"

# D. 初期版でこぼれた4経路（二度と通さない）
#   書き先を /tmp/z から ./z に変えた。「一時領域は通す」以後、/tmp/z への書き込みは
#   シェル経由では通る（上の `echo x > /tmp/scratch.txt`）のに、インタプリタ経由だけ止めていた。
#   この検体が固定したいのは「python/node の書き込み構文を見ているか」であって、/tmp/z ではない。
#   /tmp/z の版は H 節で「通す」側の対として置いた。
run "$DENY" kensho "python3 -c \"open('./z','w').write('x')\"" 2 "D の穴: python open(w)（対象内）"
run "$DENY" kensho "node -e \"require('fs').writeFileSync('./z','x')\"" 2 "D の穴: node writeFileSync（対象内）"
run "$DENY" kensho "ed -s ./README.md"            2 "D の穴: ed（対象内）"
run "$DENY" kensho "ed -s /tmp/z"                 0 "一時領域の ed は通す"
run "$DENY" kensho "sed -n 'w /tmp/z' /etc/hosts" 2 "D の穴: sed の w"

# E. 初期版でこぼれた経路（2）
run "$DENY" kensho "python3 -c \"import os;os.system('cp a b')\"" 2 "E の穴: os.system"
run "$DENY" kensho "node -e \"require('fs').openSync('./z','w')\"" 2 "E の穴: node openSync（対象内）"

# H. 検証の役の実測（サンドボックスが作れず検証の網羅性が下がった）。
#    過検知側を足したら本命も足す。通す検体と止める検体を**対で**置く。
SCR="/tmp/claude-1000/-home-x-project/55df49f1-0000-0000-0000-000000000000/scratchpad"
# H-1 複数引数の mkdir。原因1: 行継続（\ + 改行）を SEGS が改行で割り、末尾の \ が書き先に数えられた
run "$DENY" kensho "$(printf 'mkdir -p %s/root/tools/hooks \\\n  %s/root/state' "$SCR" "$SCR")" 0 "H-1: 行継続で並べた複数の一時領域 mkdir は通す"
run "$DENY" kensho "$(printf 'mkdir -p %s/root/tools/hooks \\\n  ./root/state' "$SCR")"     2 "H-1: 行継続でも対象が混じれば止める"
# H-1 原因2: 引用符で囲んだパスが空白に潰され、書き先が 0 個になっていた
run "$DENY" kensho "mkdir -p \"$SCR/root/tools/hooks\" \"$SCR/root/state\""  0 "H-1: 引用符付きの複数の一時領域 mkdir は通す"
run "$DENY" kensho "mkdir -p \"$SCR/root/tools/hooks\" \"./root/state\""     2 "H-1: 引用符付きでも対象が混じれば止める"
run "$DENY" kensho "mkdir -p '$SCR/root/state'"                              0 "H-1: 単一引用符の一時領域 mkdir も通す"
run "$DENY" kensho "mkdir -p '~/project/newdir'"                              2 "H-1: 引用符付きの ~/ 配下は止める"
run "$DENY" kensho "cp \"/etc/hosts\" \"$SCR/h\""                            0 "H-1: 引用符付き cp、書き先が一時領域なら通す"
run "$DENY" kensho "grep -rn 'rm' src/"                                      0 "H-1の対: 引用符内の単語 rm はパスでないので今までどおり潰す（残すと rm 実行に見える）"
run "$DENY" kensho "grep -rn 'x/rm' src/"                                    0 "H-1の対: / を含む literal を残しても rm の実行とは読まない"
# H-2 インタプリタ経由。_tmp_only はリダイレクト先しか見ておらず、関数引数のパスを見ていなかった
run "$DENY" kensho "$(printf "python3 - <<EOF\nimport os\nos.makedirs('%s/root/state', exist_ok=True)\nEOF" "$SCR")" 0 "H-2: heredoc の os.makedirs（一時領域のみ）は通す（検証の役が実際に踏んだ形）"
run "$DENY" kensho "$(printf "python3 - <<EOF\nimport os\nos.makedirs('./newdir', exist_ok=True)\nEOF")"        2 "H-2: heredoc の os.makedirs（対象内）は止める"
run "$DENY" kensho "python3 -c \"open('$SCR/out.txt','w').write('x')\""      0 "H-2: open(w) の先が一時領域なら通す"
run "$DENY" kensho "python3 -c \"open('/tmp/a','w'); open('README.md','w')\"" 2 "H-2: 一時領域と対象が混じれば止める（相対パスも拾う）"
run "$DENY" kensho "python3 -c \"open(p,'w').write('x')\""                   0 "H-2→I: 書き先が literal でない（変数）なら止めず warn を出す（止めると調査の役の全 python が使えない）"
run "$DENY" kensho "python3 -c \"import shutil; shutil.copy('/etc/hosts','$SCR/h')\"" 0 "H-2→I: 読み元 /etc は書き先ではない。書き先 $SCR/h が一時領域なら通す（過検知は安全側ではない）"
run "$DENY" kensho "python3 -c \"from pathlib import Path; Path('$SCR/x').write_text('y')\"" 0 "H-2: pathlib の write_text（一時領域）は通す"
run "$DENY" kensho "python3 -c \"from pathlib import Path; Path('README.md').write_text('y')\"" 2 "H-2: pathlib の write_text（対象内）は止める"
run "$DENY" kensho "node -e \"require('fs').writeFileSync('/tmp/z','x')\""   0 "H-2: node writeFileSync（一時領域）は通す（D 節の対）"
run "$DENY" kensho "node -e \"require('fs').openSync('/tmp/z','w')\""        0 "H-2: node openSync（一時領域）は通す（E 節の対）"
run "$DENY" kensho "python3 -c \"import os;os.system('cp /tmp/a /tmp/b')\""  2 "H-2の対: os.system の引数はコマンドでありパスでない。一時領域でも通さない"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['rm','-rf','/tmp/x'])\"" 2 "H-2の対: subprocess の引数も同じ。通さない"
run "$DENY" kensho "python3 -c \"open('/tmp/x','wb').write(__import__('urllib.request').request.urlopen('https://example.com/a').read())\"" 0 "H-2: URL の // をパスと誤読しない"

# I. 読み取り専用の役が実測で踏んだ過検知4種。
#    通す検体と止める検体を**対で**置く。
#    (a) ヒアドキュメント本体・コメント中の比較演算子 `>=` `>` や `->` を「リダイレクト」と読んでいた
run "$DENY" chosa "$(printf "python3 - <<'EOF'\nimport json\nrows=[r for r in data if r['likes']>=20]\nprint(\"== likes>=20\", len(rows))\nEOF")" 0 "I-a: heredoc 本体の >= と文字列 \"== likes>=20\" はリダイレクトでない（調査の役が実際に踏んだ形）"
run "$DENY" chosa "$(printf "python3 - <<'EOF'\n# a -> b\nok = b>200\nEOF")"                        0 "I-a: heredoc 本体のコメント -> と比較 b>200（実測）"
run "$DENY" chosa "$(printf "ls docs  # a -> b\nls minutes")"                                        0 "I-a: シェルコメント中の -> はリダイレクトでない"
run "$DENY" chosa "$(printf "python3 - <<'EOF'\nfrom PIL import Image\nex = Image.Exif()\nln = 3\nEOF")" 0 "I-a: heredoc 本体の変数名 ex / ln をコマンド ex / ln と読まない"
run "$DENY" kensho "echo x > ~/project/foo"                                                           2 "I-a の対: トップレベルの実リダイレクト（対象）"
run "$DENY" kensho "echo x >= file"                                                                  2 "I-a の対: トップレベルの >= は bash では『= という名のファイルへの書き込み』。止める"
run "$DENY" kensho "$(printf "cat > ~/project/x <<'EOF'\nhello\nEOF")"                                2 "I-a の対: heredoc の**外**にあるリダイレクトは見る"
run "$DENY" kensho "$(printf "bash <<'EOF'\nrm -rf ./docs\nEOF")"                                    2 "I-a の対: heredoc の受け手がシェル(bash/sh)なら本体は実行されるコマンド。落とさない"
run "$DENY" kensho "$(printf "ls docs  # comment\nrm -rf ./docs")"                                   2 "I-a の対: コメント除去は行末まで。次の行の rm は見る"
#    (b) 同一コマンド内で代入した変数（S=/tmp/...; mkdir -p $S/x）を展開せず、$S が /tmp に合わず止めていた
run "$DENY" chosa "S=$SCR; mkdir -p \$S/qiita"                                                       0 "I-b: 同一コマンド内で代入した変数を展開してから判定（一時領域）"
run "$DENY" chosa "$(printf "mkdir -p %s/qiita && python3 - <<'EOF'\nimport json\nrows=[r for r in data if r['likes']>=20]\nEOF" "$SCR")" 0 "I-b: scratchpad の mkdir ＋ heredoc python の >=（調査の役が実際に踏んだ形）"
run "$DENY" kensho "S=~/project; mkdir -p \$S/newdir"                                                 2 "I-b の対: 展開先が対象なら止める"
run "$DENY" kensho "mkdir ~/project/newdir"                                                           2 "I-b の対: 素の mkdir（対象）"
run "$DENY" kensho "mkdir -p \$UNDEFINED_VAR/x"                                                      2 "I-b の対: 展開できない変数は一時領域と認めない（従来どおり）"
#    (c) open(変数,'w') を「判定不能＝止める」にしていた／読み元パスを書き先に数えていた／sys.stdout.write を書き込みと読んでいた
run "$DENY" chosa "python3 -c \"p='$SCR/out.json'; open(p,'w').write('x')\""                          0 "I-c: 第1引数が変数でも同一コード内の代入から一時領域と分かれば通す"
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nsrc='$HOME/dev/photos'\nopen('%s/out.json','w').write(src)\nEOF" "$SCR")" 0 "I-c: 読み元 /home/... が同居しても書き先が一時領域なら通す（検証の役が実際に踏んだ形）"
run "$DENY" kensho "python3 -c \"import sys; sys.stdout.write('x')\""                                0 "I-c: sys.stdout.write はファイル書き込みでない"
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nwith open('%s/o.txt','w') as f:\n    f.write('x')\nEOF" "$SCR")" 0 "I-c: with open(...) as f の f.write（一時領域）"
run "$DENY" kensho "python3 -c \"print(open('$REPO/README.md').read())\""          0 "I-c: mode 無しの open は読み取り。対象でも通す"
run "$DENY" kensho "python3 -c \"open('$REPO/x','w')\""                            2 "I-c の対: literal の書き先が対象なら止める"
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nopen('$REPO/x','w').write('x')\nEOF")" 2 "I-c の対: heredoc 本体の open(w) も見る（⑥は raw を見る）"
run "$DENY" kensho "python3 -c \"p='$REPO/x'; open(p,'w').write('x')\""             2 "I-c の対: 変数を辿って対象と分かれば止める"
run "$DENY" kensho "python3 -c \"import shutil; shutil.copy('/tmp/a','README.md')\""                 2 "I-c の対: shutil.copy の書き先（最後の引数）が対象なら止める"
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nwith open('README.md','w') as f:\n    f.write('x')\nEOF")" 2 "I-c の対: with open(...) as f の f.write（対象）"
run "$DENY" kensho "python3 -c \"open('$REPO/x','w').write('x')\" > /tmp/log"      2 "I 抜け道（実証 exit=0）: > /tmp/… が1つあると ⑥ が丸ごと通っていた。塞ぐ"
#    (d) git stash list が「git 変更系」で止まっていた
run "$DENY" kensho "git stash list"                                                                  0 "I-d: git stash list は読み取り"
run "$DENY" kensho "git stash show -p 'stash@{0}'"                                                   0 "I-d: git stash show も読み取り"
run "$DENY" kensho "git stash drop"                                                                  2 "I-d の対: git stash drop は変更"
run "$DENY" kensho "git stash pop"                                                                   2 "I-d の対: git stash pop は変更"
run "$DENY" kensho "git stash"                                                                       2 "I-d の対: 引数なし git stash は push＝作業ツリーを変更"
run "$DENY" kensho "git stash list && git stash clear"                                               2 "I-d の対: 読み取りと変更が混じれば止める"

# J. `subprocess.*` はトークンの存在だけで止まっていた（起動されるコマンドを見ていなかった）。
#    別セッションの検証の役が被弾した形＝「/tmp に検体を作り、subprocess.run で対象スクリプトを起動して出力を比較する」。
#    検証の役は迂回せず bash ループへ書き換えて同じ検証を通した（正しい振る舞い）が、その分だけ計測経路が減った。
#    通す検体と止める検体を**対で**置く。
#    J-1 報告された形そのもの（heredoc・書き先は /tmp のみ・起動先は読み取り用のスクリプト）
run "$DENY" chosa "$(printf "python3 - <<'EOF'\nimport subprocess, os\nos.makedirs('/tmp/vtp_cmp', exist_ok=True)\nopen('/tmp/vtp_cmp/a.txt','w').write('sample')\nr = subprocess.run(['bash','verify.sh'], capture_output=True, text=True)\nopen('/tmp/vtp_cmp/out.txt','w').write(r.stdout)\nEOF")" 0 "J: /tmp だけに書き subprocess.run で起動する検証コード（検証の役が実際に踏んだ形）"
#    J-2 引数が読み取りコマンドなら通す
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['git','log','--oneline','-3'], capture_output=True)\"" 0 "J: subprocess.run の引数が git log（読み取り）なら通す"
run "$DENY" kensho "python3 -c \"import subprocess; print(subprocess.check_output(['cat','/etc/hostname']))\"" 0 "J: check_output(cat) は読み取り"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['ls','-l','/tmp/vtp_cmp'])\"" 0 "J: ls は読み取り"
run "$DENY" kansa "python3 -c \"import subprocess; subprocess.run(['crontab','-l'], capture_output=True)\"" 0 "J: crontab -l は読み取り（監査の役が cron 配線の点検に要る）"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['bash','-c','ls docs | head -3'], capture_output=True)\"" 0 "J: bash -c の中身が読み取りだけなら通す"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(cmd, capture_output=True)\"" 0 "J: 起動コマンドが変数で辿れない → warn を出して通す（open と同じ扱い）"
#    J-2 の対（ここが緑だと起動コマンドを一切見ていない）
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['rm','-rf','$REPO/docs'])\"" 2 "J の対: subprocess 経由の rm（対象配下）"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run('cat x > $REPO/x', shell=True)\"" 2 "J の対: shell=True の文字列はシェル判定に掛ける"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['git','commit','-m','x'])\"" 2 "J の対: subprocess 経由の git commit"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.check_output(['git','push'])\"" 2 "J の対: subprocess 経由の git push"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['sed','-i','s/a/b/','f'], cwd='$REPO')\"" 2 "J の対: subprocess 経由の sed -i"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.Popen(['mkdir','./newdir'])\"" 2 "J の対: subprocess 経由の mkdir（対象内）"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['bash','-c','rm -rf ./docs'])\"" 2 "J の対: bash -c の中身が変更系なら止める"
run "$DENY" kensho "python3 -c \"import subprocess; cmd=['rm','-rf','./docs']; subprocess.run(cmd)\"" 2 "J の対: 変数でも同一コード内の代入から辿れれば止める"
#    J-3 起動先が python3 -c の場合。argv からは判定できない（warn が出る）が、⑥ の open(write) 判定が生のコードを見るので
#        書き込み側は落ちる。**層が2つあることを検体で固定する**（片方だけ直すと静かに穴が開く）。
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nimport subprocess\nsubprocess.run(['python3','-c','open(\"README.md\",\"w\").write(\"x\")'])\nEOF")" 2 "J: subprocess 経由の python3 -c でも、対象への open(w) は ⑥ が見る"
run "$DENY" kensho "$(printf "python3 - <<'EOF'\nimport subprocess\nsubprocess.run(['python3','-c','print(open(\"README.md\").read())'])\nEOF")" 0 "J の対: 同じ形でも読み取りだけなら通す"

# K. 検証の役から引き継いだ過検知3件。
#    3件とも **「実物を読んで /tmp に写しを書く」＝変異検証そのものの形** を塞いでいた。
#    **通す側と止める側を必ず対で置く**（片方だけだと、直しすぎたことに気づけない）。
#
# K-1 mktemp のコマンド置換。`$(mktemp -d)` は代入の値の正規表現で `$` に切れていた。
run "$DENY" kensho 'D=$(mktemp -d); mkdir -p $D/mut'        0 "K: mktemp 代入 → 配下に mkdir"
run "$DENY" kensho 'mkdir -p "$(mktemp -d)/mut"'            0 "K: mktemp を直に挿す形"
run "$DENY" kensho 'D=$(mktemp -d); echo hi > $D/x'         0 "K: mktemp 配下へのリダイレクト"
run "$DENY" kensho 'D=`mktemp -d`; mkdir -p $D/mut'         0 "K: バッククォート形"
#    対（止める側）: mktemp でも**行き先を明示していれば /tmp とは限らない**。
run "$DENY" kensho "D=\$(mktemp -d $REPO/XXXX); mkdir -p \$D/x" 2 "K の対: テンプレートが /home"
run "$DENY" kensho "D=\$(mktemp -d -p $HOME); mkdir -p \$D/x"          2 "K の対: -p で行き先指定"
run "$DENY" kensho "D=\$(mktemp -d --tmpdir=$HOME); mkdir -p \$D/x"    2 "K の対: --tmpdir で行き先指定"
#
# K-2 chmod / chown の第1引数はパスではない。`+x` `755` を書き先と数えていた。
run "$DENY" kensho 'chmod +x /tmp/claude-1000/x/mut.sh'     0 "K: chmod +x（一時領域）"
run "$DENY" kensho 'chmod 755 /tmp/claude-1000/x/mut.sh'    0 "K: chmod 8進モード"
run "$DENY" kensho 'chmod -R u+w /tmp/claude-1000/s'        0 "K: chmod 記号モード＋フラグ"
run "$DENY" kensho 'chown user:group /tmp/claude-1000/x' 0 "K: chown user:group（一時領域）"
#    対（止める側）: モード語を飛ばしても、**パスがリポジトリ内なら止まる**こと。
run "$DENY" kensho "chmod +x $REPO/tools/x.sh" 2 "K の対: chmod の対象がリポジトリ内"
run "$DENY" kensho 'chmod 755 tools/x.sh'                   2 "K の対: chmod の対象が相対パス"
run "$DENY" kensho "chown root:root $REPO/x" 2 "K の対: chown の対象がリポジトリ内"
#
# K-3 python の str.replace() を Path.replace と誤読していた。
#     `open(...).read()` は**文字列**であってパスではない。読んだ中身と読み元のパスの取り違え。
run "$DENY" kensho "$(printf 'python3 - <<EOF\ns = open("$REPO/verify.sh").read()\nopen("/tmp/claude-1000/s/mut.sh","w").write(s.replace("a","b"))\nEOF')" 0 "K: 実物を読んで /tmp に写しを書く（変異検証の形）"
run "$DENY" kensho "python3 -c 's=\"x\"; print(s.replace(\"a\",\"b\"))'" 0 "K: 素の str.replace"
#    対（止める側）: Path.replace は引数1つ。ファイルの置き換えなので止まること。
run "$DENY" kensho "python3 -c 'from pathlib import Path; Path(\"$REPO/x\").replace(\"y\")'" 2 "K の対: Path.replace（引数1つ）は止める"
run "$DENY" kensho "python3 -c 'open(\"$REPO/x\",\"w\").write(\"z\")'" 2 "K の対: リポジトリ内への open(w) は止める"
run "$DENY" kensho "python3 -c 'import pathlib; pathlib.Path(\"$REPO/x\").write_text(\"z\")'" 2 "K の対: Path.write_text は止める"
#
# K-4 近傍の過検知2件。
run "$DENY" kensho 'systemctl is-system-running'            0 "K: systemctl の読み取りサブコマンド"
run "$DENY" kensho 'echo sed -i is dangerous'               0 "K: echo の引数はデータであってコマンドではない"
#    対（止める側）: echo でもコマンド置換とリダイレクトは実行・書き込みである。
run "$DENY" kensho "echo \$(rm -rf $REPO/x)" 2 "K の対: echo 内のコマンド置換は実行される"
run "$DENY" kensho "echo hi > $REPO/x"    2 "K の対: echo でもリダイレクトは書き込み"
run "$DENY" kensho 'systemctl restart nginx'                2 "K の対: systemctl の変更系は止める"

# L. **独立検証で見つかった穴**。
#    L-1/L-2 は**最初の是正で作り込んだ退行**、L-3 はその前から在った素通り、
#    L-4 は**是正の半分が一度も測られていなかった**箇所。
#
# L-1: mktemp の行き先は TMPDIR で変わる。最初の mktemp 是正がこれを見ていなかった。
run "$DENY" kensho "export TMPDIR=$REPO; D=\$(mktemp -d); mkdir -p \$D/evil" 2 "L-1: TMPDIR が一時領域の外なら mktemp を信用しない"
run "$DENY" kensho "TMPDIR=$HOME D=\$(mktemp -d); touch \$D/x"                        2 "L-1: 前置代入の TMPDIR でも同じ"
run "$DENY" kensho 'export TMPDIR=/tmp/mine; D=$(mktemp -d); mkdir -p $D/ok'                   0 "L-1 の対: TMPDIR が一時領域内なら通す"
#
# L-2: `..` を含むパスを一時領域と認めない。**8形中7形が素通りしていた。**
run "$DENY" kensho "rm -rf /tmp/..$REPO/docs"                     2 "L-2: rm で上へ抜ける"
run "$DENY" kensho "echo x > /tmp/..$REPO/README.md"              2 "L-2: リダイレクトで上へ抜ける"
run "$DENY" kensho "mkdir -p /tmp/..$REPO/newdir"                 2 "L-2: mkdir で上へ抜ける"
run "$DENY" kensho "touch /tmp/claude-1000/../..$REPO/x"          2 "L-2: 途中に .. がある"
run "$DENY" kensho "cp /etc/hosts /tmp/..$REPO/x"                 2 "L-2: cp の書き先が上へ抜ける"
run "$DENY" kensho "dd of=/tmp/..$REPO/x"                         2 "L-2: dd of= で上へ抜ける"
run "$DENY" kensho "python3 -c 'open(\"/tmp/..$REPO/x\",\"w\").write(\"z\")'" 2 "L-2: python の書き先が上へ抜ける"
run "$DENY" kensho 'rm -rf /tmp/claude-1000/x/scratchpad'                           0 "L-2 の対: 素直な一時領域は通す"
run "$DENY" kensho 'echo hi > /tmp/claude-1000/x/y'                                 0 "L-2 の対: 素直なリダイレクトは通す"
#
# L-3: `echo` 是正のうち **CMDS ループ側**（変更系コマンド名の検出）に検体が0本だった。
#     `echo sed -i ...` は _MUT_PATTERNS 側でしか効かず、**片方を壊しても誰も気づかなかった**。
run "$DENY" kensho "echo rm -rf $REPO は危険だ"   0 "L-3: echo の引数の rm はデータ（CMDS ループ側）"
run "$DENY" kensho 'echo mkdir でディレクトリを作る'                 0 "L-3: echo の引数の mkdir はデータ"
run "$DENY" kensho 'echo chmod +x について説明する'                  0 "L-3: echo の引数の chmod はデータ"
run "$DENY" kensho 'printf "git commit の使い方\n"'                  0 "L-3: printf の引数もデータ"
run "$DENY" kensho "echo rm -rf x && rm -rf $REPO/y" 2 "L-3 の対: 後続セグメントの実コマンドは止める"

# M. `sed の w` の過検知。**検証の役が検証中に2回踏み、作業が妨げられた。**
#    原因は2つ: ①`[^'"]*` が改行を含み、引用符が1つあれば離れた行の `w ` に届いた
#               ②`sed` の在処と `w` の在処を別々に見ていた（同じ sed 呼び出しの中かを見ていない）
#    **過検知は安全側の失敗ではない。** ガードが検証そのものを妨げた実例である。
run "$DENY" kensho 'for w in alpha beta; do printf "%s\n" "$w"; done; sed -n "1,1p" README.md' 0 "M: ループ変数 w ＋ sed -n（検証の役が実際に踏んだ）"
run "$DENY" kensho 'echo "for w in を消したら通るか"'                     0 "M: 引用符の中で w に言及しただけ"
run "$DENY" kensho "sed -n '1,5p' README.md | grep -i foo"                0 "M: 素の sed -n（パイプ越し）"
run "$DENY" kensho "sed 's/foo/bar w baz/' README.md"                     0 "M: 置換の**中**の w はコマンドではない"
run "$DENY" kensho "sed -E 's/1/2 w x/' README.md"                        0 "M: 数字の直後の w も置換の中なら通す"
#    対（本物の sed w は今も止まること）。**アドレス付き・フラグ位置も含めて撃つ。**
run "$DENY" kensho "sed -n '1,5w $REPO/out.txt' README.md"   2 "M の対: 行範囲アドレス＋w"
run "$DENY" kensho "sed -n '/pat/w $REPO/o.txt' README.md"   2 "M の対: 正規表現アドレス＋w"
run "$DENY" kensho "sed -n '\$w $REPO/o.txt' README.md"      2 "M の対: \$ アドレス＋w"
run "$DENY" kensho "sed 's/a/b/w $REPO/o.txt' README.md"     2 "M の対: s///w のフラグ位置"
run "$DENY" kensho "sed 's/a/b/; w $REPO/x.txt' README.md"   2 "M の対: セミコロンの後の w"

# N. **検証の役が別の作業を検証している最中に踏んだ過検知2件。**
#    どちらも「一時領域の写しで挙動を確かめよ」という指示そのものを妨げた。
#    ⚠ とくに sed -i は、`tools/mutation_check.sh` が内部で同じことを写しに撃っているので、
#      **スクリプト経由なら通り、人が手で撃つと止まる**という非対称になっていた。
run "$DENY" kensho 'git merge-base --is-ancestor abc123 HEAD'      0 "N: git merge-base は読み取りだけ（git merge に前方一致で誤爆していた）"
run "$DENY" kensho 'git merge-tree abc def'                        0 "N: git merge-tree も読み取り"
run "$DENY" kensho "sed -i -E 's/a/b/' /tmp/claude-1000/x/copy.sh"  0 "N: 一時領域の写しへの sed -i"
run "$DENY" kensho 'D=$(mktemp -d); sed -i "s/a/b/" $D/x.sh'        0 "N: mktemp 配下への sed -i"
run "$DENY" kensho "sed -i -e 's/a/b/' /tmp/claude-1000/x/a.sh /tmp/claude-1000/x/b.sh" 0 "N: -e つき・複数ファイルでも一時領域なら通す"
#    対（止める側）。**書き先を見るようにしただけで、対象を守る力は落としていない。**
run "$DENY" kensho "sed -i -E 's/a/b/' tools/gate_check.sh"         2 "N の対: リポジトリ内への sed -i"
run "$DENY" kensho "sed -i 's/a/b/' $REPO/CLAUDE.md" 2 "N の対: 絶対パスでリポジトリ内"
run "$DENY" kensho "sed -i 's/a/b/' /tmp/..$REPO/x"  2 "N の対: /tmp/../ で上へ抜ける"
run "$DENY" kensho "sed -i -E 's/a/b/' /tmp/claude-1000/x/a.sh tools/y.sh" 2 "N の対: 1つでも対象が混じれば止める"
run "$DENY" kensho "perl -i -pe 's/a/b/' tools/x.sh"                2 "N の対: perl -i でリポジトリ内"
run "$DENY" kensho 'git merge feature'                              2 "N の対: 本物の git merge は止める"

# O. 独立検証で素通りが実測された6経路と、過検知1件。**通す検体と止める検体を対で置く。**
#    素通り: rsync / find -delete / bash -c "…" / eval "…" / sort -o / patch。
#    find の検出は subprocess の argv 側にだけあり、シェル文字列側では一度も呼ばれていなかった。
#    bash -c / eval は、引用リテラルを潰す掃除（①）が中身を判定から外していた。
run "$DENY" kensho 'rsync -a /tmp/x/ ./'                                  2 "O-1: rsync の書き先が対象"
run "$DENY" kensho "rsync -a /tmp/x/ $REPO/"                              2 "O-1: rsync の書き先が絶対パスで対象"
run "$DENY" kensho 'rsync -a ./ /tmp/x/'                                  0 "O-1 の対: rsync の書き先が一時領域（読み元が対象でも通す）"
run "$DENY" kensho 'rsync -avn /tmp/x/ ./'                                0 "O-1 の対: rsync -n（dry-run）は書かない"
run "$DENY" kensho 'find . -name "*.md" -delete'                          2 "O-2: find -delete（起点がカレント＝対象）"
run "$DENY" kensho "find $REPO -type f -delete"                           2 "O-2: find -delete（起点が絶対パスで対象）"
run "$DENY" kensho 'find . -name "*.md" -exec rm {} \;'                   2 "O-2: find -exec rm"
run "$DENY" kensho "find . -type f -exec sed -i 's/a/b/' {} \;"           2 "O-2: find -exec sed -i"
run "$DENY" kensho 'find /tmp/x -name "*.md" -delete'                     0 "O-2 の対: 起点が一時領域なら -delete も通す"
run "$DENY" kensho 'find /tmp/x -exec rm {} \;'                           0 "O-2 の対: 起点が一時領域なら -exec rm も通す（CMDS の rm で先に止めない）"
run "$DENY" kensho 'find . -name "*.md"'                                  0 "O-2 の対: -delete/-exec の無い find は読み取り"
run "$DENY" kensho "find . -name '*.md' -exec grep -l foo {} +"           0 "O-2 の対: -exec の起動先が読み取り（grep）なら通す"
run "$DENY" kensho 'find . -exec ./mytool {} \;'                          0 "O-2 の対: 起動先が自作スクリプトなら warn を出して通す（open / subprocess と同じ扱い）"
run "$DENY" kensho 'bash -c "rm -rf docs"'                                2 "O-3: bash -c の引用文字列の中の rm"
run "$DENY" kensho 'bash -x -c "git commit -m x"'                         2 "O-3: フラグ付きでも -c の中身を見る"
run "$DENY" kensho "sh -c 'echo x > README.md'"                           2 "O-3: sh -c の中のリダイレクト"
run "$DENY" kensho 'bash -c "ls docs | head -3"'                          0 "O-3 の対: 中身が読み取りだけなら通す"
run "$DENY" kensho "sh -c 'rm -rf /tmp/x'"                                0 "O-3 の対: 中身が一時領域だけなら通す"
run "$DENY" kensho 'bash -c "$CMD"'                                       0 "O-3 の対: 中身が変数なら静的に読めない → warn を出して通す"
run "$DENY" kensho 'eval "rm -rf docs"'                                   2 "O-4: eval の引用文字列の中の rm"
run "$DENY" kensho "eval 'git commit -m x'"                               2 "O-4: eval の中の git commit"
run "$DENY" kensho 'eval rm -rf docs'                                     2 "O-4: 引用符の無い eval は従来どおり ⑤ が止める"
run "$DENY" kensho 'eval "ls -l"'                                         0 "O-4 の対: 中身が読み取りなら通す"
run "$DENY" kensho "eval 'echo hi > /tmp/x/y'"                            0 "O-4 の対: 中身が一時領域への書き込みなら通す"
run "$DENY" kensho 'sort -o README.md README.md'                          2 "O-5: sort -o の書き先が対象"
run "$DENY" kensho 'sort --output=README.md f'                            2 "O-5: --output= 形"
run "$DENY" kensho 'sort -o /tmp/x/out f'                                 0 "O-5 の対: 書き先が一時領域"
run "$DENY" kensho 'sort f | head'                                        0 "O-5 の対: -o の無い sort は読み取り"
run "$DENY" kensho "python3 -c \"import subprocess; subprocess.run(['sort','-o','README.md','f'])\"" 2 "O-5: subprocess 経由の sort -o"
run "$DENY" kensho 'patch -p1 < /tmp/p.diff'                              2 "O-6: patch の書き先は diff の中身で決まる＝静的に読めないので止める"
run "$DENY" kensho 'patch -p1 -i /tmp/p.diff'                             2 "O-6: -i 形も同じ（-i の値は読み元）"
run "$DENY" kensho "patch -p1 -d $REPO < /tmp/p.diff"                     2 "O-6: -d で対象を指した"
run "$DENY" kensho 'patch --dry-run -p1 < /tmp/p.diff'                    0 "O-6 の対: --dry-run は書かない"
run "$DENY" kensho 'patch -d /tmp/x -p1 < /tmp/p.diff'                    0 "O-6 の対: -d で一時領域を指した（写しに当てる形）"
run "$DENY" kensho 'patch /tmp/x/f /tmp/p.diff'                           0 "O-6 の対: 元ファイルが一時領域"
#    過検知: 引用リテラルが `^` `\` を含むと空白に潰され、最初のファイル引数がスクリプトに数えられていた。
run "$DENY" kensho "sed -i '/^tests\/run_loop_guard\.sh\t/d' /tmp/claude-1000/x/mutations.tsv" 0 "O-7: スクリプト部が素のパスに見えない sed -i でも、書き先が一時領域なら通す（実測の過検知）"
run "$DENY" kensho "sed -i -e '/^x\t/d' /tmp/claude-1000/x/a"             0 "O-7: -e 形でも同じ"
run "$DENY" kensho "sed -i '/^x/d' tests/mutations.tsv"                   2 "O-7 の対: 同じ形で書き先が対象なら止める"
run "$DENY" kensho "sed -i '/^x/d' /tmp/claude-1000/x/a tests/mutations.tsv" 2 "O-7 の対: 1つでも対象が混じれば止める"
run "$DENY" kensho "grep 'find . -delete' README.md"                      0 "O の対: 引用符の中の find -delete はデータ"
run "$DENY" kensho "grep -rn 'rm -rf' src/ | sort | head"                 0 "O の対: 引用符の中の rm と -o の無い sort"

# P. **既知の穴（現状の挙動を固定する検体）**。独立検証（第2ラウンド）で見つかり、未修正のまま。
#    二重引用符の中のコマンド置換は、① が引用リテラルを目印（QLIT）に潰すので中身が判定に掛からない。
#    引用符なしの `echo $(rm …)` は K の対で止まる（上）。この非対称を記録する。
#    ⚠ 既知の穴。塞いだらこの検体の期待値を 2 に変える。
run "$DENY" kensho "echo \"\$(rm -rf $REPO/x)\"" 0 "P: 既知の穴。二重引用符の中のコマンド置換は現状通る（塞いだら期待値を 2 に変える）"
run "$DENY" kensho "\$(echo rm) -rf $REPO/x" 0 "P: 既知の穴。コマンド置換でコマンド名を作る形は現状通る（塞いだら期待値を 2 に変える）"

# F. 対象外の役は素通り（ゲートを足すとき、対象でない者に何が起きるかを必ず試す）
run "$DENY" shukko "git commit -m x"              0 "対象外: 書く役は通る"
run "$DENY" ""     "git commit -m x"              0 "対象外: 主セッション（ここが赤だと全部が動かない）"
run "$DENY" ""     "rm -rf /tmp/zzz"              0 "対象外: 主セッション"

# G. コミット名義（期待値は上の harness.conf）
run "$IDENT" "" 'git commit -m "x"'               0 "名義: -c 無しは global が使われる"
run "$IDENT" "" 'git log --oneline -3'            0 "名義: 読み取りは対象外"
run "$IDENT" "" 'git -c user.email=BADMAIL commit -m x'  2 "名義: メールが違う"
run "$IDENT" "" 'git -c user.name=BADNAME commit -m x'   2 "名義: 名前が違う"
run "$IDENT" "" 'GIT_AUTHOR_EMAIL=BADMAIL git commit -m x' 2 "名義: 環境変数での上書き"
run "$IDENT" "" 'git -c user.email="BADMAIL" commit -m x' 2 "名義: 値がクォートされていても捕まえる（閉じ引用符の飲み込みバグの検体）"
run "$IDENT" "" 'GIT_AUTHOR_EMAIL=BADMAIL bash .githooks/pre-commit ; git commit -m ok' 0 "過検知: 代入は前段のbashに掛かる（実際に踏んだ）"
run "$IDENT" "" 'cd /tmp && GIT_COMMITTER_NAME=BADNAME git commit -m x' 2 "名義: 複合コマンドの後段でも捕まえる"
run "$IDENT" "" "t 'cd /tmp && GIT_COMMITTER_NAME=BADNAME git commit -m x'" 0 "過検知: 引用符内の検体（3度踏んだ）"
run "$IDENT" "" 'git -c user.name="github-actions[bot]" -c user.email="x@y.z" commit -q -m draft' 2 "名義: bot 名義も既定では止める（別セッションから提供された実検体）"
# 過検知の検体: ヒアドキュメントの本文は実行されるコマンドではない
run "$IDENT" "" "$(printf 'cat > t.sh <<EOF\ngit -c user.email=BADMAIL commit -m x\nEOF')" 0 "過検知: ヒアドキュメント内の検体（実際に踏んだ）"
run "$IDENT" "" 'git -c user.email=someone@example.invalid -c user.name="Some One" commit -m x' 0 "名義: 上書きが期待値と一致すれば通る（ここが赤だと『上書き＝即止める』になっている）"
HARNESS_CONF="$TMP/none.conf" run "$IDENT" "" 'git -c user.email=someone@example.invalid commit -m x' 2 "名義: 期待値が未設定なら上書きを判定できないので止める（黙って通さない）"
HARNESS_CONF="$TMP/none.conf" run "$IDENT" "" 'git commit -m x' 0 "名義: 期待値が未設定でも上書きの無い commit は通る"

# Z. 設定（harness.conf）が読まれていること。役名の一覧を差し替えたら判定が変わる。
printf 'READONLY_AGENTS="auditor"\n' > "$TMP/alt.conf"
HARNESS_CONF="$TMP/alt.conf" run "$DENY" auditor "rm -rf ./docs" 2 "設定: READONLY_AGENTS に載せた役は止まる"
HARNESS_CONF="$TMP/alt.conf" run "$DENY" kensho  "rm -rf ./docs" 0 "設定: 一覧から外した役は通る（既定の5役を決め打ちしていない）"
HARNESS_CONF="$TMP/none.conf" run "$DENY" kensho "ls" 2 "設定: harness.conf が無ければサブエージェントの Bash は止まる（判定不能を黙って通さない）"
HARNESS_CONF="$TMP/none.conf" run "$DENY" ""     "ls" 0 "設定: harness.conf が無くても主セッションは止めない"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "== フック回帰スイート pass=$pass fail=0 =="; exit 0
else echo "== 赤 フック回帰スイート pass=$pass fail=$fail =="; exit 1; fi
