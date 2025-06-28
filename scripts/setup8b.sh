#!/usr/bin/env bash
set -e

# 1. 新クラスタ作成
eksctl create cluster -f cluster8b.yaml

# 2. CoreDNS を GPU ノードで許可
kubectl -n kube-system patch deployment coredns --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}}]'

# 3. GPUノードに分かりやすいラベルを付与
GPU_NODE=$(kubectl get nodes -l accelerator=nvidia -o jsonpath='{.items[0].metadata.name}')
kubectl label node "${GPU_NODE}" accelerator=nvidia-gpu --overwrite

# 4. 8Bモデルをデプロイ
kubectl apply -f qwen3-8b-vllm.yaml

echo "8Bクラスタ作成を開始しました（~15分かかります）。"
echo "状況確認: kubectl -n qwen8b get pods"
