#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import time, json, sys, pprint
from pathlib import Path
import requests

ENDPOINT = "http://a66ebcb3861ff423cb98e777fd86d73d-1845622538.ap-northeast-1.elb.amazonaws.com:8000"

def get_model_id() -> str:
    r = requests.get(f"{ENDPOINT}/v1/models", timeout=10)
    r.raise_for_status()
    return r.json()["data"][0]["id"]

def infer_once(model: str, prompt: str):
    payload = {"model": model,
               "messages": [{"role": "user", "content": prompt}]}
    t0 = time.perf_counter()
    r = requests.post(f"{ENDPOINT}/v1/chat/completions",
                      json=payload, timeout=60)
    elapsed = time.perf_counter() - t0
    # 失敗しても本文を返して原因確認できるようにする
    try:
        body = r.json()
    except Exception:
        body = r.text
    return r.status_code, elapsed, body

def main() -> None:
    model = get_model_id()
    print(f"モデルID:{model}\n")

    pdir = Path("/Users/ryo/Downloads/qwen3_eks_setup/prompts")
    for pfile in sorted(pdir.glob("prompt*.txt")):
        prompt = pfile.read_text(encoding="utf-8").strip()
        status, sec, body = infer_once(model, prompt)

        print(f"{pfile.name:10s} status={status} time={sec:6.2f}s")
        # レスポンス本体を見やすく整形して出力
        if isinstance(body, dict):
            pprint.pprint(body, width=120, compact=True)
        else:
            print(body)
        print("-" * 80)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nユーザー中断")
    except Exception as e:
        print("エラー:", e, file=sys.stderr)
        sys.exit(1)
