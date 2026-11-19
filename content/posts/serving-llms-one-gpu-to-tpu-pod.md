---
title: "Can Three Small GPU Servers Run One Big Model?"
date: 2026-11-19T12:00:00+05:30
draft: false
tags: ["llm", "vllm", "kserve", "llm-d", "tpu", "nvlink", "kubernetes", "hetzner", "selfhosted"]
author: "Ashish Jaiswal"
summary: "Two days of reading and measuring how LLMs get served, from one 20 GB GPU on a 1 Gbit/s link up to a 9,216-chip TPU pod. One rule explains most of it: split a model only across fast links, and run whole copies behind a router everywhere else."
showToc: true
TocOpen: true
---

My [earlier post]({{< relref "setting-up-local-llm-at-obmondo.md" >}}) about our GPU box ended with a plan. The box is serving our agents now, and the plan raises a next question: if we add two more servers, can they run one bigger model together?

They can, but slowly. Working out why took me from our single 20 GB card to Google's 9,216-chip TPU pods and back to Kubernetes. One rule runs through all of it: split a model only across fast links such as NVLink or a TPU's inter-chip interconnect (ICI), and everywhere else run whole copies behind a router. A second rule goes with it. Memory size decides which model fits, and memory bandwidth decides how fast it answers.

---

## Where We Are: One 20 GB Card

