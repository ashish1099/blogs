---
title: "Upgrading vLLM to v0.17.0 with Qwen on RTX 4000 Ada: Every Breaking Change You Will Hit"
date: 2026-03-10T09:00:00+05:30
draft: false
tags: ["vllm", "qwen", "llm", "docker", "cuda", "tool-calling", "selfhosted", "qwen3"]
author: "Ashish Jaiswal"
summary: "A hands-on record of every error encountered upgrading from vLLM v0.9.2 to v0.17.0 with Qwen models on an RTX 4000 Ada (20GB VRAM): deprecated CLI flags, CUDA runtime changes, entrypoint conflicts, tool-call parser requirements, unsupported transformers, and how to pick the right quantized model for 20GB VRAM."
showToc: true
TocOpen: true
---

This is a follow-up to my earlier post on
[getting vLLM + Qwen2.5-14B working with tool calling on RTX 4000 Ada](/posts/vllm-qwen-tool-calling-rtx4000-ada/).
That setup ran vLLM v0.9.2. Upgrading to v0.17.0 broke things in ten distinct ways.
This post records each one in the order it was encountered, with the fix.

## Hardware and target

**GPU:** NVIDIA RTX 4000 SFF Ada Generation — 20GB VRAM, sm_89 architecture
**OS:** Ubuntu 24.04
**Upgrade path:** `vllm/vllm-openai:v0.9.2` → `vllm/vllm-openai:v0.17.0`
**Models explored:** Qwen3.5-9B, Qwen3-8B-AWQ, Qwen2.5-14B-Instruct-AWQ
**Final model:** `Qwen/Qwen2.5-14B-Instruct-AWQ`
**Goal:** Tool calling for agentic coding (qwen-code / OpenCode)

---

## Issue 1: `--model` flag is deprecated

**Symptom:** Container starts with a deprecation warning then exits or ignores the model arg.

**What changed:** In v0.17.0 the CLI restructured. `vllm serve` is now a proper subcommand
and the model name is a **positional argument**, not a flag.

**Old:**
```yaml
command: >
  --model Qwen/Qwen2.5-14B-Instruct-AWQ
  --quantization awq_marlin
```

**New:**
```yaml
entrypoint: ["vllm", "serve", "Qwen/Qwen3-8B-AWQ"]
command: >
  --quantization awq_marlin
  --gpu-memory-utilization 0.95
```

Note: this also leads directly to Issue 3 — keep reading.

---

## Issue 2: CUDA runtime not found

**Symptom:**
```
RuntimeError: Failed to infer device type
```

The container starts but vLLM can't see the GPU at all.

**Root cause:** The `runtime: nvidia` key in docker-compose conflicts with the `deploy:` block
when both are present in some Compose versions. The result is that neither works — the container
gets no GPU access.

**Fix:** Remove `runtime: nvidia` entirely and rely on the `deploy.resources.reservations`
block. Add `NVIDIA_VISIBLE_DEVICES=all` explicitly as an environment variable to ensure the
NVIDIA Container Toolkit exposes the GPU inside the container.

```yaml
services:
  lmcache-vllm:
    image: vllm/vllm-openai:v0.17.0
    # Do NOT add: runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - HF_TOKEN=${HF_TOKEN}
```

---

## Issue 3: Docker entrypoint conflict

**Symptom:** The command fails with an unrecognized argument error, or `vllm` is called twice in
the resulting process string.

**Root cause:** The `vllm/vllm-openai` image already sets `vllm` as its `ENTRYPOINT`. If your
docker-compose `command:` starts with `serve`, Docker passes it as an argument to `vllm` — which
works. But if you also prefix with `vllm` in the command, you get `vllm vllm serve ...`.

The clean approach that handles the model-as-positional-arg change from Issue 1 is to override
the entrypoint fully:

```yaml
entrypoint: ["vllm", "serve", "Qwen/Qwen3-8B-AWQ"]
command: >
  --gpu-memory-utilization 0.95
  --max-model-len 23232
  --quantization awq_marlin
  --enable-auto-tool-choice
  --tool-call-parser hermes
```

This gives you a clean process line: `vllm serve Qwen/Qwen3-8B-AWQ --gpu-memory-utilization ...`

---

## Issue 4: `--enable-auto-tool-choice` requires `--tool-call-parser`

**Symptom:** vLLM exits at startup:
```
ValueError: --enable-auto-tool-choice requires --tool-call-parser to be set
```

**Fix:** Add `--tool-call-parser`. In v0.17.0, the available parsers are:

```
deepseek_v3, deepseek_v31, deepseek_v32, ernie45, functiongemma, gigachat3, glm45, glm47,
granite, granite-20b-fc, hermes, hunyuan_a13b, internlm, jamba, kimi_k2, llama3_json,
llama4_json, llama4_pythonic, longcat, minimax, minimax_m2, mistral, olmo3, openai,
phi4_mini_json, pythonic, qwen3_coder, qwen3_xml, seed_oss, step3, step3p5, xlam
```

For Qwen3 family: `--tool-call-parser hermes` is the stable choice. `qwen3_xml` and
`qwen3_coder` are also available if your model uses those output formats.

---

## Issue 5: `--enable-prompt-tokens-details` does not exist

**Symptom:** vLLM exits at startup:
```
error: unrecognized arguments: --enable-prompt-tokens-details
```

