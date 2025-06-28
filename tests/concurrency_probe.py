#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prompt*.txt を対象に，
0.5/1/1.5/2/5/10 秒以内に応答が返る最大同時リクエスト数を探索し，
summary と prompt 別 detail CSV を出力。
8B AWQ クラスタ（ELB8）用：モデル名固定・エンドポイント差し替え。
"""

import asyncio, aiohttp, time, csv, pathlib, sys, json, random
from typing import List, Dict, Tuple, Any

# -------- 設定 -------- #
PROMPT_DIR   = pathlib.Path("/Users/ryo/Downloads/qwen3_eks_setup/prompts")
PROMPT_GLOB  = "prompt*.txt"

# ★ 8B クラスタの ELB とモデル名
ENDPOINT     = "http://a66ebcb3861ff423cb98e777fd86d73d-1845622538.ap-northeast-1.elb.amazonaws.com:8000"
MODEL_NAME   = "qwen3"

THRESHOLDS   = [0.5, 1, 1.5, 2, 5, 10]
MAX_LIMIT    = 1024
OUTPUT_DIR   = pathlib.Path("4B_AWQ_raw") # 新しい出力ディレクトリ
SUMMARY_CSV  = OUTPUT_DIR / "concurrency_result_raw.csv"
REQ_TIMEOUT  = aiohttp.ClientTimeout(total=60)
ANS_LIMIT    = 500

EXTRA_PROMPTS = [
    "仕事が辛いです", "学校に行きたくなくて",
    "悩みを聞いて", "今日も疲れた", "日々が辛いです"
]

# -------- 低レベル I/O -------- #
async def fetch_model_id(_: aiohttp.ClientSession) -> str:
    return MODEL_NAME               # 固定返却

async def infer_once(session: aiohttp.ClientSession, model: str, prompt: str
                     ) -> Tuple[Any, str | None]:
    extra = random.choice(EXTRA_PROMPTS)
    payload = {
        "model": model,
        "messages": [
            {"role": "user", "content": prompt},
            {"role": "user", "content": extra}
        ],
        "temperature": 1.0,
        "top_p": 1.0
    }
    for _ in range(3):
        t0 = time.perf_counter()
        try:
            async with session.post(f"{ENDPOINT}/v1/chat/completions",
                                    json=payload, timeout=REQ_TIMEOUT) as r:
                body = await r.text()
                if r.status == 200:
                    sec = round(time.perf_counter() - t0, 6)
                    try:
                        answer = json.loads(body)["choices"][0]["message"]["content"]
                    except Exception:
                        answer = body
                    return sec, answer
                else:
                    return "ERR", f"HTTP_{r.status} {body[:120]}"
        except Exception as e:
            last = f"EXCEPT_{e.__class__.__name__}"
    return "ERR", last

async def run_batch(session: aiohttp.ClientSession, n: int,
                    model: str, prompt: str
                    ) -> List[Tuple[Any, str | None]]:
    tasks = [infer_once(session, model, prompt) for _ in range(n)]
    return await asyncio.gather(*tasks)

# -------- 探索ロジック -------- #
def batch_ok(latencies: List[Any], threshold: float) -> bool:
    numeric = [l for l in latencies if isinstance(l, (int, float))]
    return len(numeric) == len(latencies) and max(numeric) <= threshold

def rows_from_batch(threshold: float, max_n: int | None,
                    attempt_n: int,
                    results: List[Tuple[Any, str | None]]) -> List[Dict]:
    rows = []
    for idx, (lat, ans) in enumerate(results, 1):
        rows.append({
            "threshold_s": threshold, "max_n": max_n,
            "attempt_n": attempt_n, "req_idx": idx,
            "latency_s": lat, "success": isinstance(lat, (int, float)),
            "answer": (ans or "")[:ANS_LIMIT].replace("\n", " ")
        })
    return rows

async def search_max_n(session: aiohttp.ClientSession, model: str,
                       prompt: str, threshold: float,
                       detail_rows: list) -> int:
    n = 1
    while n <= MAX_LIMIT:
        res = await run_batch(session, n, model, prompt)
        detail_rows.extend(rows_from_batch(threshold, None, n, res))
        if not batch_ok([r[0] for r in res], threshold): break
        n *= 2
    low, high, best = n // 2, min(n, MAX_LIMIT), n // 2
    while low + 1 < high:
        mid = (low + high) // 2
        res = await run_batch(session, mid, model, prompt)
        detail_rows.extend(rows_from_batch(threshold, None, mid, res))
        if batch_ok([r[0] for r in res], threshold):
            best, low = mid, mid
        else:
            high = mid
    for row in detail_rows:
        if row["threshold_s"] == threshold: row["max_n"] = best
    return best

async def process_prompt(session: aiohttp.ClientSession, model: str,
                         pfile: pathlib.Path) -> Dict[float, int]:
    prompt_text = pfile.read_text(encoding="utf-8").strip()
    detail_rows, result = [], {}
    for th in THRESHOLDS:
        n = await search_max_n(session, model, prompt_text, th, detail_rows)
        result[th] = n
        print(f"{pfile.name}: threshold {th} s ⇒ max_n = {n}")
    out_path = OUTPUT_DIR / f"{pfile.stem}_details.csv"
    with out_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(detail_rows[0].keys()))
        w.writeheader(); w.writerows(detail_rows)
    return result

# -------- メイン -------- #
async def main() -> None:
    OUTPUT_DIR.mkdir(exist_ok=True) # 出力ディレクトリを作成
    if not SUMMARY_CSV.exists():
        SUMMARY_CSV.write_text("prompt_file,threshold_s,max_concurrency\n", encoding="utf-8")

    connector = aiohttp.TCPConnector(limit=100, force_close=True)
    async with aiohttp.ClientSession(connector=connector) as session:
        model_id = await fetch_model_id(session)          # "qwen3-8b"
        for p in sorted(PROMPT_DIR.glob(PROMPT_GLOB)):
            stats = await process_prompt(session, model_id, p)
            with SUMMARY_CSV.open("a", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                for th, n in stats.items():
                    w.writerow([p.name, th, n])

if __name__ == "__main__":
    try:
        asyncio.run(main())
        print(f"\n✅ 完了: summary → {SUMMARY_CSV}, 詳細 → {OUTPUT_DIR}/*.csv")
    except KeyboardInterrupt:
        sys.exit("中断されました。")
