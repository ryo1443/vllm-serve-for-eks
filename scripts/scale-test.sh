set -euo pipefail

# ---------- 必要コマンド --------------------------------------------------- #
for c in gdate jq parallel eksctl kubectl curl; do
  command -v "$c" >/dev/null || { echo "❌ '$c' が必要です"; exit 1; }
done
parallel --citation <<<'yes' >/dev/null 2>&1 || true      # citation 永久承諾

# ---------- 共通設定 ------------------------------------------------------- #
OUTDIR="$HOME/Downloads/qwen3_eks_setup"; mkdir -p "$OUTDIR"
CLUSTER="qwen3-cluster"; NG="gpu-ng"
ELB="http://a66ebcb3861ff423cb98e777fd86d73d-1845622538.ap-northeast-1.elb.amazonaws.com:8000"
MODEL=$(curl -s "${ELB}/v1/models" | jq -r '.data[0].id'); echo "MODEL = $MODEL"
SUMMARY="$OUTDIR/summary.csv"; echo 'pod_num,scale_sec,infer_sec' > "$SUMMARY"

now_ms(){ gdate +%s%N | cut -c1-13; }          # 13 桁ミリ秒
REQUESTS=300                                    # ★ 総リクエスト数を 300 に

# ---------- スケール & ロールアウト --------------------------------------- #
scale_nodes(){
  local tgt=$1 start=$(now_ms)
  eksctl scale nodegroup --cluster "$CLUSTER" --name "$NG" --nodes "$tgt" --nodes-max "$tgt" >/dev/null
  printf "▶ GPU ノード %d 台へスケール..." "$tgt"
  while true; do
    kubectl get nodes --no-headers | awk '{print $1}' | \
      xargs -I{} kubectl label node {} accelerator=nvidia-gpu --overwrite >/dev/null 2>&1 || true
    ready=$(kubectl get nodes -l accelerator=nvidia-gpu --no-headers | wc -l)
    printf "\r[%s] Ready %d/%d" "$(gdate +%T)" "$ready" "$tgt"
    [[ $ready -eq $tgt ]] && break; sleep 8
  done; echo " ✓"
  SCALE_SEC=$(( ( $(now_ms) - start ) / 1000 ))
}
wait_rollout(){
  local ns=$1 dpl=$2 tgt=$3
  printf "▶ Pod ロールアウト待ち..."
  while true; do
    r=$(kubectl -n "$ns" get deploy "$dpl" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    r=${r:-0}; printf "\r[%s] Running %d/%d" "$(gdate +%T)" "$r" "$tgt"
    [[ $r -eq $tgt ]] && break; sleep 4
  done; echo " ✓"
}

# ---------- 並列リクエスト ワーカー --------------------------------------- #
single_req(){                 # id (1..REQUESTS)
  local num=$((1000+RANDOM%9000))
  local q="/no_think 次の整数の素因数分解をしてください: $num"
  local retries=0 ans code json ms
  while true; do
    local body=$(jq -nc --arg m "$MODEL" --arg q "$q" '{model:$m,messages:[{role:"user",content:$q}]}')
    local t0=$(now_ms)
    local resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
                      -d "$body" "${ELB}/v1/chat/completions" || echo -e '\n000')
    code=${resp##*$'\n'}; json=${resp%$'\n'*}
    ms=$(( $(now_ms) - t0 ))
    if [[ $code == 200 ]]; then
      ans=$(echo "$json" | jq -r '.choices[0].message.content // .choices[0].text' | tr -d '\n'); break
    fi
    ((retries++))
    [[ $retries -ge 3 ]] && { ans="[ERR:$code]"; break; }
    sleep 1
  done
  printf '"%s","%s","%s","%s","NA"\n' "$num" "$q" "$ans" "$ms"
}

parallel_infer(){             # csv → infer_sec
  local csv=$1
  echo 'num,question,answer,time_ms,pod_name' > "$csv"
  export MODEL ELB; export -f single_req now_ms
  local start=$(now_ms)
  parallel --will-cite -j30 single_req ::: $(seq 1 $REQUESTS) >> "$csv"
  echo "$(( ( $(now_ms) - start ) / 1000 ))"
}

# ---------- ベンチ -------------------------------------------------------- #
bench(){                      # $1 = Pod 台数
  local rep=$1; echo -e "\n=========== Pod 数 ${rep} =========="
  scale_nodes "$rep"
  kubectl -n qwen scale deploy/qwen3-awq-vllm --replicas=$rep
  wait_rollout qwen qwen3-awq-vllm "$rep"

  local csv="$OUTDIR/bench_pod${rep}.csv"
  echo "▶ ${REQUESTS} リクエスト同時推論中..."; infer_sec=$(parallel_infer "$csv")
  echo "   推論完了秒 = ${infer_sec}s  → CSV: $csv"

  echo "$rep,$SCALE_SEC,$infer_sec" >> "$SUMMARY"
}

bench 1
bench 2
bench 5

echo -e "\n==== 実行時間まとめ ===="; cat "$SUMMARY"