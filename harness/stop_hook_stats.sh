#!/usr/bin/env bash
# stop_hook_stats.sh — Stop フック（hooks/unfinished_action.py）の発火統計。**撤退条件を測るための道具。**
#
# 型の由来: 「発火10回のうち誤検知が7回以上なら外す」と書いてあっても、
#   ログが pass/block しか持たず、本番の発火数すら数えられなければ、その撤退条件は存在しないのと同じ。
#   **撤退条件は、測る機構とセットにしないと存在しない。**
#
# 【この道具が保証すること・しないこと】
#   保証する : 本番(real)の発火数・block 数を数え、閾値に達したら知らせる。
#              本番で一度も呼ばれていないことを検知する。
#   保証しない: **誤検知かどうかは機械では判定できない。** 人がログを読んで判定する。
#              よって撤退条件は「自動で外す」ではなく「**閾値に達したら人に判定を求める**」。
#              **自動判定できないものを、自動判定するふりをしない。**
#
# 使い方: bash harness/stop_hook_stats.sh [ログのパス]
#   ログの既定は <キット>/<STATE_DIR>/unfinished_action.log（STATE_DIR は harness.conf）。
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${HARNESS_CONF:-$KIT_ROOT/harness.conf}"
STATE_DIR="state"
[ -f "$CONF" ] && . "$CONF"
LOG="${1:-$KIT_ROOT/$STATE_DIR/unfinished_action.log}"
THRESHOLD="${STOP_HOOK_REVIEW_AT:-10}"

if [ ! -f "$LOG" ]; then
  echo "ログが無い: $LOG （一度も呼ばれていない）"
  exit 0
fi

real_fired=$(awk -F'\t' '$2=="real" && $4=="fired"{n++} END{print n+0}' "$LOG")
real_block=$(awk -F'\t' '$2=="real" && ($4=="block"||$4=="block-state"||$4=="block-artifact"){n++} END{print n+0}' "$LOG")
real_pass=$(awk -F'\t'  '$2=="real" && $4=="pass"{n++} END{print n+0}' "$LOG")
real_skip=$(awk -F'\t'  '$2=="real" && $4=="skip"{n++} END{print n+0}' "$LOG")
test_n=$(awk -F'\t'     '$2=="test"{n++} END{print n+0}' "$LOG")
manual_n=$(awk -F'\t'   '$2=="manual"{n++} END{print n+0}' "$LOG")
sessions=$(awk -F'\t'   '$2=="real"{print $3}' "$LOG" | sort -u | grep -c . || true)
old_fmt=$(awk -F'\t' 'NF<5{n++} END{print n+0}' "$LOG")

echo "===== Stop フック発火統計 ====="
echo "  本番(real): 呼ばれた ${real_fired} / block ${real_block} / pass ${real_pass} / skip ${real_skip}"
echo "  テスト(test): ${test_n}   手動(manual): ${manual_n}   セッション数: ${sessions:-0}   旧形式(判定不能): ${old_fmt}"
echo "  ※ real は Claude Code が実際に Stop で呼んだもの（入力に prompt_id がある）。"
echo "     manual は人が手で叩いたもの。**環境変数ではなく入力の形で見分ける**（付け忘れで嘘になるため）。"

if [ "$real_fired" -eq 0 ]; then
  echo
  echo "  🚨 **本番で一度も呼ばれていない。**"
  echo "     「配線した」と「そのセッションで発火する」は別である。"
  echo "     フックを足したセッションでは効かないことがある。**新しいセッションで確かめること。**"
  exit 0
fi

if [ "$real_block" -ge "$THRESHOLD" ]; then
  echo
  echo "  ⚠ block が ${real_block} 回に達した（閾値 ${THRESHOLD}）。**撤退条件の判定時期である。**"
  echo "     ログの block 行を読み、そのうち誤検知（実際には待機中だった）が何回かを人が数えること。"
  echo "     7割以上が誤検知なら、フックの撤退条件どおり外す。"
  echo "     ── 直近の block 行 ──"
  awk -F'\t' '($4=="block"||$4=="block-state"||$4=="block-artifact"){print "     " $1 "  " $4 "  " substr($5,1,70)}' "$LOG" | tail -5
fi
exit 0
