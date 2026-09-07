#!/usr/bin/env bash
# gate_check.sh — その操作が「人間ゲート」に当たるかを機械で判定する。
#
# なぜ機械に落とすのか:
#   「これは人間ゲートか」を都度考えるなら、**結局そこで止まる。** 考えること自体が摩擦である。
#   **迷わないために機械に聞く。** 迷いを消すのが目的であって、責任を機械に移すのではない。
#
# 使い方:
#   bash tools/gate_check.sh "git push origin main"               # → exit 0（裁量）
#   bash tools/gate_check.sh "gh pr edit 19 --add-label publish"  # → exit 1（人間ゲート）
#   bash tools/gate_check.sh --list                               # 判定基準を表示
#
# 終了コード:
#   0 = 裁量で進んでよい
#   1 = 人間ゲート（人の確認が要る）
#   2 = 判定できない（**その場合も人間ゲート扱い**。分からないものを勝手に進めない）
#
# 語彙は tools/gate_vocab.conf に外出ししてある（bash が source する）。考え方は README §人間ゲート。
#
# 【この判定が保証すること・しないこと】
#   保証する : 既知の「外に出る操作」の型を、迷いなく人間ゲート側に分類する
#   保証しない: **網羅性。** 未知の外向き操作は素通りしうる。これは denylist であり境界ではない。
#              **「gate_check が 0 を返したから安全」とは言わない。**
#              疑わしいと感じたら、機械が 0 を返しても止まってよい。判断は人が持つ。
#
# 【配線（ワークフロー）の分類】
#   配線（ワークフロー・cron・CI・公開の時間窓・承認の受け取り方）を**変える**のは裁量。
#   公開・デプロイの配線を**押す**（発火させる）のは公開そのもの＝人間ゲート。
#   裁量の2条件（①検査が緑 ②即時停止できる経路）はそのまま掛かる。配線の裁量を返すときは
#   **その2条件を必ず出力に出す。** 条件を黙って落とすと許可だけが残る。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOCAB="${GATE_VOCAB:-$HERE/gate_vocab.conf}"

# ---- ロケールの固定 ----
# **多バイト文字を含む否定文字クラス `[^。]` は、UTF-8 ロケールが無いと壊れる。**
#   `サ`(E3 82 B5) と `。`(E3 80 82) はバイトを共有するため、バイト単位の `[^。]*` が跨げない。
#   cron も CI も LANG を持たない。素の環境で「本番サーバへ反映する」が裁量(0)に化けた実測がある。
# 判定に使う道具がロケールで挙動を変えるなら、**判定できない**。黙って裁量側に倒さない。
for _loc in "${LC_ALL:-}" C.UTF-8 C.utf8 en_US.UTF-8 ja_JP.UTF-8; do
  [ -n "$_loc" ] || continue
  if printf 'あ' | LC_ALL="$_loc" wc -m 2>/dev/null | grep -q '^ *1$'; then export LC_ALL="$_loc"; break; fi
done
if ! printf 'あ' | wc -m 2>/dev/null | grep -q '^ *1$'; then
  echo "🟡 判定できない: UTF-8 ロケールが無く、日本語の判定が壊れる（LC_ALL=${LC_ALL:-未設定}）"
  echo "   → 人間ゲート扱いにする。分からないものを勝手に進めない。"
  exit 2
fi

# ---- 語彙の読み込み（無ければ判定できない） ----
if [ ! -f "$VOCAB" ]; then
  echo "🟡 判定できない: 語彙ファイルが無い: $VOCAB"
  echo "   → 人間ゲート扱いにする。"
  exit 2
fi
. "$VOCAB"
for v in GATE_LABEL_RE GATE_DEPLOY_RE GATE_PUBLISH_RE GATE_VISIBILITY_RE GATE_SEND_RE GATE_SNS_RE GATE_DELIVER_RE \
         GATE_BILLING_RE GATE_DESTROY_RE GATE_RMR_RE GATE_TMP_RE GATE_WIRING_RE GATE_PUBWORD_RE GATE_CHANGE_RE \
         GATE_FIRE_RE GATE_MACHINE_RE GATE_PUBLISHED_RE GATE_VISCHANGE_RE GATE_UNKNOWN_RE; do
  if [ -z "${!v:-}" ]; then
    echo "🟡 判定できない: 語彙 $v が空か未定義（$VOCAB）"
    echo "   → 人間ゲート扱いにする。"
    exit 2
  fi
done

WHAT="${1:-}"

