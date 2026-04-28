#!/usr/bin/env python3
"""Fine-tune a small local causal LM on swing coaching feedback."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, Iterable, List


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train a small local instruction model on llm_sft_train.jsonl.",
    )
    parser.add_argument(
        "--train-jsonl",
        type=Path,
        required=True,
        help="Path to llm_sft_train.jsonl generated from swing review annotations.",
    )
    parser.add_argument(
        "--model-path",
        type=str,
        required=True,
        help="Local model path or HuggingFace model id for a small causal LM.",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--num-train-epochs", type=float, default=3.0)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=8)
    parser.add_argument("--warmup-ratio", type=float, default=0.03)
    parser.add_argument("--weight-decay", type=float, default=0.01)
    parser.add_argument("--logging-steps", type=int, default=10)
    parser.add_argument("--save-steps", type=int, default=100)
    parser.add_argument(
        "--max-samples",
        type=int,
        help="Optional sample cap for smoke tests or quick iterations.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        import torch
        from datasets import Dataset
        from transformers import (
            AutoModelForCausalLM,
            AutoTokenizer,
            Trainer,
            TrainingArguments,
        )
    except ImportError as exc:
        raise SystemExit(
            "Missing training dependencies. Install scripts/requirements-llm-train.txt first.",
        ) from exc

    examples = load_examples(args.train_jsonl, max_samples=args.max_samples)
    if not examples:
        raise SystemExit("No training rows found in the provided JSONL.")

    tokenizer = AutoTokenizer.from_pretrained(args.model_path, use_fast=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model_path,
        torch_dtype=auto_torch_dtype(torch),
    )
    model.config.use_cache = False

    dataset = Dataset.from_list(
        [{"text": format_conversation(example["messages"], tokenizer)} for example in examples]
    )

    def tokenize_batch(batch: Dict[str, List[str]]) -> Dict[str, List[List[int]]]:
        encoded = tokenizer(
            batch["text"],
            padding="max_length",
            truncation=True,
            max_length=args.max_length,
        )
        encoded["labels"] = [ids[:] for ids in encoded["input_ids"]]
        return encoded

    tokenized = dataset.map(tokenize_batch, batched=True, remove_columns=["text"])

    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    bf16_available = torch.cuda.is_available() and getattr(torch.cuda, "is_bf16_supported", lambda: False)()
    fp16_enabled = torch.cuda.is_available() and not bf16_available

    training_args = TrainingArguments(
        output_dir=str(out_dir),
        per_device_train_batch_size=args.per_device_train_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        num_train_epochs=args.num_train_epochs,
        warmup_ratio=args.warmup_ratio,
        weight_decay=args.weight_decay,
        logging_steps=args.logging_steps,
        save_steps=args.save_steps,
        save_total_limit=2,
        report_to="none",
        remove_unused_columns=False,
        bf16=bf16_available,
        fp16=fp16_enabled,
        optim="adamw_torch",
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized,
        tokenizer=tokenizer,
    )
    trainer.train()

    trainer.save_model(str(out_dir))
    tokenizer.save_pretrained(str(out_dir))
    (out_dir / "training_config.json").write_text(
        json.dumps(
            {
                "train_jsonl": str(args.train_jsonl.expanduser().resolve()),
                "model_path": args.model_path,
                "sample_count": len(examples),
                "max_length": args.max_length,
                "num_train_epochs": args.num_train_epochs,
                "learning_rate": args.learning_rate,
                "per_device_train_batch_size": args.per_device_train_batch_size,
                "gradient_accumulation_steps": args.gradient_accumulation_steps,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print(f"Model saved to: {out_dir}")
    print(f"Training config saved to: {out_dir / 'training_config.json'}")


def load_examples(path: Path, max_samples: int | None = None) -> List[dict]:
    rows = []
    with path.expanduser().resolve().open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
            if max_samples is not None and len(rows) >= max_samples:
                break
    return rows


def format_conversation(messages: Iterable[dict], tokenizer) -> str:
    messages = list(messages)
    if hasattr(tokenizer, "apply_chat_template") and tokenizer.chat_template:
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=False,
        )

    parts = []
    for message in messages:
        role = message.get("role", "user").upper()
        content = message.get("content", "")
        parts.append(f"{role}:\n{content}")
    return "\n\n".join(parts)


def auto_torch_dtype(torch):
    if torch.cuda.is_available():
        if getattr(torch.cuda, "is_bf16_supported", lambda: False)():
            return torch.bfloat16
        return torch.float16
    return torch.float32


if __name__ == "__main__":
    main()
