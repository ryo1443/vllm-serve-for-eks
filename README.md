# Qwen3-4B-AWQ on EKS (T4) – One‑Click Setup

このリポジトリは **NVIDIA T4×EKS** 上に vLLM で **Qwen3‑4B‑AWQ** をホストする
再現性のある最小構成です。  
初心者でも `eksctl` と `kubectl` だけで同じ環境を何度でも作れます。

## 構成ファイル

| ファイル | 役割 |
|---|
| `kubernetes/cluster.yaml` | EKSクラスタ＋GPUノード＋CPUノード＋NAT を定義 |
| `kubernetes/cluster8b.yaml` | 8Bモデル用のEKSクラスタ設定 |
| `kubernetes/qwen3-vllm.yaml` | 素の4B AWQモデルのvLLM Deployment と LoadBalancer Service |
| `kubernetes/qwen3-4b-custom.yaml` | S3からモデルをダウンロードするカスタム4B AWQモデルのvLLM Deployment と LoadBalancer Service |
| `kubernetes/qwen3-4b-custom-hf.yaml` | Hugging Faceからモデルをダウンロードするカスタム4B AWQモデルのvLLM Deployment と LoadBalancer Service |
| `kubernetes/qwen3-8b-deployment.yaml` | 8BモデルのvLLM Deployment |
| `kubernetes/qwen3-8b-service.yaml` | 8BモデルのLoadBalancer Service |
| `scripts/setup.sh` | 4B AWQモデルのセットアップコマンド自動化スクリプト |
| `scripts/setup8b.sh` | 8B AWQモデルのセットアップコマンド自動化スクリプト |
| `scripts/scale.sh` | スケールテスト用スクリプト |
| `scripts/scale-test.sh` | スケールテスト用スクリプト |
| `scripts/measure_max_concurrency.sh` | 最大同時接続数計測用スクリプト |
| `tests/concurrency_probe.py` | 同時接続数計測Pythonスクリプト |
| `tests/test.py` | テスト用Pythonスクリプト |
| `prompts/` | プロンプトファイル群 |
| `README.md` | この説明書 |

## 使い方（コピペでOK）

### 1. リポジリのクローン

```bash
git clone <your-repo>
cd qwen3_eks_setup
```

### 2. EKSクラスターのセットアップ

#### 4B AWQモデル用クラスター

```bash
bash scripts/setup.sh
```
途中で 15 分ほど待ちます。

#### 8B AWQモデル用クラスター

```bash
bash scripts/setup8b.sh
```
途中で 15 分ほど待ちます。

### 3. モデルのデプロイ

#### 素の4B AWQモデル

`kubernetes/qwen3-vllm.yaml` を適用します。

```bash
kubectl apply -f kubernetes/qwen3-vllm.yaml
```

ELB DNS を取得して OpenAI 互換のエンドポイントへリクエストできます。

```bash
ELB=$(kubectl -n qwen get svc qwen3-awq-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$ELB:8000/v1/chat/completions \
   -H 'Content-Type: application/json' \
   -d '{"model":"qwen3","messages":[{"role":"user","content":"こんにちは"}]}'
```

#### カスタム4B AWQモデル (S3からダウンロード)

`kubernetes/qwen3-4b-custom.yaml` を適用します。

```bash
kubectl apply -f kubernetes/qwen3-4b-custom.yaml
```

ELB DNS を取得して OpenAI 互換のエンドポイントへリクエストできます。

```bash
ELB=$(kubectl -n qwen4b-custom get svc qwen3-4b-custom-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$ELB:8000/v1/chat/completions \
   -H 'Content-Type: application/json' \
   -d '{"model":"qwen3-4b-custom","messages":[{"role":"user","content":"こんにちは"}]}'
```

#### カスタム4B AWQモデル (Hugging Faceからダウンロード)

`kubernetes/qwen3-4b-custom-hf.yaml` を適用します。

```bash
kubectl apply -f kubernetes/qwen3-4b-custom-hf.yaml
```

ELB DNS を取得して OpenAI 互換のエンドポイントへリクエストできます。

```bash
ELB=$(kubectl -n qwen4b-custom-hf get svc qwen3-4b-custom-hf-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$ELB:8000/v1/chat/completions \
   -H 'Content-Type: application/json' \
   -d '{"model":"qwen3-4b-custom","messages":[{"role":"user","content":"こんにちは"}]}'
```

#### 8B AWQモデル

`kubernetes/qwen3-8b-deployment.yaml` と `kubernetes/qwen3-8b-service.yaml` を適用します。

```bash
kubectl apply -f kubernetes/qwen3-8b-deployment.yaml
kubectl apply -f kubernetes/qwen3-8b-service.yaml
```

ELB DNS を取得して OpenAI 互換のエンドポイントへリクエストできます。

```bash
ELB=$(kubectl -n qwen8b get svc qwen3-8b-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST http://$ELB:8000/v1/chat/completions \
   -H 'Content-Type: application/json' \
   -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"こんにちは"}]}'
```

### 4. 同時接続数計測

`tests/concurrency_probe.py` を使用して、各モデルの最大同時接続数を計測できます。

#### 準備

`concurrency_probe.py` を実行する前に、`conda` 環境 `qwen_custom` に `aiohttp` をインストールしてください。

```bash
conda run -n qwen_custom pip install aiohttp
```

#### `concurrency_probe.py` の設定

`tests/concurrency_probe.py` を開き、以下の変数を計測対象のモデルに合わせて変更してください。

*   `ENDPOINT`: 計測対象モデルのELB DNSとポート
*   `MODEL_NAME`: 計測対象モデルのモデル名
*   `OUTPUT_DIR`: 結果を保存するディレクトリ名 (例: `4B_AWQ_raw`, `4B_AWQ_custom`, `8B_AWQ`)
*   `SUMMARY_CSV`: `OUTPUT_DIR` 内のサマリーCSVファイル名 (例: `concurrency_result_raw.csv`)

#### 実行

```bash
/opt/anaconda3/envs/qwen_custom/bin/python3 tests/concurrency_probe.py
```

結果は指定した `OUTPUT_DIR` 内にCSVファイルとして保存されます。

### 5. スケールテスト

`scripts/scale.sh` を使用して、GPUノードとデプロイのレプリカ数を同時にスケールできます。

```bash
scripts/scale.sh <GPUノード台数> <EKSクラスター名> <NodeGroup名> <デプロイの名前空間> <デプロイ名>
```

例:

*   **素の4B AWQモデルを1台にスケールダウン:**
    `scripts/scale.sh 1 qwen3-cluster gpu-ng qwen qwen3-awq-vllm`
*   **カスタム4B AWQモデルを1台にスケールダウン:**
    `scripts/scale.sh 1 qwen3-cluster gpu-ng qwen4b-custom-hf qwen3-4b-custom-hf-vllm`

`scripts/scale-test.sh` は、特定のシナリオでのスケールテストを実行するためのスクリプトです。

### 6. 自動スケール

*   Pod 水平スケール: HPA（例は README 末尾に記載）
*   GPU ノード自動増減: Karpenter NodePool 設定例も付属

---
**動いたら ⭐ Star をお願いします！**