if [ "$WHAT" = "--list" ] || [ -z "$WHAT" ]; then
  cat <<'LIST'
===== 人間ゲート判定の基準（README §人間ゲート） =====

【人間ゲート（人の確認が要る）】＝ 外部または人の目に触れる瞬間
  - 対外送信      … 応募・提案・メール・クライアントへの連絡・issue コメント
  - 公開          … publish ラベル、記事の公開、リポジトリの可視性変更
  - 納品          … 成果物の引き渡し
  - 課金          … 決済・サブスクリプション・プラン変更
  - 本番デプロイ  … ホスティングへの deploy、本番サーバへの反映
  - 不可逆な削除  … 資産の削除、履歴の書き換え、force push、トークンの失効
  - SNS 投稿      … 外部アカウントからの発信
  - 公開の配線を「押す」… gh workflow run / workflow_dispatch などで公開・デプロイの経路を
                    **発火させる**こと。配線を*変える*のは裁量だが、*押す*のは公開そのもの

【裁量（進んでよい）】＝ この機械の中で完結し、外にも人の目にも触れない
  - リポジトリ内のファイル生成・修正・削除（作業物）
  - テストの実行、検査の実行
  - private リポジトリへの commit / push / PR 作成
  - 検証が緑であることを確認したうえでの PR マージ
  - 配線（ワークフロー・cron・CI・公開の時間窓・承認の受け取り方）の変更
  - cron などマシン設定の変更（**バックアップと戻し方を残すこと**）
  - CI・検査のワークフロー（走らせる検査を増やす・テストを足す）
  - 公開済み資産の内容更新（誤字・リンク切れ・README のプレースホルダ等。可視性の変更は除く）
  - 運用ルールの制定・改訂（ただし自分の権限範囲の拡大を除く）
  - サブエージェントの起動、調査、設計

【裁量に付く条件（欠けたら裁量に含まれない）】
  ① 検査が緑であること
  ② hold ラベル等で人間が即時停止できる経路を残すこと

【判定できないとき】
  **人間ゲート扱いにする。** 分からないものを勝手に進めない。
  受け皿に残るのは「公開/納品/外部/対外」を含みながら型に当たらないものだけ。
LIST
  exit 0
fi

verdict() { echo "🔴 人間ゲート: $1"; echo "   → 人の確認が要る。作業は進めてよいが、その一手は打たない。"; exit 1; }
conditions() {
  echo "   ⚠ 裁量には2条件が掛かる。欠けたら裁量に含まれない:"
  echo "     ① 検査が緑であること"
  echo "     ② hold ラベル等で人間が即時停止できる経路を残すこと"
}

low=$(printf '%s' "$WHAT" | tr 'A-Z' 'a-z')
# 引用符を落としてから判定する。`--add-label "publish"` のように飾りを1つ足すだけで判定を外れていた実測がある。
low_nq=$(printf '%s' "$low" | tr -d '\042\047')

# ── 外部公開・送信 ──
printf '%s' "$low_nq" | grep -Eq "$GATE_LABEL_RE"      && verdict "publish ラベル＝新規の対外公開"
printf '%s' "$low_nq" | grep -Eq "$GATE_DEPLOY_RE"     && verdict "本番デプロイ"
printf '%s' "$low_nq" | grep -Eq "$GATE_PUBLISH_RE"    && verdict "記事・成果物の公開＝新規の対外公開"
printf '%s' "$low"    | grep -Eq "$GATE_VISIBILITY_RE" && verdict "リポジトリの可視性変更＝新規の対外公開"
printf '%s' "$low"    | grep -Eq "$GATE_SEND_RE"       && verdict "対外送信"
printf '%s' "$low"    | grep -Eq "$GATE_SNS_RE"        && verdict "外部アカウントからの発信"
printf '%s' "$low"    | grep -Eq "$GATE_DELIVER_RE"    && verdict "納品＝新規の対外公開"

# ── 課金 ──
printf '%s' "$low" | grep -Eq "$GATE_BILLING_RE" && verdict "課金"

# ── 不可逆な削除・履歴の書き換え ──
printf '%s' "$low" | grep -Eq "$GATE_DESTROY_RE" && verdict "不可逆な削除・履歴の書き換え・資格情報の失効"
# rm -rf は一時領域なら裁量、それ以外は人間ゲート
if printf '%s' "$low" | grep -Eq "$GATE_RMR_RE"; then
  printf '%s' "$low" | grep -Eq "$GATE_TMP_RE" || verdict "一時領域の外での再帰削除"
fi

