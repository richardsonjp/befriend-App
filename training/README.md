# befriend's own personality model (M8)

Replaces the OpenRouter call in `internal/services/personality` with a fine-tune of **Qwen3.5-2B** (Apache 2.0),
served by `llama-server` under a GBNF grammar. One generation is seven calls: the profile block plus one
phrasebook chunk per trigger kind.

`Qwen3.5-1.7B` does not exist — the small dense tier is 0.8B / 2B / 4B / 9B.

## The run book

```bash
# 1. Prompts for synthetic users, from the live question set (needs the database up).
cd backend && go run ./cmd/apiserver harvest inputs -n 1200 --seed 1 -o ../harvest/inputs.jsonl

# 2. Answer them with Apple's on-device model. Hours; keep it foreground and awake.
cd ../PetCore && caffeinate -is swift run Harvest \
    --inputs ../harvest/inputs.jsonl --outputs ../harvest/outputs.jsonl
#    Run it again to retry whatever came back incomplete. Two passes is normal.

# 3. Grade with the same Validate the production worker runs.
cd ../backend && go run ./cmd/apiserver harvest filter \
    --inputs ../harvest/inputs.jsonl --outputs ../harvest/outputs.jsonl -o ../harvest/dataset.jsonl

# 4. Split by user.
cd .. && python3 training/prepare.py --dataset harvest/dataset.jsonl --out training/data

# 5. Train (free Colab T4, or any NVIDIA GPU; not Apple silicon).
pip install unsloth && python3 training/train.py --data training/data --out training/out
```

`harvest/` is gitignored: it is hours of generated text, reproducible from the seed.

### Skins (M9)

Each synthetic friend wears a random skin: about 30% the built-in one (the v1 moods and actions), the rest a
mix of built-in and new names, some moods with actions drawn only for them. Every record in `inputs.jsonl`
carries its skin, its own system message and its own chunk grammar; the Mac harvester generates under a schema
built from the skin, and `filter` validates against it. That's how the model learns to write for whatever moods
and actions a skin names, which production asks of it for every artist's skin.

**A dataset harvested before this doesn't teach that.** Re-run steps 1–5 (new inputs, harvest, filter, prepare,
train) before pointing production at the fine-tune; until then phrasebooks come from OpenRouter, which handles
any skin through the JSON schema. `generate.py` and `filter` still read old inputs (no per-record skin).

## What to expect

Measured on this Mac (macOS 26.3.1, Apple Intelligence on), from a 10-user batch:

| | |
|---|---|
| time per call | ~5.1 s (~36 s per personality) |
| passes for structural completeness | ~2 |
| usable personalities | roughly **1 per 3 harvested** |
| longest sample | ~1,200 tokens, so `max_seq_length` 2048 is ample |

Profile calls are the scarce half: they fail more often than chunks, mostly by slipping into first person.
`filter` keeps a personality's six chunks even when its profile call is rejected, so the dataset skews toward
chunks — which is the right way round, since chunks are 6 of every 7 calls in production too.

## Running a model and poking it from a terminal

Works the same for stock Qwen3.5-2B, the fine-tune, or anything else llama.cpp can load.

```bash
brew install llama.cpp                      # note: the bottle has no llama-gbnf-validator

# 1. Serve it. Leave this running in its own terminal.
llama-server -m ~/models/befriend/qwen35-2b-Q4_K_M.gguf --port 8899 -c 8192 -n -1
curl -s localhost:8899/health               # {"status":"ok"}

# 2. Grab a grammar and a real prompt.
cd backend && go run ./cmd/apiserver harvest grammar --kind profile > /tmp/profile.gbnf
go run ./cmd/apiserver harvest inputs -n 5 -o /tmp/inputs.jsonl     # needs the database up

# 3. One call by hand. /apply-template formats with the model's own chat template, which a fine-tune
#    trained through apply_chat_template requires — a raw prompt gives it a format it never saw.
PROMPT=$(jq -r '.calls[0].user' <(sed -n 2p /tmp/inputs.jsonl))
SYSTEM=$(jq -r '.system' <(sed -n 1p /tmp/inputs.jsonl))
TEMPLATED=$(jq -n --arg s "$SYSTEM" --arg u "$PROMPT" \
    '{messages:[{role:"system",content:$s},{role:"user",content:$u}]}' \
    | curl -s localhost:8899/apply-template -d @- | jq -r .prompt)
jq -n --arg p "$TEMPLATED" --arg g "$(cat /tmp/profile.gbnf)" \
    '{prompt:$p, grammar:$g, n_predict:4000, temperature:0.9}' \
    | curl -s localhost:8899/completion -d @- | jq -r .content
```

Without a grammar the output is unconstrained and will not parse — the grammar is not optional.

### The whole loop, scored

`generate.py` writes exactly what the Mac harvester writes, so one grader scores the on-device teacher, the
stock model and the fine-tune with no special cases:

```bash
python3 training/generate.py --inputs /tmp/inputs.jsonl --outputs /tmp/model.jsonl --users 5
cd backend && go run ./cmd/apiserver harvest filter \
    --inputs /tmp/inputs.jsonl --outputs /tmp/model.jsonl -o /tmp/graded.jsonl
```

Use `--skip` to score a slice the fine-tune never trained on.

Measured on this Mac (M-series, CPU/Metal, no GPU): **~44 s per personality** for 2B Q4_K_M — already inside
the <60 s budget before any GPU is rented.

## Judging the result

Pass rate alone is not the bar — the grammar guarantees structure, so a bad model still scores well on it.

1. **Grade it the same way.** Serve the GGUF, generate for held-out inputs, and run the output back through
   `harvest filter`. Target ≥95%, and clearly above stock Qwen3.5-2B under the same grammar.
2. **Read twenty.** Does the writing reference the questionnaire answers, or could any friend have said it?
   This is the thing pass rate cannot see, and the reason the teacher's ceiling matters.
3. **Compare against the teacher**, not against perfection. The student is distilled from a ~3B on-device model;
   matching it is success, and beating it would be surprising.

## Notes that cost time to learn

- **Don't use QLoRA.** Unsloth's Qwen3.5 guide advises against 4-bit training for this family — the quantization
  error is unusually high. `train.py` loads bf16 and only quantizes for serving.
- **`train_on_responses_only` matters here more than usual.** Every sample shares a long system message and a
  `<data>` block; without it, most of the gradient goes into reproducing prompts the model is always handed.
- **A model's own trained context caps generation** regardless of `n_predict`. If output truncates early, check
  `/props` on `llama-server` for the real `n_ctx` before blaming the grammar.
- **The `llama.cpp` Homebrew bottle ships no `llama-gbnf-validator`.** Validate grammars by POSTing to
  `llama-server`'s `/completion` with a `grammar` field instead.

## Still open

The harvest only covers **onboarding**. Evolution prompts carry `current_personality` and `recent_activity`,
which don't exist until personalities do. Once this dataset exists, feed passing personalities back as
`Previous` with synthetic activity to cover the weekly path too.
