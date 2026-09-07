#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""unfinished_action.py — 「次にやると宣言して、やらずにターンを終える」を止める Stop フック。

型の由来: 「このまま次の判定に進みます」と書いて、サブエージェントを起動せずにターンを終えた事故。
      人が「止まっていませんか」と指摘するまで止まっていた。段取りを口で言って実行しない形は繰り返す。
      注意力で直すのは設計の敗北なので機構にする。

【この検査が保証すること・しないこと】
  保証する : 最終メッセージが「直近の一人称の行動宣言」で終わっているとき、一度だけ停止を差し戻す。
             加えて、検査が赤のまま／検査結果が古いまま止まろうとしたとき、一度だけ差し戻す。
  保証しない: 宣言の中身が正しいかは見ない。これは仕掛け線であって証明ではない。

【語彙】hooks/unfinished_vocab.txt（[declare] 宣言語 / [exclude] 除外語）。日本語のまま持つ。

【誤検知の扱い】待機・条件付き・他者主語は除外語で落とす。それでも誤って鳴ったら、
  「待機中」と一言添えて再度停止すればよい（stop_hook_active により二度は鳴らない）。
  **文言を検査に合わせて歪めないこと。** 誤検知が続くなら語彙のほうを疑う。

【撤退条件（先に決める・測れる形で）】
  `bash harness/stop_hook_stats.sh` が本番(real)の block を数える。
  **10回に達したら、人がログを読んで誤検知率を判定する**（機械は数えるだけ）。7割以上が誤検知ならこのフックを外す。
  **自動判定できないものを、自動判定するふりをしない。**
  あわせて「**本番で一度も呼ばれていない**」も検知する。「配線した」と「そのセッションで発火する」は別である。

