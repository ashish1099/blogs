---
title: "Obmondo Code: An AI-Powered SRE Alert Diagnosis CLI"
date: 2026-04-08T09:00:00+05:30
draft: true
tags: ["go", "tui", "llm", "sre", "alerting", "bubbletea", "vllm", "qwen", "kubernetes", "ssh", "devtools"]
author: "Ashish Jaiswal"
summary: "A walkthrough of Obmondo Code, an SRE co-pilot CLI built in Go that connects an AI agent to 290+ diagnostic runbooks, SSH command execution, Gitea issue parsing, and time registration — with a strict safety model baked into every layer."
showToc: true
TocOpen: true
---

On-call life has a recurring pattern: an alert fires, you open the Gitea issue, read the
certname, SSH into the host, run the same fifteen diagnostic commands you always run, copy
the output into a chat window, and ask an LLM what it means. Obmondo Code collapses that
loop into a single terminal session.

## What it is

Obmondo Code is an SRE co-pilot CLI built in Go. You paste a Gitea issue URL and it:

1. Parses the certname and alert ID from the issue body
2. Auto-connects to the target host via SSH ControlMaster
3. Extracts template variables from the issue (e.g. `service_name=logrotate.service`)
4. Presents the relevant diagnostic runbook steps in an interactive TUI
5. Runs each command with explicit user approval, collecting output
6. Sends collected output to an LLM (Qwen3-14B on internal vLLM) for analysis

It ships with 290+ diagnostic runbooks covering Linux system alerts and Kubernetes alerts.
No external API calls, no account creation, no cloud dependency — the LLM endpoint is the
internal Obmondo vLLM instance at `ai.obmondo.com:8000`.

---

## Architecture

The project is a single Go binary built on two main layers: a Charm TUI and an LLM agent loop.

```
code (cobra CLI)
  ├── pkg/agent/       — TUI, LLM client, tool registry, mode enforcement, safety
  ├── pkg/template/    — 290+ embedded YAML diagnostic runbooks, alert ID mappings
  ├── pkg/executor/    — local, SSH, ControlMaster execution
  └── pkg/logger/      — session logs to ~/.local/share/obmondo/code/
```

### The TUI

