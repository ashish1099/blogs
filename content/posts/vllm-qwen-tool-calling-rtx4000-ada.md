---
title: "vLLM + Qwen2.5-14B on Hetzner RTX 4000 Ada: Making Tool Calling Work"
date: 2026-02-27T10:00:00+05:30
draft: false
tags: ["vllm", "qwen", "llm", "hetzner", "cuda", "tool-calling", "opencode", "selfhosted"]
author: "Ashish Jaiswal"
summary: "A complete journey of getting vLLM + Qwen2.5-14B-AWQ running on an RTX 4000 Ada with working tool calls for OpenCode: CUDA driver setup, throughput debugging, AWQ Marlin kernels for sm_89, writing a custom Qwen tool parser plugin, and debugging model refusals caused by a reasoning:true misconfiguration."
showToc: true
TocOpen: true
---

## Why Tool Calling Matters

Running a local LLM is useful. Running a local LLM that can *use tools* is where things get
genuinely interesting for agentic workflows.

[OpenCode](https://github.com/sst/opencode) is a terminal-based AI coding assistant — think
Cursor but in the terminal, with full tool-use support. It can read files, run shell commands,
edit code, and chain actions together to complete a task. That whole capability depends on the
LLM backend correctly returning `tool_calls` in its API responses.

Without tool calling, you get a chatbot that describes what it would do. With tool calling, you
get an agent that actually does it.

This post covers the complete journey of getting that working on a self-hosted RTX 4000 Ada node
with vLLM and Qwen2.5-14B-Instruct-AWQ — six distinct issues, each with a non-obvious fix.

## Setup

**Hardware:** Hetzner dedicated node with an NVIDIA RTX 4000 SFF Ada Generation (20GB VRAM,
sm_89 architecture)

**OS:** Ubuntu 24.04 (fresh install)

**Model:** `Qwen/Qwen2.5-14B-Instruct-AWQ` — 4-bit AWQ quantization, fits comfortably in 20GB
VRAM with room for KV cache

**Serving:** vLLM via Docker Compose

**Client:** OpenCode

### CUDA and Driver Install

Fresh Ubuntu 24.04 doesn't ship NVIDIA drivers in a state that works cleanly with Docker
containers. The sequence that worked:

```bash
# Remove any old driver fragments that conflict
sudo apt remove --purge nvidia-driver-535 nvidia-driver-550

# Add the CUDA repository keyring
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update

# Install linux headers (required for the kernel module to build)
sudo apt install linux-headers-$(uname -r)

# Install driver 590 and container toolkit
sudo apt install cuda-drivers nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

The specific pain point: without `libcuda.so.1` (provided by the `cuda-drivers` package), the
container runtime can see the GPU device but can't initialize CUDA inside the container. The
error surfaces as `CUDA error 803: system not yet initialized` — which is confusing because it
looks like a driver mismatch, not a missing library.

Removing the older drivers (535, 550) was also necessary — they leave behind conflicting package
state that causes the 590 install to fail or produce a broken partial setup.

## The Full Journey

What follows is each issue encountered in order, with diagnosis and fix. The final working
configuration appears at the end.

### Issue A: max-model-len Too Small

**Symptom:** vLLM started but rejected requests with a context-length error.

**Root cause:** The default `--max-model-len 8192` is too small. Qwen2.5's chat template adds
significant overhead (system prompt, tool definitions, special tokens), so even short user
messages were hitting the limit immediately.

**Fix:**

```
--max-model-len 32768
```

This was later revised down to 23232 (more on that in Issue D) to stay within the KV cache
capacity of the RTX 4000 Ada with AWQ Marlin at 16-bit KV dtype.

---

### Issue B: Missing Tool-Call Flags

**Symptom:** Model responded to normal chat requests fine, but tool-calling requests returned no
`tool_calls` field — just a plain text response.

**Root cause:** vLLM doesn't enable tool-use parsing by default. Without the right flags, it
serves the model as a plain completion endpoint and never attempts to parse structured tool calls
out of the output.

**Fix:**

```
--enable-auto-tool-choice --tool-call-parser hermes
```

(`hermes` is the built-in parser vLLM ships for Qwen-family models. As we'll see in Issue E, it
doesn't actually work for this model version — but this is still the right flag to start with.)

---

### Issue C: OpenCode max_tokens Overflow

**Symptom:** OpenCode requests were rejected with a context window error, even for simple tasks.

**Root cause:** OpenCode was sending `max_tokens: 32000` by default. The available output window
was only 19674 tokens (32768 context − 13094 input tokens for a typical coding request). vLLM
enforces `prompt_tokens + max_tokens <= max_model_len` — if the client asks for more output
tokens than are available, the request is rejected outright.

**Fix:** Reduce `max_tokens` in OpenCode config:

```json
// ~/.config/opencode/opencode.json
"Qwen/Qwen2.5-Coder-14B-Instruct-AWQ": {
  "limit": { "context": 23232, "output": 4096 }
}
```

4096 is more than enough output for any realistic coding task, and it leaves plenty of headroom
in the context window for the input. (An earlier iteration used 8192, but that was reduced
further once longer multi-turn conversations started exhausting the window — 4096 is the
sweet spot for interactive use with a 23232-token context.)

---

### Issue D: 3.2 tok/s — AWQ Marlin Kernels Missing for sm_89

This was the most subtle and most damaging issue.

**Symptom:** Throughput stuck at 3.2 tokens/second regardless of request complexity. GPU
monitoring showed:

- GPU core utilization: 100%
- Memory bandwidth: ~367 GB/s (85% of theoretical peak)
- Power draw: ~90W

Everything looked maxed out — but the output rate was unusably slow.

**The math that exposed the problem:**

- Qwen2.5-14B at 4-bit AWQ quantization ≈ 7 GB of model weights
- Memory-bandwidth-bound inference throughput = memory bandwidth / weight size
- 367 GB/s ÷ 7 GB/token = ~52 tokens/s theoretical maximum
- Actual: 3.2 tok/s = **114 GB of memory traffic per token**

That's 16× worse than theoretical. Something was reading the weights 16 times per token instead
of once.

**Root cause:** The `lmcache/vllm-openai:v0.3.14` image — which we started with for LMCache
support — was not compiled with sm_89 (Ada Lovelace) architecture targets. AWQ Marlin, the fast
Triton/CUDA kernel path for quantized inference, silently fell back to an unoptimized
de-quantize-then-multiply path. The GPU was 100% busy doing the wrong thing.

The fallback is silent. vLLM logs at startup don't say "Marlin not available for your GPU,
falling back." You have to notice the throughput arithmetic doesn't add up.

**Fix:** Switch to the official vLLM image with explicit sm_89 support and use the `awq_marlin`
quantization backend:

```yaml
image: vllm/vllm-openai:v0.9.2
command: --quantization awq_marlin ...
```

Throughput after the fix: ~20+ tokens/second. Usable for interactive work.

`max-model-len` was also recalculated at this point. With `awq_marlin` quantization and 16-bit
KV cache on the RTX 4000 Ada's 20GB VRAM, the KV cache capacity works out to a max context of
23232 tokens. Setting it higher causes OOM on the first large request.

**Lesson:** High GPU utilization with low throughput is a code-path smell. If the arithmetic
says you should be faster, you're probably running the wrong kernel. Always verify that your
image was compiled for your GPU architecture.

---

### Issue E: Custom Qwen Tool Parser

**Symptom:** Even with `--enable-auto-tool-choice --tool-call-parser hermes` and all the
correct flags, tool calling didn't work. The model responded with plain text: "I would use the
`read_file` tool to..." instead of returning a structured `tool_calls` response.

**Diagnosis:** Direct API test to capture raw model output:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-14B-Instruct-AWQ",
    "tools": [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}],
    "messages": [{"role": "user", "content": "Read /etc/hostname"}]
  }'
```

Raw text in the model's response:

```
<tools>{"name": "read_file", "arguments": {"path": "/etc/hostname"}}</tools>
```

The model was generating tool calls correctly — it just wrapped them in `<tools>...</tools>` XML
tags instead of the format the `hermes` parser expected. The hermes parser looked for a
different delimiter pattern, found nothing, and returned the raw text as content with no tool
calls extracted.

**Fix:** Write a custom vLLM tool parser plugin that handles Qwen's actual output format.

`qwen_tools_parser.py`:

```python
import json
import re
from typing import List, Union

from vllm.entrypoints.openai.tool_parsers import ToolParser, ToolParserManager
from vllm.entrypoints.openai.protocol import (
    ChatCompletionRequest,
    DeltaMessage,
    ExtractedToolCallInformation,
    FunctionCall,
    ToolCall,
)


@ToolParserManager.register_module("qwen_tools")
class QwenToolsParser(ToolParser):
    """
    Parser for Qwen2.5's tool call format: <tools>JSON</tools>
    """

    def extract_tool_calls(
        self,
        model_output: str,
        request: ChatCompletionRequest,
    ) -> ExtractedToolCallInformation:
        tool_calls = []
        pattern = r"<tools>(.*?)</tools>"
        matches = re.findall(pattern, model_output, re.DOTALL)

        for match in matches:
            try:
                parsed = json.loads(match.strip())
                tool_calls.append(
                    ToolCall(
                        type="function",
                        function=FunctionCall(
                            name=parsed["name"],
                            arguments=json.dumps(parsed.get("arguments", {})),
                        ),
                    )
                )
            except (json.JSONDecodeError, KeyError):
                continue

        if tool_calls:
            content = re.sub(pattern, "", model_output, flags=re.DOTALL).strip() or None
            return ExtractedToolCallInformation(
                tools_called=True,
                tool_calls=tool_calls,
                content=content,
            )

        return ExtractedToolCallInformation(
            tools_called=False,
            tool_calls=[],
            content=model_output,
        )

    def extract_tool_calls_streaming(
        self,
        previous_text: str,
        current_text: str,
        delta_text: str,
        previous_token_ids: List[int],
        current_token_ids: List[int],
        delta_token_ids: List[int],
        request: ChatCompletionRequest,
    ) -> Union[DeltaMessage, None]:
        # Streaming tool call extraction not implemented — returns None to fall back
        # to non-streaming mode for tool calls
        return None
```

Register it in docker-compose by mounting the file and adding the flags:

```yaml
command: >
  --model Qwen/Qwen2.5-14B-Instruct-AWQ
  --tool-call-parser qwen_tools
  --tool-parser-plugin /qwen_tools_parser.py
  ...

volumes:
  - ./qwen_tools_parser.py:/qwen_tools_parser.py
```

### Issue F: "I'm Sorry" Refusals — `reasoning: true` on a Non-Reasoning Model

**Symptom:** The model returns "I'm sorry, but I can't help with that request." for completely
safe requests sent through OpenCode. A direct curl to the same vLLM endpoint returns correct
output without any problem.

**Diagnosis:**

```bash
# Direct curl — works fine
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen2.5-14B-Instruct-AWQ",
       "messages": [{"role": "user", "content": "Write hello world in Go"}],
       "max_tokens": 256}' | jq '.choices[0].message.content'
# → Returns valid Go code ✓
```

Since raw vLLM works and OpenCode doesn't, the issue is in how OpenCode formats the request —
not in the model or serving infrastructure.

**Root cause:** `reasoning: true` in the OpenCode model config tells OpenCode this model
supports chain-of-thought / thinking mode. OpenCode then sends thinking-mode parameters (or
injects thinking tokens) in the request. `Qwen2.5-Coder-14B-Instruct` is an instruction-tuned
model — not a reasoning model like QwQ or Qwen3-thinking. Receiving unexpected thinking tokens
or parameters causes the model to produce a safety refusal instead of completing the task.

The symptom looks exactly like a content-policy trigger, which makes it easy to spend time
investigating the model configuration or vLLM settings when the actual problem is in the
client config.

**Fix:** Remove `reasoning: true` from the OpenCode config for this model:

```json
// ~/.config/opencode/opencode.json
"Qwen/Qwen2.5-14B-Instruct-AWQ": {
  "tool_call": true,
  "limit": { "context": 23232, "output": 4096 }
}
```

**Lesson:** If a self-hosted model refuses safe requests through the client but answers
correctly via direct curl, the problem is in the client's request formatting, not the model.
Check for any capability flags (`reasoning`, `thinking`, `vision`) that don't match the
model's actual capabilities.

---

## Verification

After restarting the container with the custom parser:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-14B-Instruct-AWQ",
    "tools": [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}],
    "messages": [{"role": "user", "content": "Read /etc/hostname"}]
  }' | jq '.choices[0].message.tool_calls'
