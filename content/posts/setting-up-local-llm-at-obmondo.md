---
title: "Setting Up a Local LLM at Obmondo: From Zero to Qwen2.5-Coder"
date: 2026-02-24T10:00:00+01:00
draft: false
tags: ["llm", "ai", "selfhosted", "vllm", "hetzner", "devops", "opensource"]
author: "Ashish Jaiswal"
summary: "How we decided to run a local LLM at Obmondo — hardware selection on a budget, understanding quantization and model parameters, comparing Ollama vs vLLM, and landing on Qwen2.5-Coder for coding assistance."
showToc: true
TocOpen: true
---

## Why We Wanted a Local LLM

Every developer I know has a quiet anxiety about AI coding tools: you paste a function, a config snippet, or a stack trace into the chat box, and it goes somewhere. To a data center you don't control. Through a third-party API you're trusting not to log, train on, or leak it.

For personal side projects that's a reasonable tradeoff. For Obmondo — where we manage infrastructure for clients, handle proprietary automation code, and sometimes debug things that touch production secrets — it's not.

That's the itch. We wanted the productivity wins of an LLM assistant without the privacy trade-off of sending code to OpenAI or Anthropic.

The use cases we had in mind:

**Developer speed.** Quick coding Q&A without leaving the terminal. "How do I do X in Ruby?" or "What's wrong with this shell script?" — answered instantly, locally, with no context limits imposed by a third-party SaaS tier.

**POC fast lane.** Describing a feature idea in plain English and getting a working scaffold back in minutes. Not days of ticketing and refinement — just a rough implementation to reason about.

**Alert summarization.** We run monitoring with Prometheus and Alertmanager. When alerts fire at 2am, the raw output is not human-friendly. Piping that through an LLM to get a readable two-sentence summary before paging someone is genuinely useful.

**Feature request drafting.** Clients send us raw notes. Turning those into structured tickets with acceptance criteria is a mechanical task — one a local LLM can handle without seeing anything it shouldn't.

**Private internal projects.** Obmondo builds its own tooling. None of that should be in anyone else's training data.

We're ~40 people, with maybe 10 who would actively use a coding assistant day-to-day. That's the audience we're building for.

---

## The Budget Reality: Hetzner GEX44

The obvious objection to local LLMs is hardware. Running a capable model means GPU VRAM, and GPU cloud instances are expensive at sustained usage. An A100 on AWS runs $3–4/hour — that's $2,000+/month before you've done anything useful. Dedicated GPU servers on Hetzner are a completely different proposition.

