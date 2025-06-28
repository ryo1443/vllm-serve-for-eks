#!/usr/bin/env bash
set -euo pipefail

# ---------- 必要コマンド --------------------------------------------------- #
for c in gdate eksctl kubectl; do
  command -v "$c" >/dev/null || { echo "❌ '$c' が必要です"; exit 1; }
done

# ---------- 引数確認 ------------------------------------------------------- #
if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <GPUノード台数> <EKSクラスター名> <NodeGroup名> <デプロイの名前空間> <デプロイ名>"
  exit 1
fi
TARGET_NODES=$1
CLUSTER=$2
NG=$3
DEPLOY_NS=$4
DEPLOY_NAME=$5

[[ $TARGET_NODES =~ ^[0-9]+$ ]] || { echo "❌ 台数は数値で指定してください"; exit 1; }

now_ms(){ gdate +%s%N | cut -c1-13; } # 13 桁ミリ秒

# ---------- ノードスケール ------------------------------------------------- #
scale_nodes(){
  local tgt=$1 start=$(now_ms)
  eksctl scale nodegroup --cluster "$CLUSTER" --name "$NG" \
    --nodes "$tgt" --nodes-max "$tgt" >/dev/null
  printf "▶ GPUノードを %d 台へスケール中...\n" "$tgt"
  while true; do
    # ラベルを確実に付与
    kubectl get nodes --no-headers | awk '{print $1}' | \
      xargs -I{} kubectl label node {} accelerator=nvidia-gpu --overwrite >/dev/null 2>&1 || true
    ready=$(kubectl get nodes -l accelerator=nvidia-gpu --no-headers | wc -l | tr -d ' ')
    printf "\r[%s] Ready %d/%d" "$(gdate +%T)" "$ready" "$tgt"
    [[ $ready -eq $tgt ]] && break
    sleep 8
  done
  echo " ✓"
  echo "   ノード準備完了まで $(( ( $(now_ms) - start ) / 1000 )) 秒"
}

# ---------- デプロイスケール ---------------------------------------------- #
scale_deploy(){
  local tgt=$1
  kubectl -n "$DEPLOY_NS" scale deploy/"$DEPLOY_NAME" --replicas=$tgt
  printf "▶ Podロールアウト待機中...\n"
  while true; do
    ready=$(kubectl -n "$DEPLOY_NS" get deploy "$DEPLOY_NAME" \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    ready=${ready:-0}
    printf "\r[%s] Running %d/%d" "$(gdate +%T)" "$ready" "$tgt"
    [[ $ready -eq $tgt ]] && break
    sleep 4
  done
  echo " ✓"
}

# ---------- メイン --------------------------------------------------------- #
scale_nodes   "$TARGET_NODES"
scale_deploy  "$TARGET_NODES"
echo "🎉 スケール完了しました"