The TUI is built with [Bubbletea](https://github.com/charmbracelet/bubbletea) and
[Lipgloss](https://github.com/charmbracelet/lipgloss). The terminal occupies alternate
screen mode with a chat-style message area, a status bar showing SSH connection state and
current mode, and a single-line input box. There is no web interface, no Electron, no
background server — just a static binary and a config file at
`~/.config/obmondo/code.yaml`.

### Four agent modes

Shift+Tab cycles through four modes, each with distinct tool permissions:

| Mode | Purpose | Allowed tools |
|---|---|---|
| AlertAid | SSH-based alert diagnosis | SSH exec, diagnostics, kubectl, alert tools |
| Timereg | Time registration | timereg login/submit only |
| PR Review | Gitea PR review with inline comments | git tools, review_pr |
| PR Merge | Merge PRs after review | merge_pr, git tools |

Mode enforcement is applied at two levels: the system prompt tells the LLM what tools it
has, and `IsToolAllowed()` in `tui_mode.go` hard-blocks tool calls that violate the current
mode before they reach the executor. The LLM cannot call SSH tools while in PR Review mode
even if it tries.

### The tool registry

Tools are registered in `tools.go` as `MakeTool` entries with a name, description, and
parameter schema. The LLM agent calls them by name. The most important tools:

- `fetch_gitea_issue` — fetches issue body, parses certname and alert ID, extracts template vars
- `get_runbook` — loads the matching diagnostic template, filters out remediation groups
- `run_diagnostic` — runs a command on local or SSH, with safety check and user approval gate
- `review_pr` / `merge_pr` — Gitea PR operations via internal API
- `git_clone` / `git_log` / `git_file` — SSH-only git operations for PR review context

### Diagnostic runbooks

Templates are YAML files embedded in the binary at compile time using `//go:embed`. Each
template covers a diagnostic category (e.g. all HAProxy alerts share one template, all
CrashLooping pod alerts share another). Alert IDs map to templates via `mappings.yaml` —
290+ explicit mappings, no wildcards.

A typical template step looks like:

```yaml
- name: "Check disk usage"
  description: "Show filesystem utilization"
  command: "df -h /var"
  priority: 0
  reviewed_by: "ashish"
  reviewed_at: "2026-01-15"
```

The `reviewed_by` / `reviewed_at` fields are set only by a human who has personally run
the command on a real host. If a command is modified, these fields are cleared — the review
is bound to the exact command string.

Steps at `priority: 0` are shown by default. Steps at `priority: 10` (advanced) are hidden
until the user presses `+` to reveal them. Steps in a group named `"Remediation"` are never
shown or executed — Code is a read-only diagnostic tool.

---

## The safety model

This is the part that took the most thought. When you give an LLM agent SSH access to
production hosts, the safety model is not optional.

### Five layers

**Layer 1: Destructive command blocklist.** Forty-plus patterns are hard-blocked at the
executor level regardless of user approval:

```
rm, rmdir, unlink, delete, drop, truncate, kill, reboot, shutdown,
kubectl delete/apply/patch/edit/replace/scale/cordon/drain,
helm delete/uninstall/upgrade/install,
systemctl stop/restart/disable/enable,
docker rm/stop/kill/rmi,
git push --force, --no-gpg-sign, --no-verify,
nc, ncat, scp, rsync, nmap, ...
```

These never execute. The LLM cannot request them, and the user cannot approve them.

**Layer 2: Network access control.** `curl` and `wget` are allowed only for:

- `localhost`, `127.0.0.1`, `::1`
- RFC 1918 ranges (`10.x`, `172.16-31.x`, `192.168.x`)
- `*.obmondo.com`

Any request to an external URL is blocked. This matters because a compromised or confused
LLM cannot exfiltrate data by constructing a `curl` command to an attacker-controlled server.

**Layer 3: Mandatory user approval.** Every command — including safe ones like `df -h` —
shows a `Yes / No` selector before execution. There is no auto-approve mode and no way to
pre-approve a batch. The user sees the full rendered command before it runs.

**Layer 4: SSH gate.** If a certname is extracted from the issue but no SSH ControlMaster
socket exists for that host, all commands are blocked until the user establishes a connection
and types `connected`. The LLM cannot fabricate command output — it either has real output
or nothing.

**Layer 5: Read-only posture.** The system prompt explicitly prohibits modifications. The
`get_runbook` tool strips remediation groups before returning steps to the LLM. There is no
path for Code to remediate an issue — it diagnoses and stops there.

### Why ControlMaster instead of opening SSH directly

Opening SSH from inside a Bubbletea alternate-screen session creates problems: password
prompts and GPG pinentry windows conflict with the TUI's raw terminal mode. ControlMaster
solves this by reusing an existing multiplexed socket. The user opens SSH in another
terminal, the socket exists, Code reuses it. No interactive prompts inside the TUI.

YubiKey detection is handled separately: if `SSH_AUTH_SOCK` points to a GPG agent or key
comments contain `cardno:`, Code shows a touch prompt before any git or SSH operation that
requires signing.

---

## Puppet diagnostics and the `--noop` constraint

The puppet runbooks (`linuxaid/puppet.yaml`) deserve a specific mention. Puppet diagnostics
are common in the Obmondo environment, and a naive implementation would allow `puppet agent
--test` — which triggers a real Puppet run and can modify system state.

The safety layer blocks any `puppet agent` invocation that is not explicitly `--noop`. The
allowed form is:

```bash
puppet agent --test --noop
```

Any variant without `--noop` is blocked. Similarly, custom environment flags
(`--environment staging`) are blocked — diagnostics run against the node's configured
environment only, which is the environment that produced the alert.

---

## Time registration integration

One thing that sets Code apart from a generic AI terminal is the built-in time registration.

When you fetch a Gitea issue, the start time is recorded. As you work, accumulated time is
tracked in memory. On `/timereg add` or session end, a YAML entry is written to
`~/.local/share/obmondo/code/timereg/YYYY-MM-DD.yaml`:

```yaml
date: "2026-04-08"
entries:
  - id: a1b2c3d4e5
    issue_url: https://gitea.obmondo.com/EnableIT/repo/issues/123
    repo: repo
    issue: 123
    customer: enableit
    minutes: 45
    work_done: "Diagnosed service failure on host"
    type: consult_level3
    submitted: false
```

`/timereg submit` aggregates the day's entries, shows a summary, and requires double
approval before calling `PUT /api/timereg`. The double-approval prevents accidental
submissions — you confirm once to see the full summary, again to send it.

---

## Session persistence and the `/update` workflow

Sessions auto-save every 5 minutes and on quit. Each session lives at
`~/.local/share/obmondo/code/YYYY-MM-DD_<id>/state.yaml`. Resume with `code -s <id>`.

The `/update` command is a practical necessity for a tool that evolves fast: it runs
`git pull && make build` on the cloned repo, saves the current session, and restarts the
binary — which immediately reloads the saved session. The user's conversation context,
collected diagnostic output, and SSH connection state all survive the update.

---

## LLM context management

Qwen3-14B-AWQ has a 40K token context window. With system prompt, conversation history,
and collected diagnostic output, it is easy to approach that limit during a long diagnosis
session.

Code trims the message list when approaching 35K tokens. The rule is: system prompt is
always preserved, oldest user/assistant messages are dropped first. This keeps recent
context (the commands you just ran) at the cost of very old turns from earlier in the
session.

Qwen3 outputs `<think>...</think>` blocks containing its chain-of-thought. These are
stripped before display — the user sees only the final 2–3 line analysis. The system prompt
constrains responses to errors, warnings, anomalies, and root cause — no explanations of
what commands do, no follow-up questions.

---

## Tech stack summary

| Component | Library / approach |
|---|---|
| CLI | `github.com/spf13/cobra` |
| TUI | `github.com/charmbracelet/bubbletea` + lipgloss |
| Markdown render | `github.com/charmbracelet/glamour` |
| SSH exec | `golang.org/x/crypto/ssh` via ControlMaster sockets |
| Runbooks | 290+ YAML files, `//go:embed`, `gopkg.in/yaml.v3` |
| LLM | Qwen3-14B-AWQ on internal vLLM, OpenAI-compat API |
| Timereg | Internal Obmondo API, JWT auth |
| Config | `~/.config/obmondo/code.yaml`, permissions 0600 |
| Sessions | `~/.local/share/obmondo/code/`, YAML state files |

---

## What I would do differently

A few things became clear only after building and using this for months:

**Runbook review discipline is harder than it looks.** The `reviewed_by`/`reviewed_at`
fields make review state explicit, but enforcing the auto-clear rule in practice requires
discipline every time a command is tweaked. Without that, reviewed steps silently become
unreviewed. I eventually added agent guidelines (in `AGENTS.md`) that make clearing reviews
on command changes a mandatory rule for any AI-assisted editing.

**Mode enforcement should have been day one.** The four-mode system was added after initial
development. Retrofitting it meant auditing every tool for what it should and should not
be allowed to do per mode. Starting with mode isolation as a first-class design constraint
would have been cleaner.

**The SSH gate prevents a real class of LLM errors.** Before the gate, the LLM would
occasionally generate plausible-looking diagnostic summaries when no command had actually
run — it would draw on training data about what `df -h` typically shows on a healthy system.
The gate eliminates this entirely: the LLM only analyzes real output, or it has nothing
to analyze.

---

Code is internal to Obmondo and lives at `gitea.obmondo.com/EnableIT/code`. It runs on
every SRE's laptop at Obmondo as a daily driver.