We landed on the **[Hetzner GEX44](https://www.hetzner.com/dedicated-rootserver/gex44/)**.

Specs:

- **CPU:** Intel Core i5-13500 (14 cores — 6 performance + 8 efficiency)
- **RAM:** 64 GB DDR4
- **Storage:** 2 × 1.92 TB NVMe SSD (RAID 1)
- **GPU:** NVIDIA RTX 4000 SFF Ada — 20 GB GDDR6 ECC
- **Network:** 1 Gbps, unlimited traffic
- **Cost:** ~€184–205/month + a one-time setup fee of €264–312

That GPU is the key part. 20 GB of GDDR6 ECC VRAM is enough to run a quantized 14B model comfortably. ECC memory is a bonus — it matters for long-running inference workloads where bit errors would otherwise corrupt outputs silently.

The reasoning for dedicated over cloud GPU: if you're running a model that your team uses throughout the workday, you need it on all the time. At sustained cloud GPU pricing, dedicated is cheaper past roughly 300 hours of runtime per month. We'll be at that threshold easily.

### Cloud GPU Pricing Comparison (February 2026)

Here's what the alternatives actually cost at full-month (730-hour) runtime — the realistic baseline for an always-on inference server:

| Provider | Instance / Plan | GPU | VRAM | Monthly Cost |
|----------|----------------|-----|------|-------------|
| **Hetzner** | GEX44 (dedicated) | RTX 4000 SFF Ada | 20 GB | **~€184** (~$201) |
| AWS | g4dn.2xlarge | NVIDIA T4 | 16 GB | ~$549 |
| AWS | g5.2xlarge | NVIDIA A10G | 24 GB | ~$885 |
| Scaleway | L4-1-24G | NVIDIA L4 | 24 GB | ~€548 (~$600) |
| Lambda Labs | 1× A100 40GB | NVIDIA A100 | 40 GB | ~$1,080 |
| AWS | p3.2xlarge | NVIDIA V100 | 16 GB | ~$2,234 |
| DigitalOcean | GPU Droplet | NVIDIA H100 | 80 GB | ~$2,473 |
| Azure | NC24ads A100 v4 | NVIDIA A100 | 80 GB | ~$2,681 |

Cloud figures are on-demand hourly rates × 730 hours. Reserved instances (1–3 year) reduce cloud costs by 30–50%, but the gap against Hetzner dedicated is wide enough that discounts don't close it for sustained workloads.

A few things the table doesn't show:

- **Cloud GPU is elastic.** If you only need a GPU for a week-long experiment, hourly cloud pricing is clearly better. Dedicated makes sense only when the server runs all month.
- **Hetzner is in Europe** (Falkenstein, Germany). For an EU company handling client infrastructure, that's a compliance consideration alongside the cost one.
- **VRAM and GPU generation matter.** The AWS T4 (16 GB, $549/month) has less VRAM than the RTX 4000 Ada and is two GPU generations older. The A10G (24 GB, $885/month) is a closer architectural match — and still 4× the price.
- **Upcoming Hetzner price increase:** Hetzner has announced a ~16% price increase effective April 1, 2026, moving the GEX44 to ~€212/month. Even post-increase, the value proposition remains compelling against the alternatives above.

This is still a learning experiment. We're not betting the company on this hardware decision — we're buying ourselves room to figure out what actually works before committing to something larger.

---

## The Learning Curve: Understanding LLM Terms

Before picking a model, I had to stop pretending I understood what I was reading on HuggingFace. Here's what actually matters for our decision.

### Parameters

When someone says "7B model" they mean 7 billion parameters — the numerical weights that encode what the model learned during training. More parameters generally means more capable, but it also means more VRAM.

A rough rule of thumb: in full precision (float32), each parameter costs 4 bytes. A 7B model in float32 = 28 GB. That's already more than our GPU. This is why quantization exists.

### Quantization

Quantization compresses the model weights by reducing numeric precision. Think of it like JPEG compression for images: you trade some quality for a dramatic reduction in file size, and for most uses the difference is imperceptible.

Full float32 → half precision (float16, bfloat16) → 8-bit integers (Q8) → 4-bit integers (Q4) → further compression schemes (Q4_K_M, Q5_K_S, etc.)

The naming conventions you'll see:

- **GGUF** — the file format used by llama.cpp and Ollama. Model files end in `.gguf`. The quantization level is usually in the filename: `qwen2.5-coder-14b-instruct-Q4_K_M.gguf`
- **AWQ / GPTQ** — alternative quantization formats, commonly used with vLLM. Often better quality at the same bit-width than naive quantization
- **Q4_K_M** — a specific GGUF quantization: 4-bit, "K" variant (mixed precision, slightly better quality), medium size variant

For our 20 GB GPU:

- A **7B model at Q8** (8-bit) uses roughly 7–8 GB — plenty of headroom
- A **14B model at Q4_K_M** uses roughly 9–10 GB — fits well, leaves room for context
- A **32B model at Q4** uses roughly 18–20 GB — tight, might work, would leave little room for concurrent requests

The sweet spot for our use case is 14B at Q4, or 7B at Q8 if we need more throughput headroom.

### Browsing HuggingFace

HuggingFace is the GitHub of ML models. When evaluating models, the useful filters are:

- **Task:** Text Generation or Code Generation for what we need
- **Sort by Downloads or Likes** — a proxy for community confidence
- **Model card** — read it. Good model cards specify hardware requirements, benchmark results, and recommended quantizations. If a model card is thin, that's a yellow flag.

Quantized community builds are often published by users like bartowski or TheBloke — their GGUF uploads are widely used and tested.

---

## Ollama vs vLLM — Why We Picked vLLM

Once I understood what models to look at, the next question was what software to run them on. Two options kept coming up: Ollama and vLLM.

### Ollama

Ollama is remarkable for how simple it is. Install it, run `ollama pull qwen2.5-coder:14b`, and you have an HTTP API and a CLI ready to go. It handles model downloads, quantization format compatibility, and serving — all without configuration.

```bash
# Pull and run a model with Ollama
ollama run qwen2.5-coder:14b
```

Ollama is the right tool for a developer's laptop. Single user, interactive sessions, minimal setup. It's also great for testing — you can try five models in an afternoon with zero friction.

The limitation: Ollama processes requests serially by default. One user at a time. If two developers send requests simultaneously, the second one waits. For our use case — potentially 10 developers using it throughout the day — that's a bottleneck.

### vLLM

vLLM is a production-grade inference server developed at UC Berkeley. The core innovation is **PagedAttention** — a memory management technique that handles the KV cache (the working memory for active inference) much more efficiently than naive implementations.

The practical effect: vLLM can handle multiple concurrent requests by interleaving them efficiently, rather than serializing them. For multi-user workloads, this makes a substantial difference.

vLLM exposes an **OpenAI-compatible API** by default — the same `/v1/completions` and `/v1/chat/completions` endpoints. Any tool that works with the OpenAI API works with vLLM with just a base URL change. That matters because our developers already use tools built for the OpenAI API.

Starting vLLM looks like this:

```bash
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-Coder-14B-Instruct \
  --quantization awq \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --host 0.0.0.0 \
  --port 8000
```

And querying it works exactly like the OpenAI API:

```bash
curl http://your-server:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-Coder-14B-Instruct",
    "messages": [
      {"role": "user", "content": "Write a Python function to parse Alertmanager webhook payload"}
    ],
    "max_tokens": 512
  }'
```

The tradeoff: vLLM requires more setup, more familiarity with Python environments and GPU drivers, and has more moving parts than Ollama. It's not a five-minute install on a fresh machine.

### The Decision

For the server: **vLLM**. Ten concurrent users, even at modest peak load, need proper concurrent request handling. Ollama would serialize everything and developers would notice.

For local testing on developer laptops: **Ollama**. Zero-friction experimentation, useful for evaluating prompts and model behavior before deploying changes to the shared server.

---

## Choosing the Model: Qwen2.5-Coder

With the hardware and serving software decided, the remaining question was which model.

We knew we wanted a coding-focused model. General-purpose models (Llama 3, Mistral, Qwen2.5-base) are capable, but models fine-tuned specifically on code benchmarks and programming datasets consistently outperform them on the tasks we care about. No reason to start with a generalist when specialists exist.

The candidates we looked at seriously:

**Code Llama** (Meta) — the original coding-specialized open model, based on Llama 2. Still solid, but the ecosystem has moved on. Superseded for most use cases.

**DeepSeek Coder** — strong benchmarks, excellent multilingual code support. The DeepSeek-Coder-V2 in particular is impressive. Went on the shortlist.

**StarCoder2** — from BigCode/HuggingFace. Good code quality, but the model sizes available didn't line up as cleanly with our VRAM budget.

**Qwen2.5-Coder** (Alibaba) — the current generation of Qwen's coding models. Strong HumanEval scores, available in 7B, 14B, and 32B sizes, actively maintained, good quantized builds available.

We landed on **Qwen2.5-Coder-14B-Instruct** for these reasons:

- **Benchmark performance.** Qwen2.5-Coder-14B scores competitively on HumanEval and other code benchmarks — above Code Llama and close to much larger models.
- **Size fit.** 14B quantized to Q4 fits comfortably in 20 GB VRAM, with room left for concurrent requests.
- **Language coverage.** Our stack is Python, Ruby, Go, and shell. Qwen2.5-Coder handles all of these well — it's trained on a broad corpus, not just Python-heavy datasets.
- **Instruct variant.** The `-Instruct` versions are fine-tuned for conversation and instruction following, which is what we need. Not just code completion but Q&A, explanation, and generation from a description.
- **Community builds.** Active quantized builds on HuggingFace mean we can use AWQ or GPTQ versions directly with vLLM without rolling our own quantization pipeline.

The 32B variant would probably perform better, but it sits right at our VRAM limit and leaves nothing for concurrent users. We can always upgrade the model if 14B proves insufficient — the infrastructure stays the same.

---

## Scale Planning: 40 Employees, ~10 Active Users

Forty employees sounds like a lot of load, but in practice:

- Roughly 10 developers would use a coding assistant regularly
- Of those, probably 2–4 would be generating requests at the same moment at peak
- Each request is a few seconds to maybe 30 seconds depending on length

That's a very manageable load for a single GPU with vLLM. PagedAttention handles 2–4 concurrent requests without significant throughput degradation.

Latency expectations at this scale: a 14B quantized model on an RTX 4000 Ada generates roughly 20–40 tokens per second. A 200-token code response takes 5–10 seconds. That's acceptable for interactive use — not instant, but no worse than a slow network call to an external API.

How we'll expose it: the vLLM OpenAI-compatible endpoint means existing tooling works out of the box. Continue.dev (the VS Code extension most of our developers use for AI assistance) supports custom OpenAI-compatible backends with a single config line:

```json
{
  "models": [{
    "title": "Qwen2.5-Coder (Local)",
    "provider": "openai",
    "model": "Qwen/Qwen2.5-Coder-14B-Instruct",
    "apiBase": "http://your-server:8000/v1",
    "apiKey": "not-needed"
  }]
}
```

No code changes, no new integrations. The developers just update their config and point at the local server.

---

## The Use Cases We're Building Toward

Getting the server running is step one. Here's what we're planning to build on top of it.

**Developer coding assistant.** The immediate win. Connect Continue.dev or a similar extension to the local vLLM endpoint. Inline suggestions, explain-this-code, refactor prompts — all running locally. No external API calls, no data leaving our network.

**Alert summarizer.** This is the one I'm most excited about. The pipeline: Alertmanager fires a webhook → a small Python script receives it → strips the JSON payload to the relevant fields → sends it to the local LLM with a prompt like "Summarize this alert in two sentences for a sysadmin who just woke up" → posts the result to Slack alongside the raw alert link. If this works, it changes the on-call experience meaningfully.

Something like:

```python
import httpx

def summarize_alert(alert_payload: dict) -> str:
    prompt = f"""You are an on-call assistant. Summarize this alert briefly and clearly.
Alert: {alert_payload}
Summary (2 sentences max):"""

    response = httpx.post(
        "http://your-server:8000/v1/chat/completions",
        json={
            "model": "Qwen/Qwen2.5-Coder-14B-Instruct",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 100,
            "temperature": 0.2,
        }
    )
    return response.json()["choices"][0]["message"]["content"]
```

**Feature request drafting.** Client sends a Slack message or email with a rough idea. We paste it into a prompt template: "Turn this into a structured feature request with background, acceptance criteria, and open questions." Review, edit, done. Saves 15–20 minutes per ticket; across enough tickets that adds up.

**PoC generator.** Describe a feature in plain text, get a working scaffold. This is harder — LLMs hallucinate APIs and make structural mistakes. But for exploration and initial design, even a 70%-correct scaffold is useful as a starting point. We'll use this for internal tooling experiments, not client deliverables.

**Private internal work.** Obmondo's own tooling code can be referenced freely. No more "I can't show this to an external model." Debug sessions, architecture questions, documentation generation — all local.

---

## Current Status and What's Next

This is still a planning and learning phase. We have not provisioned the server yet. The decision to go with vLLM + Qwen2.5-Coder-14B is made; the next step is actually standing it up.

The planned sequence:

1. Provision the Hetzner GEX44 and set up the base OS (Ubuntu 24.04)
2. Install CUDA drivers and the NVIDIA container toolkit
3. Deploy vLLM via Docker with the Qwen2.5-Coder-14B-AWQ model
4. Benchmark: tokens/sec, latency under concurrent load, VRAM usage
5. Build and test the alert summarizer pipeline
6. Roll out the Continue.dev config to the developer team
7. Collect feedback, adjust the model or serving config as needed

The benchmark step will tell us if 14B is the right size or if we need to drop to 7B for acceptable concurrency, or if 32B is actually feasible with careful VRAM tuning.

I'll write a follow-up once it's live — with actual numbers, the real config, and whatever we got wrong the first time. The interesting part is rarely the plan.

---

*If you've been through a similar setup or have thoughts on model choice for multi-user coding assistance, I'd like to hear it. Find me on [LinkedIn](https://linkedin.com/in/ashish1099) or [GitHub](https://github.com/ashish1099). If something here is wrong, hit the "Suggest Changes" link above.*