```

Response:

```json
[
  {
    "id": "call_abc123",
    "type": "function",
    "function": {
      "name": "read_file",
      "arguments": "{\"path\": \"/etc/hostname\"}"
    }
  }
]
```

OpenCode confirmed end-to-end: file reads, shell execution, and code edits all flowing through
the local model with no external API calls.

## Final Configuration

Working `docker-compose.yml`:

```yaml
services:
  vllm:
    image: vllm/vllm-openai:v0.9.2
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
    command: >
      --model Qwen/Qwen2.5-14B-Instruct-AWQ
      --quantization awq_marlin
      --max-model-len 23232
      --enable-auto-tool-choice
      --tool-call-parser qwen_tools
      --tool-parser-plugin /qwen_tools_parser.py
      --chat-template /qwen_template.jinja
      --gpu-memory-utilization 0.95
    volumes:
      - ./qwen_tools_parser.py:/qwen_tools_parser.py
      - ./qwen_template.jinja:/qwen_template.jinja
      - hf_cache:/root/.cache/huggingface
    ports:
      - "8000:8000"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  hf_cache:
```

## Performance

| Metric | Value |
|--------|-------|
| Hardware | RTX 4000 SFF Ada (20GB VRAM, sm_89) |
| Model | Qwen2.5-14B-Instruct-AWQ (4-bit) |
| vLLM image | vllm/vllm-openai:v0.9.2 |
| Quantization | awq_marlin |
| Throughput (broken, lmcache image) | 3.2 tok/s |
| Throughput (fixed, v0.9.2 + awq_marlin) | ~20+ tok/s |
| Context window | 23232 tokens |
| VRAM at rest | ~12 GB |
| VRAM peak (full context) | ~18 GB |
| Power draw during inference | ~90W |

## Takeaways

**1. Match your image to your GPU architecture.**
sm_89 (Ada Lovelace) is recent enough that some community images skip it. Always verify that
AWQ Marlin kernels are actually activating — the fallback is silent and catastrophic for
throughput.

**2. High GPU utilization ≠ correct execution.**
The GPU was 100% busy doing the wrong thing. Throughput arithmetic tells the real story. If
memory bandwidth × expected weight size doesn't match your observed tokens/s, you're running
the wrong kernel.

**3. vLLM's built-in tool parsers are model-specific.**
The `hermes` parser expects a different delimiter format than Qwen2.5 actually produces. If tool
calls aren't working, capture raw model output first with a direct curl before assuming the
issue is configuration.

**4. Context window math matters for clients.**
`max_model_len` is the total budget shared between input and output. If your client sends
`max_tokens: 32000` and your prompt is already 13K tokens, every request will be rejected.
Cap `max_tokens` in the client config to something realistic.

**5. RTX 4000 Ada is a capable serving GPU for 14B models.**
20GB VRAM at Hetzner bare-metal pricing works well for this class of model. After the fixes, the
setup runs at 90W with 20+ tok/s throughput — comfortable for interactive developer use.

**6. Client capability flags must match the actual model.**
`reasoning: true` is for thinking models (QwQ, Qwen3-thinking). Setting it on a standard
instruct model produces mysterious safety refusals that look like content-policy triggers.
If the model refuses via client but works via direct curl, the problem is in the request
formatting — not the model.

---

This setup is now running in production at Obmondo for internal developer tooling via OpenCode.
The agentic coding workflow (multi-step file edits, test runs, commit messages) all works on the
local model with no external API dependency.
