---
title: "Taming octocatalog-diff in CI: Exit Codes and Noise-Free Error Output"
date: 2026-03-06
tags: ["puppet", "ci", "octocatalog-diff", "bash", "devops"]
categories: ["development"]
---

octocatalog-diff is a great tool for surfacing Puppet catalog changes in pull requests,
but its default CI behaviour has two sharp edges: it exits with code 2 when diffs are
found (which most CI systems treat as failure), and its stderr is full of Ruby thread
noise and stack traces that obscure the actual compilation errors you care about. Here
is how we fixed both.

## The Exit Code Problem

octocatalog-diff uses three exit codes:

- `0` — no diffs found
- `1` — compilation error (genuine failure)
- `2` — diffs found (informational)

In a catalog-diff CI job, exit code 2 is the expected, happy-path result — it means
the tool ran successfully and found changes to review. Treating it as a build failure
meant every PR that touched Puppet code would show a red CI check, making the output
useless as a signal.

The fix in both `.gitea/workflows/catalog-diff-e2e.yaml` and
`.github/workflows/catalog-diff-e2e.yaml` is straightforward:

```bash
octocatalog-diff ... || exit_code=$?
if [ "${exit_code}" -eq 1 ]; then
  echo "Catalog compilation failed"
  exit 1
fi
# exit code 0 (no diffs) or 2 (diffs found) are both success
```

## Filtering stderr Noise

octocatalog-diff stderr includes Ruby VM thread messages, backtraces, and other runtime
chatter that swamps the actual `Error:` lines you need to diagnose a compilation
failure. We added a `filter_stderr` function to `bin/catalog-diff.sh` that:

1. Captures stderr to a temp file during the octocatalog-diff run
2. Extracts only lines matching `Error:`
3. Prints them under labelled headers tied to the branch being compiled

```bash
filter_stderr() {
  local branch="$1"
  local stderr_file="$2"
  echo "=== Errors compiling ${branch} ==="
  grep 'Error:' "${stderr_file}" || true
}
```

Full unfiltered output is preserved behind a `--debug` flag for deeper investigation.

## Branch-Aware Error Headers

When compiling two branches (base and head), errors need to be attributed to the right
one. We extract `--from` and `--to` values from the script's own argument list:

```bash
from_branch="master"
to_branch="$(git branch --show-current)"

for i in "$@"; do
  case "$i" in
    --from=*) from_branch="${i#*=}" ;;
    --to=*)   to_branch="${i#*=}" ;;
  esac
done
```

This means even when the script is called from CI with explicit branch overrides, the
error headers will always name the correct branch — no hardcoded assumptions.

## Key Takeaways

- **Match exit code semantics to the tool, not the shell convention.** Not every
  non-zero exit means failure; read the tool's documentation.
- **Own your stderr.** When wrapping a third-party tool, filtering its noise before
  surfacing errors to users is part of the integration work, not optional polish.
- **Label your output by context.** When a script processes multiple branches
  sequentially, make sure every error message says which branch it came from.
