#!/usr/bin/env bash
# ----------  measure_max_concurrency.sh  (mac bash 3.2 OK) -----------
set -euo pipefail
PARALLEL_CITATION_NOTICE=0

#--- bash4 があれば切替 -------------------------------------------------
if [[ ${BASH_VERSINFO[0]} -lt 4 && -x /opt/homebrew/bin/bash ]]; then
  exec /opt/homebrew/bin/bash "$0" "$@"
fi

#--- 必須コマンド -------------------------------------------------------
for c in gdate jq parallel curl; do
  command -v "$c" >/dev/null || { echo "❌ $c が必要"; exit 1; }
done
parallel --citation <<< yes >/dev/null 2>&1 || true

#--- 定数 ---------------------------------------------------------------
BASE="$HOME/Downloads/qwen3_eks_setup"
PROMPT_DIR="$BASE/prompts"          # prompt1.txt …
OUTDIR="$BASE/results"; mkdir -p "$OUTDIR"

ELB="http://a66ebcb3861ff423cb98e777fd86d73d-1845622538.ap-northeast-1.elb.amazonaws.com:8000"
MODEL=$(curl -s "$ELB/v1/models" | jq -r '.data[0].id')
echo "MODEL = $MODEL"

TARGETS=(0.5 1 1.5 2 5 10)          # 秒
REQ=30                              # 生成する質問数(≒上限並列数)

SUMMARY="$OUTDIR/concurrency_result_custom.csv"
echo 'prompt_id,latency_s,max_concurrency' >"$SUMMARY"

now_ms(){ gdate +%s%N | cut -c1-13; }

#--- 30 個の質問 --------------------------------------------------------
gen_questions(){
  for i in $(seq 1 "$REQ"); do
    case $((i%3)) in
      0) echo "最近、人間関係で悩んでいます。どうしたら良いでしょう？ID=$i" ;;
      1) echo "仕事のストレスが強いです。アドバイスをいただけますか？ID=$i" ;;
      2) echo "将来への不安が大きいです。聞いてください。ID=$i"          ;;
    esac
  done
}

#--- 1 リクエスト --------------------------------------------------------
single_req(){                       # $1=question
  local q=$1 prompt body
  prompt=$(<"$PROMPT_FILE")
  body=$(jq -nc --arg p "$prompt" --arg q "$q" \
         '{model:env.MODEL,messages:[{role:"system",content:$p},{role:"user",content:$q}]}')

  local s=$(now_ms)
  # 30 秒で curl を打ち切る
  local resp
  resp=$(curl --max-time 30 -s -X POST -H 'Content-Type: application/json' \
              -d "$body" "$ELB/v1/chat/completions")
  local ms=$(( $(now_ms)-s ))
  local ans
  ans=$(echo "$resp" | jq -r '.choices[0].message.content // empty' | tr -d '\n')

  printf '"%s","%s","%s"\n' "$q" "$ans" "$ms"
}
export -f single_req now_ms          # parallel へ
export MODEL ELB                     #   〃

#--- 最大並列探索 (二分探索) -------------------------------------------
find_max_conc(){                     # $1=promptFile  $2=targetSec
  local pf=$1 tgt_ms; tgt_ms=$(awk "BEGIN{print $2*1000}")

  readarray -t QS < <(gen_questions)

  local lo=1 hi=$REQ best=0 mid        # ★ 上限を 30 (=REQ)
  while (( lo<=hi )); do
    mid=$(( (lo+hi)/2 ))
    printf "  ↪ concurrency=%d ... " "$mid"

    PROMPT_FILE=$pf \
    parallel --env single_req --env MODEL --env ELB --env PROMPT_FILE --env now_ms \
             -j"$mid" single_req ::: "${QS[@]:0:$mid}" >"$OUTDIR/tmp.csv"

    local max_ms
    max_ms=$(awk -F',' 'NR>1{gsub(/"/,"",$3); if($3>m)m=$3}END{print m+0}' "$OUTDIR/tmp.csv")
    echo "${max_ms}ms"

    if (( max_ms<=tgt_ms )); then best=$mid; lo=$((mid+1)); else hi=$((mid-1)); fi
  done
  rm -f "$OUTDIR/tmp.csv"; echo "$best"
}

#--- 実行 ---------------------------------------------------------------
for pf in "$PROMPT_DIR"/prompt*.txt; do
  [[ -s $pf ]] || { echo "❌ $pf が見つからない/空です"; exit 1; }
done

for pf in "$PROMPT_DIR"/prompt*.txt; do
  pid=$(basename "$pf" | grep -o '[0-9]\+')
  echo -e "\n==== Prompt${pid} ================================="
  for tgt in "${TARGETS[@]}"; do
    echo "▶ target ${tgt}s"
    maxc=$(find_max_conc "$pf" "$tgt")
    echo "  → 最大並列 = $maxc"
    echo "$pid,$tgt,$maxc" >>"$SUMMARY"
  done
done

echo -e "\n★ 集計結果 ($SUMMARY)"
column -s, -t "$SUMMARY"
# ----------------------------------------------------------------------