# ── 配線（ワークフロー）── 「変える」は裁量、「押す」は人間ゲート
#   公開・デプロイの語を含むなら既定は人間ゲート側。**「変更」と明示的に読めるときだけ裁量へ落とす。**
#   日本語の言い換えは尽きないので、列挙するのは「変更」の側にする。間違えたときの被害が非対称だからである
#   （変更を止める＝遅いだけ／押すのを通す＝取り返しがつかない）。
is_wiring=0
printf '%s' "$low" | grep -Eq "$GATE_WIRING_RE" && is_wiring=1

if [ "$is_wiring" = "1" ]; then
  has_pub=0; has_chg=0; has_fire=0
  printf '%s' "$low" | grep -Eq "$GATE_PUBWORD_RE" && has_pub=1
  printf '%s' "$low" | grep -Eq "$GATE_CHANGE_RE"  && has_chg=1
  printf '%s' "$low" | grep -Eq "$GATE_FIRE_RE"    && has_fire=1

  if [ "$has_fire" = "1" ] && [ "$has_pub" = "1" ]; then
    verdict "公開・デプロイの配線を**発火させる**＝公開を押す行為。配線の*変更*は裁量だが、*押す*のは人間ゲート（README §人間ゲート）"
  fi
  if [ "$has_pub" = "1" ] && [ "$has_chg" = "0" ]; then
    echo "🟡 判定できない: 公開・デプロイに関わる配線だが、「変更」と読める語が無い"
    echo "   → **人間ゲート扱いにする。** 配線を*変える*なら「〜を変更する」と書き直して聞き直すこと。"
    exit 2
  fi
  echo "🟢 裁量: 配線（ワークフロー・cron・CI・公開の時間窓・承認の受け取り方）の変更"
  echo "   根拠: README §人間ゲート（配線を変えるのは裁量。公開を押すのは人間ゲート）"
  conditions
  printf '%s' "$low" | grep -Eq "$GATE_MACHINE_RE" \
    && echo "   ⚠ cron・マシン設定は追加条件つき: **バックアップと戻し方を残すこと**"
  echo "   ⚠ 配線を変えてよいのであって、**公開を押してよいわけではない**。"
  exit 0
fi

# 配線の語が無くても、発火＋公開の組み合わせは押す行為である（gh workflow run release.yml など）。
if printf '%s' "$low" | grep -Eq "$GATE_FIRE_RE" && printf '%s' "$low" | grep -Eq "$GATE_PUBWORD_RE"; then
  verdict "公開・デプロイを発火させる＝公開を押す行為（README §人間ゲート）"
fi

# ── 公開済み資産の「内容更新」＝裁量 ──
#   境界（ここを間違えると新規公開が裁量に化ける）:
#     ・**既に公開されている**もの（公開済みリポジトリ・記事・稼働中のサイト）の**内容**を直す → 裁量
#     ・**まだ公開されていない**ものを世に出す／可視性を上げる → 人間ゲート（上の判定が先に捕まえる）
if printf '%s' "$low" | grep -Eq "$GATE_PUBLISHED_RE"; then
  if printf '%s' "$low" | grep -Eq "$GATE_VISCHANGE_RE"; then
    verdict "可視性そのものの変更（公開/非公開の切り替え）＝内容更新ではない。新規の対外公開に準じて人間ゲート"
  fi
  echo "🟢 裁量: 公開済み資産の内容更新"
  echo "   根拠: README §人間ゲート（新規の対外公開＝人 / 公開済み資産の内容更新＝検査が緑なら機械）"
  conditions
  echo "   ⚠ **既に公開されているものの中身を直してよい**のであって、"
  echo "     **公開されていないものを出してよいわけではない**。"
  exit 0
fi

# ── 判定できない外向きの語が混じっていないか（fail-closed 寄りの安全網）──
printf '%s' "$low" | grep -Eq "$GATE_UNKNOWN_RE" \
  && { echo "🟡 判定できない: 「公開/納品/外部/対外」を含むが、既知の型に当てはまらない"
       echo "   → **人間ゲート扱いにする。分からないものを勝手に進めない。**"
       echo "   ※ 否定形（「公開は押さない」等）にも反応する。行為の動詞だけで言い換えて再度聞くこと。"; exit 2; }

echo "🟢 裁量: 内部の作業と判定した"
echo "   ※ この判定は denylist であって境界ではない。未知の外向き操作は素通りしうる。"
echo "     疑わしいと感じたら、0 が返っても止まってよい。判断は人が持つ。"
exit 0
