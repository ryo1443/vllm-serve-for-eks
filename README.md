# Qwen3-4B-AWQ on EKS (T4) – One‑Click Setup

このリポジトリは **NVIDIA T4×EKS** 上に vLLM で **Qwen3‑4B‑AWQ** をホストする
再現性のある最小構成です。  
初心者でも `eksctl` と `kubectl` だけで同じ環境を何度でも作れます。

## 構成ファイル
| ファイル | 役割 |
|----------|------|
| `cluster.yaml` | EKSクラスタ＋GPUノード＋CPUノード＋NAT を定義 |
| `qwen3-vllm.yaml` | vLLM Deployment と LoadBalancer Service |
| `setup.sh` | コマンド自動化スクリプト |
| `README.md` | この説明書 |

## 使い方（コピペでOK）
```bash
git clone <your-repo>
cd qwen3_eks_setup
bash setup.sh          # 途中で 15 分ほど待ちます
```

完了後、ELB DNS を取得して OpenAI 互換のエンドポイントへリクエストできます。

```bash
ELB=$(kubectl -n qwen get svc qwen3-awq-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$ELB:8000/v1/chat/completions \
   -H 'Content-Type: application/json' \
   -d '{"model":"qwen3","messages":[{"role":"user","content":"こんにちは"}]}'
```

## 自動スケール
* Pod 水平スケール: HPA（例は README 末尾に記載）
* GPU ノード自動増減: Karpenter NodePool 設定例も付属

---
**動いたら ⭐ Star をお願いします！**