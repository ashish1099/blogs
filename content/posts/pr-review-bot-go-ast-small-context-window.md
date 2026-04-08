---
title: "Building a PR Review Bot Under 32K Context: Go AST Diffing, YAML Key Diffing, and Smart Truncation"
date: 2026-04-08
draft: false
tags: ["go", "golang", "llm", "mattermost", "gitea", "ast", "code-review", "vllm", "qwen", "kubernetes"]
categories: ["development", "ai"]
author: "Ashish Jaiswal"
summary: "Artoo, Obmondo's Mattermost bot, got a PR review engine that runs on a self-hosted Qwen3-14B with a ~32K context window. The key problem: a single Kubernetes PR can have 10,000+ lines of diff. The solution: Go pre-processing that compresses diffs to ~2KB before the LLM ever sees them — using go/ast for Go files, YAML key-level diffing for Helm/K8s configs, and priority-based file truncation. This post covers why each decision was made and what the LLM still cannot do."
showToc: true
TocOpen: true
---

## The Setup

[Artoo (R2)](https://gitea.obmondo.com/EnableIT/artoo) is Obmondo's internal Mattermost bot. It handles
team operations: customer monitoring, Gitea PR announcements, award scoring, timereg summaries. It runs
on a self-hosted vLLM instance with Qwen3-14B-AWQ — roughly 32K usable context at ~1.4 tokens/word.

The PR review feature started from a simple question: can the bot say something useful when someone
drops a PR link in a channel? Not just "here is a link" — actually catch issues.

The hard constraint was the context window. A routine KubeAid PR might touch 40 Go files, 15 Helm
values files, and 3 Markdown docs. The raw unified diff could be 8,000–15,000 lines. That blows the
context before the system prompt, conversation history, and response budget even get counted.

The solution is not prompt engineering. It is pre-processing in Go.

## Architecture: Go Does the Work, LLM Does the Prose

The data flow for a PR review looks like this:

```
PR URL posted in Mattermost
        │
        ▼
  [Go: Gitea SDK]
  Fetch PR metadata, commits, diff, CI status, reviewer list
        │
        ▼
  [Go: Security Scanner]
  Regex scan full diff for credentials, dangerous commands, chmod 777
  → produces: []SecurityFinding (no LLM involved)
        │
        ▼
  [Go: Structural Diff]
  Per-file: route to AST diffing (Go), YAML key diffing (YAML), or line truncation (other)
  → produces: ~2KB structural summary
        │
        ▼
  [Go: Commit Quality Check]
  Conventional commit format, message length, squash hygiene
  → produces: []CommitIssue
        │
        ▼
  [LLM: Qwen3-14B]
  Receives: ~2KB summary + metadata + findings
  Produces: human-readable review paragraph, 1-line teaser
        │
        ▼
  Phase 1: post witty one-liner to channel
  Phase 2: post full review when user asks
```

The LLM never sees the raw diff. It receives a compressed, structured summary that a human engineer
would recognize as the key changes in the PR. Token usage per review: ~3K. Standard tool-calling
approach (LLM decides what to fetch, fetches raw diff): ~6K+, two round-trips.

## Why Go Pre-processing Over LLM Tool-calling

The standard ADK/LangChain approach would be: give the LLM tools like `get_diff`, `get_commits`,
`get_ci_status`, let it call them, and reason over the raw results.

That does not work here for two reasons.

First, the context window. A raw Go file diff is dense — 500 changed lines is not unusual in a
refactor. The LLM cannot summarize what it cannot fit. Pre-processing compresses the signal before
it reaches the LLM.

Second, speed. Every tool call is a round-trip: LLM decides to call the tool, tool runs, result
goes back to LLM, LLM continues. On a 14B model with no batching headroom, that is 3–4 seconds per
round-trip. Two round-trips plus generation: 8–10 seconds of latency on a busy channel. With Go
pre-processing, there is one LLM call after all data is in hand. Total latency is 2–4 seconds.

The trade-off: Go pre-processing requires upfront investment in parsing logic. The LLM tool-calling
approach is more flexible — the model can ask for exactly what it needs. We made the explicit bet that
Obmondo's PR patterns (Go services + Kubernetes/Helm configs) are stable enough to hardcode the
extraction logic.

## Go AST Diffing for Go Files

The most impactful single decision was replacing raw Go file diffs with AST-level structural diffs.

A 500-line diff of a Go file, formatted for the LLM, might look like 200 added lines and 300 removed
lines of `+` and `-` prefixed code. Most of those lines are braces, comments, variable declarations
inside function bodies. The LLM has to parse all of it to extract the structural signal.

AST diffing extracts the signal directly. We parse both the before and after versions of the file
using `go/ast` and `go/parser`, extract the top-level declarations (functions, types, interfaces,
imports), and diff the two sets.

The output looks like this:

```
+ func HandleAuth(ctx context.Context, token string) error
~ func ProcessPR: signature changed (added parameter reviewers []string)
- func OldHelper (removed)
~ import: added "crypto/rand"
~ import: removed "math/rand"
~ struct ReviewRequest: field Added string (added)
```

That is 7 lines instead of 500. The LLM now has the structural contract of the change — what is
new, what changed signature, what was removed — without wading through implementation details.

Implementation note: `go/parser` requires valid Go source. For files that only exist in the new
version (additions) we parse the new file. For deletions we parse the old. For modifications we parse
both versions independently from the diff hunks, reconstructing the before/after source. Partial hunks
that do not compile cleanly fall back to line truncation (first 50 lines).

```go
// Reconstruct source from a diff hunk (simplified)
func extractFileVersions(hunks []DiffHunk) (before, after string) {
    var beforeLines, afterLines []string
    for _, h := range hunks {
        for _, line := range h.Lines {
            switch line.Type {
            case LineRemoved:
                beforeLines = append(beforeLines, line.Content)
            case LineAdded:
                afterLines = append(afterLines, line.Content)
            case LineContext:
                beforeLines = append(beforeLines, line.Content)
                afterLines = append(afterLines, line.Content)
            }
        }
    }
    return strings.Join(beforeLines, "\n"), strings.Join(afterLines, "\n")
}
```

## YAML Key-Level Diffing for Kubernetes and Helm Files

Infrastructure repos at Obmondo are heavy on Helm values files. A single `values.yaml` for a
complex chart can be 300–600 lines. A PR that bumps a replica count and enables monitoring adds
maybe 3 meaningful lines of change, but the context diff includes 60 lines of surrounding unchanged
YAML for hunk context.

We solve this with `gopkg.in/yaml.v3`. Both versions of the YAML file are unmarshalled into
`map[string]interface{}`, then we walk both trees simultaneously and record only the differences:

```
+ monitoring.enabled = true
+ monitoring.serviceMonitor.interval = "30s"
~ replicas: 2 → 3
- legacyAnnotations.deprecated (removed)
```

Nested keys are flattened with dot notation. Arrays use index notation (`containers[0].image`).
The output is always flat, always human-readable, and scales to zero for unchanged files.

Edge cases worth noting: YAML anchors and aliases (`&anchor`, `*ref`) are resolved by
`gopkg.in/yaml.v3` before unmarshalling, so the diff sees the expanded values. Multiline strings
(`|` blocks) are compared as a single value — we show `~ description: <multiline changed>` rather
than inlining the text.

## Smart Truncation by File Priority

Not every file type deserves the same treatment, and not every file deserves to reach the LLM at all.

Files are sorted into priority buckets:

| Priority | File types | Treatment |
|----------|-----------|-----------|
| 1 — Source | `*.go`, `*.py`, `*.ts`, `*.rs` | AST diff (Go) or first 50 lines (other) |
| 2 — Config | `*.yaml`, `*.yml`, `*.json`, `*.toml` | YAML key diff or first 30 lines |
| 3 — Tests | `*_test.go`, `*.spec.*` | Count only: `+12 / -8 lines in 3 test files` |
| 4 — Docs | `*.md`, `*.txt`, `*.rst` | First 20 lines |
| 5 — Generated | `go.sum`, `vendor/`, `*.min.js`, `*_gen.go` | Skipped entirely |

Generated files are the most important to skip. A `go.sum` update from a single dependency bump adds
300–400 lines of hash changes that are meaningless to review. Including them in the LLM input would
consume ~25% of the available context budget with zero signal.

The total compressed input to the LLM is capped at 6KB regardless of PR size. A PR with 200 changed
files and a 15,000-line diff produces the same ~2–4KB LLM input as a 10-file PR, because the
priority sorting and truncation are deterministic.

## Security Scanning Without LLM Tokens

Security scanning runs entirely in Go with regex patterns. It never touches the LLM.

Patterns checked:

- Hardcoded credentials: `password\s*=\s*["'][^"']{8,}`, AWS key prefixes, GCP service account JSON shapes
- Dangerous shell: `curl\s+\S+\s*\|\s*(bash|sh)`, `rm\s+-rf\s+/`, `chmod\s+777`
- Kubernetes footguns: `kubectl\s+delete\s+(namespace|node)`, `--force\s+--grace-period=0`
- Secrets in environment: `env.*SECRET`, `env.*PASSWORD` in Kubernetes pod specs

Each finding has a severity level (critical, warning, info) and the exact diff line that triggered it.
Critical findings are surfaced in the one-liner teaser regardless of whether the user asks for the
full review.

The rationale for keeping this out of the LLM: regex patterns are deterministic and auditable. When a
security finding fires, we know exactly which pattern matched which line. LLM-based security scanning
has false positive rates that are hard to characterize and outputs that vary across generations. For
security specifically, determinism matters more than comprehensiveness.

## Two-Phase Interaction Design

The review does not arrive as a wall of text the moment a PR link is posted. That would be annoying
in an active channel where PR links appear constantly.

Phase 1 triggers silently when any PR URL is detected in a message. Go runs the full analysis
pipeline. The LLM produces a one-liner teaser that signals severity without detail:

```
Boop — KubeAid#1399 gets a clean bill of health. Conventional commits, CI passing, no security flags.
```

```
R2 spotted KubeAid#1412 — 3 commits, 2 unsigned. Ask me for the full review when ready.
```

Phase 2 triggers when someone in the channel asks for the review: "r2 review that PR", "what did you
find", "give me the full review". The bot recognizes the intent (keyword matching, not LLM) and posts
the full structured review including commit quality, security findings, reviewer coverage, and the LLM
summary paragraph.

This design keeps the bot from interrupting every PR link paste while making the review available on
demand. The analysis result is cached in memory keyed by PR URL for 10 minutes, so Phase 2 does not
re-run the pipeline.

## The Write Guard

The bot is read-only by design. It can analyze and report; it cannot create PRs, open issues,
merge branches, or run deployments.

Enforcing this purely through prompt instructions ("never create PRs") is not reliable — any
jailbreak or unusual phrasing could slip through. Instead, a Go-level write guard intercepts requests
before they reach the LLM:

```go
var writeGuardPatterns = []*regexp.Regexp{
    regexp.MustCompile(`(?i)\b(create|open|submit)\s+(a\s+)?(pr|pull.?request|issue|ticket)\b`),
    regexp.MustCompile(`(?i)\b(merge|close|approve)\s+(the\s+)?(pr|pull.?request)\b`),
    regexp.MustCompile(`(?i)\bhelm\s+(install|upgrade|uninstall)\b`),
    regexp.MustCompile(`(?i)\bkubectl\s+(apply|delete|patch|scale)\b`),
    // ... 15 more patterns
}
```

The hard part is false positives. "The helm upgrade failed, can you look at the logs?" should not
trigger the guard. "Run helm upgrade prometheus" should. The distinction is intent phrasing, not
keyword presence.

We addressed this with a two-pass approach: the guard checks for write verbs, then checks for
negation context (failed, error, issue with, problem with) and question framing (can you, did it,
why did). If either negation or question framing is present, the pattern is suppressed.

The guard has a dedicated test file with 100+ cases covering the boundary carefully. Any new pattern
requires at least 3 true-positive and 3 false-positive test cases before merging.

## What the LLM Actually Does (and What It Cannot)

After all the Go pre-processing, the LLM receives something like:

```
PR: KubeAid#1412 — "feat: add Cilium BGP peer config"
Author: alice | CI: passing | Reviews: 1/2 requested
Commits (3): 2 conventional, 1 non-conventional ("wip: fix test")
Security: clean

Structural changes:
  cilium/bgp.go:
    + func NewBGPPeerConfig(asn int, peer net.IP) *BGPConfig
    + struct BGPConfig: fields ASN int, PeerIP net.IP, HoldTimer time.Duration
  values/cilium.yaml:
    + bgp.enabled = true
    + bgp.peers[0].asn = 65001
    ~ bgp.peers[0].peerAddress: "" → "192.168.1.1"
```

The LLM does well at: summarizing the intent of the change in plain English, flagging the
non-conventional commit message, noting that HoldTimer has no default and might need documentation,
and generating the witty one-liner teaser.

The LLM cannot catch: logic bugs inside function bodies (it never sees them), off-by-one errors,
race conditions, incorrect algorithm implementations, or anything that requires understanding the full
execution context of the system. That is not a failure of the LLM — it is a consequence of the
compression. The compression is a necessary trade-off to fit within 32K context.

The honest position: this bot catches convention violations, security anti-patterns, and structural
changes reliably. It provides a human-readable summary that saves a reviewer 2 minutes of orientation.
It does not replace code review. It augments it.

## Takeaways

1. **Pre-processing is underrated.** Go AST parsing and YAML tree diffing are not glamorous, but they
   are the reason the bot works on a 32K context model. The LLM is the last 10% of the pipeline.

2. **Skip generated files aggressively.** `go.sum`, `vendor/`, lockfiles, and minified assets are noise.
   One check at file-sort time saves context budget for signal.

3. **Two-phase interaction reduces friction.** Analysis on PR paste, full review on demand. Users
   who do not want the review are not interrupted. Users who do get it immediately.

4. **Deterministic security scanning belongs in Go, not the LLM.** Auditability matters for security
   findings. Regex over the raw diff is faster, cheaper, and easier to explain when something fires.

5. **Write guards need false-positive test suites.** The boundary between "tell me about helm install"
   and "run helm install" is thin. 100+ test cases is not overkill — it is the minimum for a guard
   that sits in a production chat bot.
