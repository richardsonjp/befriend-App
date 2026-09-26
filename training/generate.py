#!/usr/bin/env python3
"""Run a served model over harvest prompts, under the grammar, writing what `harvest filter` grades.

    llama-server -m ~/models/befriend/qwen35-2b-Q4_K_M.gguf --port 8899 -c 8192 -n -1
    python3 training/generate.py --inputs inputs.jsonl --outputs model.jsonl --users 5
    cd backend && go run ./cmd/apiserver harvest filter \
        --inputs ../inputs.jsonl --outputs ../model.jsonl -o /dev/null

The output format is identical to the Mac harvester's, so the same grader scores the on-device teacher, the
stock model and the fine-tune with no special cases. That comparison is the whole acceptance test.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def post(url, path, body, timeout=1800):
    request = urllib.request.Request(
        url + path, json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    try:
        return json.load(urllib.request.urlopen(request, timeout=timeout))
    except urllib.error.URLError as err:
        raise SystemExit(f"generate: {url}{path}: {err}\nIs llama-server running?") from err


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", default="inputs.jsonl")
    parser.add_argument("--outputs", default="model.jsonl")
    parser.add_argument("--url", default="http://127.0.0.1:8899")
    parser.add_argument("--users", type=int, default=5, help="how many users to generate for")
    parser.add_argument("--skip", type=int, default=0, help="start at this user, to grade a held-out slice")
    parser.add_argument("--temperature", type=float, default=0.9)  # matches personality.Temperature
    parser.add_argument("--seed", type=int, default=-1)
    args = parser.parse_args()

    lines = [l for l in open(args.inputs).read().splitlines() if l.strip()]
    header = json.loads(lines[0])
    records = [json.loads(l) for l in lines[1:]][args.skip : args.skip + args.users]
    if not records:
        raise SystemExit(f"generate: no users at --skip {args.skip} in {args.inputs}")

    started = time.time()
    written = 0

    with open(args.outputs, "w") as out:
        for record in records:
            # Each friend wears its own skin, so its system message and chunk grammar are its own; inputs written
            # before skins varied carry them in the header.
            system = record.get("system") or header["system"]
            grammars = {"profile": header["profile_grammar"],
                        "chunk": record.get("chunk_grammar") or header["chunk_grammar"]}
            for call in record["calls"]:
                # Let the server apply the model's own chat template: a fine-tune trained through
                # apply_chat_template must be prompted the same way, or it sees a format it never saw.
                prompt = post(args.url, "/apply-template", {"messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": call["user"]},
                ]})["prompt"]

                at = time.time()
                answer = post(args.url, "/completion", {
                    "prompt": prompt,
                    "grammar": grammars[call["kind"]],
                    "n_predict": 4000,
                    "temperature": args.temperature,
                    "seed": args.seed,
                })
                out.write(json.dumps({
                    "id": record["id"],
                    "kind": call["kind"],
                    "trigger": call.get("trigger"),
                    "output": answer["content"],
                }) + "\n")
                out.flush()
                written += 1
                label = call.get("trigger") or call["kind"]
                print(f"  {record['id']} {label:>13}: {answer['tokens_predicted']:4d} tok "
                      f"{time.time() - at:5.1f}s stop={answer.get('stop_type')}", flush=True)

    elapsed = time.time() - started
    print(f"generate: {written} calls for {len(records)} users in {elapsed:.0f}s "
          f"({elapsed / len(records):.0f}s per personality) → {args.outputs}", file=sys.stderr)


if __name__ == "__main__":
    main()
