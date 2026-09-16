#!/usr/bin/env python3
"""Turn dataset.jsonl from `apiserver harvest filter` into training and validation files.

    python3 training/prepare.py --dataset dataset.jsonl --out training/data

Splits by user, not by sample: a friend's profile call must not sit in training while its chunk calls sit in
validation, or the validation loss flatters itself. Everything else here is bookkeeping — the grading already
happened in Go, against the same Validate the production worker runs.
"""

import argparse
import json
import pathlib
import random
import collections

CHAT_ROLES = ("system", "user", "assistant")


def load(path):
    rows = []
    with open(path) as handle:
        for n, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as err:
                raise SystemExit(f"{path}:{n}: {err}") from err
    if not rows:
        raise SystemExit(f"{path}: empty — run `apiserver harvest filter` first")
    return rows


def as_chat(row):
    return {
        "messages": [
            {"role": "system", "content": row["system"]},
            {"role": "user", "content": row["user"]},
            {"role": "assistant", "content": row["output"]},
        ]
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default="dataset.jsonl")
    parser.add_argument("--out", default="training/data")
    parser.add_argument("--val-users", type=float, default=0.1, help="fraction of users held out")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    rows = load(args.dataset)

    # Identical (user, output) pairs teach nothing twice. The teacher repeats itself across users often enough
    # that this is worth doing before the split rather than after.
    seen, unique = set(), []
    for row in rows:
        key = (row["user"], row["output"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)

    users = sorted({row.get("id", "") for row in unique})
    random.Random(args.seed).shuffle(users)
    held_out = set(users[: max(1, round(len(users) * args.val_users))]) if len(users) > 1 else set()

    train = [r for r in unique if r.get("id", "") not in held_out]
    val = [r for r in unique if r.get("id", "") in held_out]

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows_out in (("train", train), ("val", val)):
        with open(out / f"{name}.jsonl", "w") as handle:
            for row in rows_out:
                handle.write(json.dumps(as_chat(row), ensure_ascii=False) + "\n")

    kinds = collections.Counter(r.get("trigger") or r.get("kind", "?") for r in unique)
    # Rough, but enough to size max_seq_length: ~4 characters per token.
    longest = max(len(r["system"]) + len(r["user"]) + len(r["output"]) for r in unique)

    print(f"prepare: {len(rows)} samples, {len(unique)} after dedupe, {len(users)} users")
    print(f"  train {len(train)} · val {len(val)} ({len(held_out)} users held out)")
    print(f"  longest sample ~{longest // 4} tokens (set max_seq_length above this)")
    print("  by call: " + ", ".join(f"{k} {n}" for k, n in kinds.most_common()))
    if len(val) == 0:
        print("  WARNING: no validation samples — harvest more users before training")
    print(f"  → {out}/train.jsonl, {out}/val.jsonl")


if __name__ == "__main__":
    main()
