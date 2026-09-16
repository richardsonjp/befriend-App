#!/usr/bin/env python3
"""LoRA fine-tune of Qwen3.5-2B on befriend's harvested personalities, then export GGUF for llama.cpp.

Runs on a free Colab T4. Locally it needs an NVIDIA GPU; Apple silicon is not supported by Unsloth.

    pip install unsloth
    python3 training/train.py --data training/data --out training/out

Two things here are not the defaults and are deliberate:

* `load_in_4bit=False`. Unsloth's own Qwen3.5 guide advises against QLoRA for this family because the
  quantization error is unusually high. 2B in bf16 fits a T4 without it.
* `train_on_responses_only`. Every sample shares a long system message and a `<data>` block; without this the
  model spends its capacity learning to reproduce prompts it will always be given.
"""

import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument("--model", default="Qwen/Qwen3.5-2B")
parser.add_argument("--data", default="training/data")
parser.add_argument("--out", default="training/out")
parser.add_argument("--epochs", type=float, default=2.0)
parser.add_argument("--max-seq-length", type=int, default=2048)  # longest harvested sample is ~1.2k tokens
parser.add_argument("--rank", type=int, default=16)
parser.add_argument("--quant", default="q4_k_m", help="GGUF quantization for serving")
parser.add_argument("--skip-gguf", action="store_true")
args = parser.parse_args()

from unsloth import FastLanguageModel  # noqa: E402  (must precede transformers)
from unsloth.chat_templates import train_on_responses_only  # noqa: E402
from datasets import load_dataset  # noqa: E402
from trl import SFTConfig, SFTTrainer  # noqa: E402

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name=args.model,
    max_seq_length=args.max_seq_length,
    load_in_4bit=False,
    dtype=None,  # bf16 where supported, fp16 otherwise
)

model = FastLanguageModel.get_peft_model(
    model,
    r=args.rank,
    lora_alpha=args.rank * 2,
    lora_dropout=0.0,
    bias="none",
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ],
    use_gradient_checkpointing="unsloth",
    random_state=1,
)

data = load_dataset(
    "json",
    data_files={
        "train": os.path.join(args.data, "train.jsonl"),
        "val": os.path.join(args.data, "val.jsonl"),
    },
)


def render(batch):
    return {
        "text": [
            tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
            for messages in batch["messages"]
        ]
    }


data = data.map(render, batched=True, remove_columns=["messages"])

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=data["train"],
    eval_dataset=data["val"],
    args=SFTConfig(
        dataset_text_field="text",
        max_seq_length=args.max_seq_length,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=4,
        warmup_ratio=0.05,
        num_train_epochs=args.epochs,
        learning_rate=2e-4,
        logging_steps=10,
        eval_strategy="epoch",
        optim="adamw_8bit",
        weight_decay=0.01,
        lr_scheduler_type="linear",
        seed=1,
        output_dir=os.path.join(args.out, "checkpoints"),
        report_to="none",
    ),
)

# Qwen3.5 uses the ChatML markers; only what follows the assistant marker contributes to the loss.
trainer = train_on_responses_only(
    trainer,
    instruction_part="<|im_start|>user\n",
    response_part="<|im_start|>assistant\n",
)

trainer.train()

merged = os.path.join(args.out, "merged")
model.save_pretrained_merged(merged, tokenizer, save_method="merged_16bit")
print(f"train: merged weights → {merged}")

if not args.skip_gguf:
    gguf = os.path.join(args.out, "gguf")
    model.save_pretrained_gguf(gguf, tokenizer, quantization_method=args.quant)
    print(f"train: GGUF → {gguf} ({args.quant})")
print("Next: serve it with llama-server and grade with `apiserver harvest filter` on held-out inputs.")