【停止スイッチ】このファイルを rm するか、settings.json の該当行を消す。
"""
import datetime
import json
import os
import time
import re
import sys

# パスは **$HOME 決め打ちにしない。** CLAUDE_PROJECT_DIR か、スクリプトの位置から解決する。
# 環境が違えば $HOME も違う。cron・CI・別ユーザ、どれも $HOME を選ばない。
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.environ.get("CLAUDE_PROJECT_DIR") or os.path.dirname(_HERE)


def _read_conf(path):
    """harness.conf（KEY="value" の行）を読む。無ければ空。"""
    conf = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
                    v = v[1:-1]
                conf[k.strip()] = v
    except Exception:
        pass
    return conf


_CONF = _read_conf(os.environ.get("HARNESS_CONF") or os.path.join(_ROOT, "harness.conf"))
_STATE_DIR = os.path.join(_ROOT, _CONF.get("STATE_DIR") or "state")
_WATCH = (_CONF.get("VERIFY_WATCH_DIRS") or "hooks tools tests .claude").split()
LOG = os.path.join(_STATE_DIR, "unfinished_action.log")
RESULT = os.path.join(_STATE_DIR, "last_verify_result")


def _load_vocab(path):
    """[declare] / [exclude] の2節を持つ語彙ファイルを読む。無ければ空（＝言語判定は鳴らない）。"""
    sec, decl, excl = None, [], []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line in ("[declare]", "[exclude]"):
                    sec = line
                    continue
                if sec == "[declare]":
                    decl.append(line)
                elif sec == "[exclude]":
                    excl.append(line)
    except Exception:
        pass
    return decl, excl


_DECL_WORDS, _EXCL_WORDS = _load_vocab(os.path.join(_HERE, "unfinished_vocab.txt"))
# 直近の一人称の行動宣言
DECL = re.compile("(" + "|".join(re.escape(w) for w in _DECL_WORDS) + ")") if _DECL_WORDS else None
# 除外：待機・条件付き・他者が主語・否定・完了報告・疑問文・未来の説明
EXCL = re.compile("(" + "|".join(re.escape(w) for w in _EXCL_WORDS) + ")") if _EXCL_WORDS else None


_PAYLOAD = {}


def _mode_of():
    """本番の発火か、手で叩いたのかを見分ける。

    `UA_TEST` 環境変数の有無だけで見分けると、付け忘れた手動実行が本番として数えられる。
    Claude Code が Stop フックを呼ぶとき、入力には `prompt_id` が入る。手で叩いた JSON には普通これが無い。
    **環境変数（人が付ける）ではなく、入力の形（機械が付ける）で判定する。**
    """
    if os.environ.get("UA_TEST"):
        return "test"
    return "real" if _PAYLOAD.get("prompt_id") else "manual"


def note(decision, detail="", session="", mode=""):
    """ログは撤退条件の判定材料である。**測れない形で書かない。** session と mode（real/test/manual）を必ず残す。"""
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s\t%s\t%s\t%s\t%s\n" % (
                datetime.datetime.now().isoformat(timespec="seconds"),
                mode or _mode_of(),
                session[:8] or "-",
                decision,
                detail.replace("\t", " ").replace("\n", " ")[:300],
            ))
    except Exception:
        pass


def last_assistant_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    for line in reversed(lines[-400:]):
        line = line.strip()
        if not line:
            continue
        try:
            ent = json.loads(line)
        except Exception:
            continue
        if ent.get("type") != "assistant":
            continue
        content = (ent.get("message") or {}).get("content")
        if isinstance(content, str) and content.strip():
            return content
        if isinstance(content, list):
            parts = [c.get("text", "") for c in content
                     if isinstance(c, dict) and c.get("type") == "text"]
            joined = "".join(parts).strip()
            if joined:
                return joined
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    global _PAYLOAD
    _PAYLOAD = data
    sid = str(data.get("session_id") or "")

    # 【心拍】呼ばれたこと自体を必ず残す。早期 return の前に打ち、発火の有無を後から数えられるようにする。
    note("fired", "event=Stop active=%s" % bool(data.get("stop_hook_active")), sid)

    if data.get("stop_hook_active"):
        note("skip", "stop_hook_active", sid)
        return 0

    # 【最優先の除外】バックグラウンド作業の完了待ちなら、絶対に差し戻さない。
    #   公式スキーマの background_tasks は「セッションが終わった」と「背景作業の完了待ちで止まっている」を
    #   区別するためにある。背景サブエージェント待ちで Stop フックとデッドロックし、長時間のセッション枠を
    #   焼いた事故が報告されている。「待っている」は未完了ではない。
    bg = data.get("background_tasks") or []
    crons = data.get("session_crons") or []
    if bg:
        note("skip", "background_tasks %d 件の完了待ち（差し戻さない）" % len(bg), sid)
        return 0
    if crons:
        note("skip", "session_crons %d 件が生きている（差し戻さない）" % len(crons), sid)
        return 0

    # 最終出力は入力の `last_assistant_message` を第一情報源にする（transcript ファイルより先に渡される）。
    # transcript だけを読むと、書き込みが間に合わないとき「no assistant text」で黙って素通りする。
    text = (data.get("last_assistant_message") or "").strip()
    src = "input"
    if not text:
        tp = data.get("transcript_path") or ""
        if tp and os.path.exists(tp):
            try:
                text = last_assistant_text(tp) or ""
                src = "transcript"
            except Exception as e:
                note("skip", "read error: %s" % e, sid)
                return 0
    if not text:
        note("skip", "no assistant text (input/transcript とも空)", sid)
        return 0

    # 末尾3文だけを見る（本文中の言及ではなく「締めの宣言」を狙う）
    sentences = [s for s in re.split(r"(?<=[。．！？\n])", text) if s.strip()]
    hits = []
    if DECL is not None:
        hits = [s.strip() for s in sentences[-3:]
                if DECL.search(s) and not (EXCL is not None and EXCL.search(s))]

    # 言語だけでなく**状態**も見る（「宣言せずに黙って止まる」を埋める）。
    #   完了の定義は「検査が全緑」だけである。**検査が赤のまま止まろうとしたら、一度だけ差し戻す。**
    #   ⚠ 検査そのものはここで回さない（毎ターン数秒かかり timeout を圧迫する）。
    #     verify.sh が残した結果ファイルを1つ読むだけにする。
    state_reason = ""
    try:
        if os.path.exists(RESULT):
            kv = dict(l.strip().split("=", 1) for l in open(RESULT) if "=" in l)
            if kv.get("red", "0") != "0":
                state_reason = "検査が赤のまま（red=%s）" % kv["red"]
            else:
                # 緑だが、その後に検査・役割定義が変わっていないか
                import subprocess
                since = int(kv.get("epoch", "0"))
                dirs = [os.path.join(_ROOT, d) for d in _WATCH if os.path.isdir(os.path.join(_ROOT, d))]
                out = ""
                if dirs:
                    out = subprocess.run(
                        ["find"] + dirs + ["-type", "f", "-newermt", "@%d" % since],
                        capture_output=True, text=True, timeout=5).stdout.strip()
                # 他セッションの作業ツリーの写しや __pycache__ は「自分の変更」ではないので数えない
                _NOISE = ("/state/", "/worktrees/", "__pycache__", "/.git/", "/node_modules/")
                n = len([x for x in out.split("\n")
                         if x and not any(z in x for z in _NOISE)])
                if n > 0:
                    state_reason = "全緑判定のあとに検査・役割定義が %d 件変わっている" % n
    except Exception as e:
        note("skip", "state check error: %s" % e, sid)

    # ── 成果物の検証 ──
    #   逃げ道を必ず1つ刻む：最終メッセージに **`skip verify（理由）`** と書けば通す。
    #   理由が記録に残るので、**フックが摩耗して黙って外されることを防ぐ**。逃げ道の無い門は、いずれ「うるさいから」で消される。
    #   逃げ道は **状態由来の差し戻し全体**に効かせる（state_reason も artifact_reason も）。
    #   ⚠ 言語由来の差し戻し（次アクションの宣言＝hits）には効かせない。「やります」と言って止まるのは、検証の有無と関係なく差し戻す。
    artifact_reason = ""
    skip_declared = bool(re.search(r"skip\s*verify", text, re.I))
    if skip_declared:
        state_reason = ""
    if not skip_declared:
        try:
            if not os.path.exists(RESULT):
                artifact_reason = "検証の結果ファイルが無い（verify.sh を一度も通していない）"
            else:
                # ⚠ 鮮度は **結果ファイルの mtime** で見る。`epoch=` の値では見ない。
                #   epoch は state_reason が使っている値で、同じ値を2つの判定に使うと
                #   **片方を壊してももう片方が鳴って気づけない。** 判定ごとに独立した信号を持つ。
                age = int(time.time()) - int(os.path.getmtime(RESULT))
                # 12時間より古い緑は「いまの成果物についての緑」ではない。
                if age > 12 * 3600:
                    artifact_reason = "直近の全緑判定が %.1f 時間前（いまの成果物を検証していない）" % (age / 3600.0)
        except Exception as e:
            note("skip", "artifact check error: %s" % e, sid)

    if not hits and not state_reason and not artifact_reason:
        note("pass", "src=%s %s" % (src, "".join(sentences[-2:])[-100:]), sid)
        return 0

    if not hits and not state_reason and artifact_reason:
        note("block-artifact", artifact_reason, sid)
        sys.stdout.write(json.dumps({"decision": "block", "reason": (
            "【ハーネス】成果物が検証されていない: %s\n"
            "完了の定義は『検査が全緑』だけである（README §検査の3値）。\n"
            "**いま `bash verify.sh` を回すこと。**\n"
            "回せない／回す必要がないなら、最終メッセージに `skip verify（理由）` と書けば通る。\n"
            "**理由は記録に残る。** 逃げ道を隠さないのは、この門が摩耗して外されないためである。\n"
            "この検査は二度は鳴らない。"
        ) % artifact_reason}, ensure_ascii=False) + "\n")
        return 0

    if not hits and state_reason:
        note("block-state", state_reason, sid)
        sys.stdout.write(json.dumps({"decision": "block", "reason": (
            "【ハーネス】未完了の状態が残ったまま終わろうとしている: %s\n"
            "完了の定義は『検査が全緑』だけである（README §検査の3値）。\n"
            "**いま `bash verify.sh` を回して緑にするか、"
            "赤のまま止まる理由（人間ゲート待ち等）を `skip verify（理由）` の形で明記せよ。**\n"
            "この検査は二度は鳴らない。"
        ) % state_reason}, ensure_ascii=False) + "\n")
        return 0

    reason = (
        "【ハーネス】最終メッセージが次アクションを宣言して終わっている: 「%s」\n"
        "宣言しただけで実行していないなら、**いま実行せよ**"
        "（サブエージェントの起動・コマンドの実行など）。\n"
        "すでに実行済み、または他者の応答やバックグラウンドの完了を待っている状態なら、"
        "そう一言明記して再度停止してよい（この検査は二度は鳴らない）。\n"
        "**文言を検査に合わせて変えるな。** 誤検知が続くなら hooks/unfinished_vocab.txt を疑え。"
    ) % hits[-1][:160]

    note("block", hits[-1][:200], sid)
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason},
                                ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