**Fix:** Remove the flag. It does not exist in v0.17.0. If you need prompt token details in
responses, check the current vLLM docs for the equivalent (or confirm it is now default behavior).

---

## Issue 6: Transformers too old for Qwen3.5

**Symptom:** vLLM starts loading the model then exits:
```
KeyError: 'qwen3_5'
```
or a similar error about an unknown model architecture.

**Root cause:** `vllm/vllm-openai:v0.17.0` ships a pinned version of `transformers` that
predates Qwen3.5 support. `Qwen/Qwen3.5-9B` is not recognized.

**Options:**
1. Add a startup pip upgrade: `pip install --upgrade transformers` in an entrypoint wrapper.
   Fragile — future vLLM releases may break with unpinned transformers.
2. Use a model the bundled transformers already knows. `Qwen/Qwen3-8B-AWQ` works without
   any transformers upgrade.

Option 2 is preferable for a stable production setup.

---

## Issue 7: `--quantization awq_marlin` fails on non-quantized model

**Symptom:**
```
ValueError: The model Qwen/Qwen3.5-9B is not quantized. awq_marlin requires a pre-quantized model.
```

**Root cause:** `awq_marlin` is a quantization *backend*, not a runtime quantization method.
It requires the model weights to already be AWQ-quantized (the weights have AWQ metadata embedded).
`Qwen/Qwen3.5-9B` is a full-precision model — no quantization metadata.

**Fix:** Either remove `--quantization awq_marlin` (and accept full-precision inference), or use
a pre-quantized model. For a 20GB GPU, full precision 9B is also going to OOM — see Issue 8.

---

## Issue 8: CUDA OOM with full-precision 9B model

**Symptom:**
```
torch.cuda.OutOfMemoryError: CUDA out of memory
```

**Root cause:** `Qwen3.5-9B` in bfloat16 is approximately 18GB of weights alone. With KV cache
overhead and the vLLM runtime, it does not fit in 20GB VRAM.

**Fix:** Use a 4-bit quantized model. The AWQ-quantized variants of 8B/9B class models fit
comfortably with room for KV cache.

---

## Issue 9: AXERA-TECH/Qwen2.5-7B-Instruct-GPTQ-Int4 is for NPU, not NVIDIA

**Symptom:** Model loads but produces garbage output, or vLLM raises a backend compatibility error.

**Root cause:** `AXERA-TECH/Qwen2.5-7B-Instruct-GPTQ-Int4` is compiled and optimized for
**Axera NPU hardware**. The weight format and quantization scheme are not compatible with
vLLM's GPTQ/Marlin kernels for NVIDIA GPUs. The Hugging Face model card mentions NVIDIA support
only in a general sense — the actual weights are NPU-targeted.

**Fix:** Use officially published Qwen AWQ models from the `Qwen` org on Hugging Face.

---

## Issue 10: Model selection for 20GB VRAM

With full-precision models OOM-ing and NPU-targeted quants ruled out, the realistic options for
RTX 4000 Ada with v0.17.0 are:

| Model | VRAM estimate | Notes |
|---|---|---|
| `Qwen/Qwen3-8B-AWQ` | ~8GB weights + KV cache | Official, well-tested with vLLM |
| `Qwen/Qwen3-14B-AWQ` | ~10GB weights + reduced KV cache | Fits, but reduce max-model-len |
| `cyankiwi/Qwen3.5-9B-AWQ-4bit` | ~6GB weights + KV cache | Community quant, newest model |

`Qwen/Qwen3-8B-AWQ` is the most stable choice for v0.17.0 — official org, known to work with
the bundled transformers version, and `awq_marlin` activates cleanly on sm_89.

---

## Final working docker-compose

```yaml
services:
  lmcache-vllm:
    image: vllm/vllm-openai:v0.17.0
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    ports:
      - "8000:8000"
    volumes:
      - ~/.cache/huggingface:/root/.cache/huggingface
    environment:
      - HF_TOKEN=${HF_TOKEN}
      - NVIDIA_VISIBLE_DEVICES=all
    ipc: host
    entrypoint: ["vllm", "serve", "Qwen/Qwen2.5-14B-Instruct-AWQ"]
    command: >
      --gpu-memory-utilization 0.9
      --max-model-len 23232
      --quantization awq_marlin
      --enable-auto-tool-choice
      --tool-call-parser hermes
```

---

## Bonus: qwen-code in Docker

If you want to run the qwen-code CLI without installing Node locally:

```bash
docker run -it --rm node:22-slim bash -c \
  "npm install -g @qwen-code/qwen-code@latest && qwen-code"
```

Point it at `http://host-ip:8000` and it picks up the local vLLM endpoint.

---

## Summary of changes from v0.9.2 to v0.17.0

| Area | v0.9.2 | v0.17.0 |
|---|---|---|
| Model argument | `--model <name>` | Positional arg: `vllm serve <name>` |
| GPU in compose | `runtime: nvidia` or `deploy` | `deploy` only + `NVIDIA_VISIBLE_DEVICES=all` |
| Tool call parser | Optional | Required when `--enable-auto-tool-choice` is set |
| `--enable-prompt-tokens-details` | Supported | Removed |
| Qwen3.5 support | N/A | Requires transformers upgrade or use Qwen3 instead |

The upgrade has genuine improvements — the expanded tool-call parser list and cleaner CLI
structure are worth it. The migration is straightforward once you know which flags changed.
