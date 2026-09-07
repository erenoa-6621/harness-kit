#!/usr/bin/env bash
# loop_guard.sh — ループの停止スイッチ。**状態ファイル1枚**で回る／止まるを決める。
#
# 型の由来: ファイルを消せばループが死ぬ、という fail-safe の形。
#   機械に作業を委ねるときの条件は2つ ── ①検査が緑 ②**人間が即時停止できる経路**。
#   `rm` 一発で止められる経路は、条件②を最も安く満たす。
#
# 使い方（ループを回す側のスクリプトが、各周回の先頭で呼ぶ）:
#   bash tools/loop_guard.sh <ループ名>  || exit 0     # 続けてよければ 0、止めるべきなら 1
#   bash tools/loop_guard.sh <ループ名> --arm          # 開始（状態ファイルを作る）
#   bash tools/loop_guard.sh <ループ名> --fail         # 1周が失敗した（連続失敗を数える）
#   bash tools/loop_guard.sh <ループ名> --ok           # 1周が成功した（連続失敗をリセット）
#   bash tools/loop_guard.sh <ループ名> --stop         # 止める（＝状態ファイルを消す）
#
# **人が止める方法（これが本題）:**
#   rm <LOOP_STATE_DIR>/<ループ名>.run
#   これだけ。次の周回で必ず止まる。理由の説明も連絡も要らない。
#
# 状態ファイルの置き場は harness.conf の LOOP_STATE_DIR（既定 state/loops。キット直下からの相対か絶対パス）。
#
# 連続失敗の上限（既定3・環境変数 LOOP_MAX_FAILS で変更）:
#   3回続けて失敗したら、それは実装の問題ではなく計画の欠陥である。自動で止める。
#
# 【保証すること・しないこと】
#   保証する : 状態ファイルが無ければ、次の周回で必ず止まること
#   保証しない: **実行中の1周を途中で止めること。** 周回の境界でしか効かない。
set -uo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${HARNESS_CONF:-$KIT_ROOT/harness.conf}"
LOOP_STATE_DIR="state/loops"
[ -f "$CONF" ] && . "$CONF"
case "$LOOP_STATE_DIR" in /*) DIR="$LOOP_STATE_DIR" ;; *) DIR="$KIT_ROOT/$LOOP_STATE_DIR" ;; esac
NAME="${1:-}"
MODE="${2:-check}"
MAX_FAILS="${LOOP_MAX_FAILS:-3}"

[ -n "$NAME" ] || { echo "使い方: loop_guard.sh <ループ名> [--arm|--fail|--ok|--stop]" >&2; exit 2; }
case "$NAME" in */*|..*) echo "ループ名にパス区切りは使えない: $NAME" >&2; exit 2 ;; esac
mkdir -p "$DIR" 2>/dev/null
F="$DIR/$NAME.run"

case "$MODE" in
  --arm)
    printf 'started=%s\nfails=0\n' "$(date -Iseconds)" > "$F"
    echo "🟢 ループ '$NAME' を開始した。**止めるには次の1行:**"
    echo "   rm $F"
    exit 0 ;;
  --stop)
    rm -f "$F"
    echo "🛑 ループ '$NAME' を止めた（状態ファイルを消した）。次の周回で停止する。"
    exit 0 ;;
  --fail)
    [ -f "$F" ] || { echo "🛑 ループ '$NAME' は既に止まっている"; exit 1; }
    n=$(sed -n 's/^fails=//p' "$F" | head -1); n=${n:-0}
    n=$((n+1))
    sed -i "s/^fails=.*/fails=$n/" "$F" 2>/dev/null || printf 'fails=%s\n' "$n" >> "$F"
    if [ "$n" -ge "$MAX_FAILS" ]; then
      rm -f "$F"
      echo "🛑 連続失敗が ${n} 回に達したので止めた（上限 ${MAX_FAILS}）。"
      echo "   **収束しないのは実装の問題ではなく、計画の欠陥である。**"
      echo "   終了条件・証明方法・題材のどれかを疑うこと。"
      exit 1
    fi
    echo "⚠ 連続失敗 ${n}/${MAX_FAILS}"
    exit 0 ;;
  --ok)
    [ -f "$F" ] || { echo "🛑 ループ '$NAME' は既に止まっている"; exit 1; }
    sed -i "s/^fails=.*/fails=0/" "$F" 2>/dev/null
    exit 0 ;;
  check|"")
    if [ -f "$F" ]; then exit 0; fi
    echo "🛑 ループ '$NAME' は止まっている（$F が無い）。周回を始めない。"
    exit 1 ;;
  *)
    echo "不明なモード: $MODE" >&2; exit 2 ;;
esac