The server is the [Hetzner GEX44](https://www.hetzner.com/dedicated-rootserver/gex44/) from the earlier post, with one NVIDIA RTX 4000 SFF Ada: 20 GB of GDDR6 ECC and 280 GB/s of memory bandwidth. It is a plain PCIe card with no NVLink, and the machine's only way out is a 1 Gbit/s Ethernet port.

```
Our GPU server today
┌──────────────────────────────┐
│ CPU ──PCIe slot── RTX 4000   │    a card in a slot
│ NIC ── 1 Gbit/s Ethernet ────┼──▶ the only way out
└──────────────────────────────┘
```

vLLM serves Gemma 4 12B on it, in the QAT build with 4-bit weights (`google/gemma-4-12B-it-qat-w4a16-ct`), with an fp8 KV cache (the memory it keeps for tokens it has already read) and a 262,144-token context. The weights take about 8 GB. The clients are opencode with our MCP server for our API, our Mattermost bot, and more agents on the way.

Decoding is limited by memory bandwidth, because producing a token means reading all the weights once. 280 GB/s divided by about 8 GB is 35 tokens a second at best, and at 70 to 80 percent efficiency that is about 25 per answer, an estimate from the arithmetic. What we did measure is a request with a prompt of about 16.7k tokens, which came back in 11 to 18 seconds end to end.

---

## A Detour: Should We Compress What Agents Send?

Every agent turn resends the whole conversation, and a 17k-token prompt costs 11 to 18 seconds on this card, so a compression proxy looked like an easy win. We read [Headroom](https://github.com/headroomlabs-ai/headroom) 0.44.0 and [lean-ctx](https://github.com/yvgude/lean-ctx) 3.12.6 from their code, then ran a contained trial of Headroom on synthetic data with made-up customers.

Headroom's lossless mode saved 0% on a 300-row markdown table, on the same rows as JSON, and on a 2,000-line log. Its default mode kept 45 of the 300 table rows and dropped the failed-backup one, and the model can fetch dropped rows back only on non-streaming requests, while opencode streams. It packed the JSON from about 30,255 Gemma tokens to about 15,740 with every row intact, but our MCP server's markdown table for the same data is about 16,748 tokens, so the saving over what we send today was 6%.

lean-ctx cuts long tool results to head, tail and error lines by default, which does not suit a table an agent has to read in full. One gotcha with Headroom: its readiness check probes `api.anthropic.com` even in offline mode, so with no network it never reported ready until we set `HEADROOM_SKIP_UPSTREAM_CHECK=1`.

We are not adding a compression hop. If a tool's output is too big, that tool is where to fix it.

---

## One Front Door for Every Agent

Today every agent calls vLLM directly. So that agents can be told apart and the model can change underneath them, we designed one OpenAI-compatible endpoint in front of vLLM, reachable only over our NetBird mesh. Traefik will pass each request to a small Go service (forwardAuth) that checks the agent's own key and swaps it for the backend key, so every request gets logged per agent. vLLM's `--served-model-name` gives the model one stable alias, and the agents keep calling the same name when Gemma is replaced.

Building it waits until we move the stack to Kubernetes. The GPU cluster gets no gateway of its own while it has one GPU server, since that would only add a hop, and when the model moves from Docker to KServe the agents keep calling the same endpoint.

---

## Three Servers, Two Layouts

Suppose we add two more servers like this one. There are two ways to use them.

**A: three replicas.** Each server runs its own Gemma 12B. An answer still arrives at about 25 tokens a second, total throughput triples, nothing travels between the GPUs, and with one server down two thirds of the capacity is left.

**B: one bigger model in thirds.** Split a model of about 50B parameters by layers, a third on each server. It fits only at 4-bit, about 27 GB of weights across 60 GB of GPU memory. Every token passes through all three servers in turn: activations go from server 1 to 2 and from 2 to 3, and the sampled token goes back from 3 to 1, which is three network hops per token. Splitting every layer across the GPUs instead (tensor parallelism) needs NVLink or RDMA class links, so on 1 Gbit/s this by-layers split is the only one available.

| | A: three replicas | B: one ~50B model in thirds |
|---|---|---|
| Speed per answer | about 25 tokens/s | about 7 to 9 tokens/s |
| 17k-token prompt | 11 to 18 s (measured) | about 20 to 30 s, plus about 5 s moving activations over 1 Gbit/s |
| One server down | two thirds of capacity left | the model is down |

All the B figures are estimates.

A better model needs more GPU memory in one server: a bigger card, or several cards in one box that split a model over PCIe 4.0 or 5.0 x16 at 32 to 64 GB/s each way, about 250 to 500 times our network. Bigger cards are faster too, since the RTX 6000 Ada has 48 GB at 960 GB/s. A second identical server adds capacity and redundancy, and it does not make any single answer faster or better.

---

## How the Big Labs Serve Models

The obvious question is whether copies behind a router is only what a small shop does for lack of choice. The big labs do it too, with a much bigger copy.

OpenAI and Anthropic, as far as I know, do not publish the size of their flagship models. The [GPT-4 report](https://arxiv.org/abs/2303.08774) says outright that it gives none, and the figures online are leaks or guesses, such as [1.8 trillion for GPT-4](https://the-decoder.com/gpt-4-architecture-datasets-costs-and-more-leaked/) from a 2023 newsletter. Open models can be counted, and the large ones I looked at are all mixture-of-experts: every weight has to sit in memory, but each token passes through only the active part.

| Model | Total parameters | Active per token |
|---|---|---|
| [gpt-oss-120b](https://openai.com/index/introducing-gpt-oss/) | 117B | about 5.1B |
| [Qwen3-235B-A22B](https://huggingface.co/Qwen/Qwen3-235B-A22B) | 235B | 22B |
| [Llama 4 Maverick](https://ai.meta.com/blog/llama-4-multimodal-intelligence/) | 400B | 17B |
| DeepSeek-V3 and [R1](https://huggingface.co/deepseek-ai/DeepSeek-R1) | 671B | 37B |
| [Kimi K2](https://arxiv.org/abs/2507.20534) | about 1T | 32B |

At those sizes one copy spans many GPUs. DeepSeek [published its serving setup](https://github.com/deepseek-ai/open-infra-index/blob/main/202502OpenSourceWeek/day_6_one_more_thing_deepseekV3R1_inference_system_overview.md): one decode copy spans 18 servers (144 H800 GPUs, [the H100 variant sold in China](https://www.datacenterdynamics.com/en/news/nvidia-creates-pared-back-h100-gpu-for-export-to-china-called-h800/)) with the experts spread across them, one prefill copy spans 4, and at one day's peak the service used 278 eight-GPU servers. The [DeepSeek-V3 report](https://arxiv.org/abs/2412.19437) puts NVLink inside a node at about 160 GB/s against 50 GB/s of InfiniBand between nodes, and the design crosses the slower links as little as it can: each token's experts sit on at most 4 nodes, and communication overlaps with compute (DualPipe).

Anthropic says it runs Claude on [three chip platforms](https://www.anthropic.com/news/expanding-our-use-of-google-cloud-tpus-and-services): Google TPUs, AWS Trainium and NVIDIA GPUs. It has announced plans for up to a million TPUs, uses AWS's [Project Rainier](https://www.aboutamazon.com/news/aws/aws-project-rainier-ai-trainium-chips-compute-cluster) (nearly half a million Trainium2 chips) and has committed to [$30 billion of Azure compute](https://www.anthropic.com/news/microsoft-nvidia-anthropic-announce-strategic-partnerships). Its [September 2025 postmortem](https://www.anthropic.com/engineering/a-postmortem-of-three-recent-issues) says each platform needs its own optimizations, and two of the three bugs it describes were TPU-specific. Anthropic hasn't described its serving layout. I expect whole copies on each platform with a router choosing one, because one copy cannot span two vendors' interconnects.

So the public recipe is to keep each copy inside one fast fabric (NVLink across 8 GPUs, or 72 in an NVL72 rack, or a TPU pod), join servers with InfiniBand or RoCE, split prefill (reading the prompt) from decode (writing tokens) and ship the KV cache between them, and run many copies.

---

## What a TPU Pod Actually Is

A TPU is a matrix-only chip built around systolic arrays. The first one, in production since 2015, was an [inference accelerator on a PCIe card](https://arxiv.org/abs/1704.04760) in an ordinary server. In the [TPU v4 paper](https://arxiv.org/abs/2304.01433), and again in Ironwood, each host carries four chips, and each chip has ports for cables that run straight to chips in other hosts.

```
One TPU host (Ironwood)
┌──────────────────────────────┐
│ CPU ──PCIe──┬── TPU   TPU    │    4 chips on one board
│             └── TPU   TPU    │
│ each TPU: 6 ICI cable ports ─┼──▶ straight to TPUs in other hosts
│ NIC ── data-centre network ──┼──▶ storage, other pods
└──────────────────────────────┘
```

Ironwood (TPU7x) has eight stacks of HBM3E giving [192 GB at about 7.4 TB/s](https://docs.cloud.google.com/tpu/docs/tpu7x), against our 20 GB at 280 GB/s: nearly ten times the memory and 26 times the bandwidth. It also has six ICI links, each [200 GB/s counting both directions](https://docs.cloud.google.com/tpu/docs/tpu7x), which makes 1,200 GB/s per chip. That is 600 GB/s each way, or 4,800 Gbit/s. Some older Google posts quote one-way figures, so you may see half of these numbers elsewhere.

Chips talk to chips over these cables, never through the CPU or Ethernet. Each chip has six neighbours, and the rows wrap around into rings, which makes a 3D torus. Four chips per host and 16 hosts per rack make a 64-chip cube.

Cubes are joined by an optical circuit-switch network. Mirrors point one fibre at another and the switch never reads a packet, which lets Google carve out slices in whole cubes and swap in a spare for a broken one. In the v4 paper, passive electrical cables make a 4×4×4 mesh inside a rack, each of the cube's six faces has 16 fibre links (96 in all), and the links on opposite faces go to the same switch, which closes the wrap-around. 144 cubes make Ironwood's [9,216-chip pod](https://docs.cloud.google.com/docs/compute-area/tpus). Outside the pod it is the data-centre network, which Google lists at 100 Gbit/s per chip, about 48 times less than the chip's own ICI in the same direction.

```
cube = one rack = 16 hosts × 4 TPUs = 64 chips
┌───────────────────────────┐
│ host [T][T][T][T]         │  ICI cables between the chips
│ host [T][T][T][T]         │
│  ... 16 hosts             │
└─────────────┬─────────────┘
              │ fibre out of the cube's six faces
┌─────────────┴───────────────────────────────────────────┐
│ optical circuit switches: mirrors aim each fibre        │
│ straight into another cube's fibre                      │
└───┬──────────┬──────────┬───────────────────────┬───────┘
  cube 2     cube 3     cube 4        ...       cube 144

144 cubes = 9,216 chips
```

NVIDIA's answer to the same problem is NVLink. An H100 has [18 links and 900 GB/s per GPU](https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/) counting both directions, and a B200 has [18 links of 100 GB/s, 1,800 GB/s](https://developer.nvidia.com/blog/nvidia-gb200-nvl72-delivers-trillion-parameter-llm-training-and-real-time-inference/). NVSwitch makes it all-to-all, but only across the 8 GPUs of a server or the 72 of an NVL72 rack. Beyond that it is InfiniBand at [400](https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-h100/latest/network-fabrics.html) to [800](https://docs.nvidia.com/networking/display/connectx8SuperNIC/Introduction) Gbit/s per GPU, about 9 times slower than NVLink in the same direction.

So NVLink is a small room where everyone talks to everyone, and ICI is a huge grid where you talk to your neighbours. Against that, our 1 Gbit/s is about 7,200 times below a B200's NVLink and about 4,800 times below Ironwood's ICI, comparing the same direction. That gap is why layout B can only be a pipeline split.

---

## Back on Kubernetes: vLLM, KServe and llm-d

vLLM is the engine, and [KServe](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-overview) is the Kubernetes operator that deploys it, through a resource called `LLMInferenceService`. Its overview diagram is a long list of integrations, and we need very little of it.

llm-d, for us, is a scheduler: the endpoint picker of the [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/). A gateway asks it which vLLM replica should get each request, and it [scores the replicas](https://llm-d.ai/blog/kvcache-wins-you-can-see) on how much of the prompt's beginning each one has cached, how long its queue is and how full its KV cache is. It matches on the prompt and ignores which client sent it, and it knows what each cache holds from its own routing history or from KV cache events that vLLM emits.

```
agent ──▶ gateway ── "which replica?" ──▶ llm-d scheduler
                                          scores every replica on:
                                           • longest cached start of this prompt
                                           • queue length
                                           • free KV cache memory
          gateway ◀────── "replica 2" ────┘
          gateway ──▶ vLLM replica 2
```

This matters for agents. On turn 5 an agent resends 17k tokens of context plus a new 1k tool result. The replica that served turn 4 only has to read the new 1k, while any other replica reads all 18k, roughly the 11 to 18 seconds from earlier. With round-robin over 2 replicas about half the turns miss, and over 3 replicas two thirds do. llm-d's prefill/decode split and cluster-wide KV cache index need fast links between GPUs, so neither helps servers on 1 Gbit/s.

Our plan has three phases: the front door in front of today's vLLM in Docker; KServe on one GPU, with no gateway and no llm-d; and, with two or more GPU servers, llm-d through KServe's `spec.router` plus a gateway, once we have measured the cache misses. We skip Knative and KEDA autoscaling, because on fixed bare metal there are no spare GPUs to scale onto and a cold start reloads the model. LMCache stays off for now because we hit an engine crash in vLLM's KV-transfer path with its connector, so we will try vLLM's native KV offload first.

---

## What I'm Taking From This

- Memory size decides which model fits, and memory bandwidth decides how fast it answers. Ours is 20 GB and 280 GB/s.
- A model can be split across devices only as far as the link between them allows. NVLink and TPU ICI can carry layers and experts across many chips. Our 1 Gbit/s cannot, so we run whole copies.
- More servers like ours add capacity and redundancy. A better model needs more memory inside one box.
- For agents, landing on a replica that already holds the context costs 1k tokens instead of 18k. A router like llm-d does that job, and we will add it once we have measured that two replicas miss often enough to matter.

---

*The 25 tokens a second and the three-server figures are estimates, and the TPU and NVLink numbers come from Google's and NVIDIA's published material. If something here is wrong, hit the "Suggest Changes" link above, or find me on [LinkedIn](https://linkedin.com/in/ashish1099) or [GitHub](https://github.com/ashish1099).*
