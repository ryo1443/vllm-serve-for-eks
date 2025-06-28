#!/usr/bin/env bash
set -e

# 1. Create EKS cluster and node groups
eksctl create cluster -f cluster.yaml

# 2. Allow CoreDNS to run on GPU-tainted node
kubectl -n kube-system patch deployment coredns --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}}]'

# 3. Add friendly label to GPU node (first GPU node found)
GPU_NODE=$(kubectl get nodes -l accelerator=nvidia -o jsonpath='{.items[0].metadata.name}')
kubectl label node "${GPU_NODE}" accelerator=nvidia-gpu --overwrite

# 4. Deploy vLLM + Qwen3
kubectl apply -f qwen3-vllm.yaml

echo "Cluster creation kicked off. It may take ~15 minutes to be fully ready."
echo "Check pod status with: kubectl -n qwen get pods"