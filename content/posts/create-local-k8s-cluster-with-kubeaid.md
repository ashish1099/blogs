---
title: "Creating a Local Kubernetes Cluster with KubeAid"
date: 2026-02-10T10:00:00+02:00
draft: true
tags: ["kubernetes", "kubeaid", "devops", "automation"]
author: "Ashish Jaiswal"
summary: "A step-by-step guide to spinning up a local Kubernetes cluster using kubeaid-cli — from installing the CLI to configuring your cluster with KubeAid and ArgoCD."
showToc: true
TocOpen: true
---

## Why KubeAid?

Setting up a Kubernetes cluster locally is a common need — whether you're developing, testing, or just learning. But getting from zero to a fully configured cluster with GitOps tooling like ArgoCD can involve a lot of manual wiring.

[KubeAid](https://github.com/Obmondo/kubeaid) is an opinionated Kubernetes management framework that bundles ArgoCD-based GitOps workflows, sensible defaults, and a CLI tool (`kubeaid-cli`) that automates the tedious parts. Instead of stitching together tools yourself, you generate a config, point it at your Git repos, and let KubeAid handle the rest.

This guide walks you through setting up a local Kubernetes cluster using `kubeaid-cli` — from installing the CLI to configuring your cluster.

## Prerequisites

- A Linux machine (or VM) with internet access
- Git installed and configured
- A [GitHub](https://github.com) account
- A fork of the [KubeAid](https://github.com/Obmondo/kubeaid) repo
- A fork of the [KubeAid config](https://github.com/Obmondo/kubeaid-config) repo
- `kubectl` installed

## Step 1: Install kubeaid-cli

Download and install the latest release of `kubeaid-cli`:

```bash
# Download the latest release
curl -fsSL https://github.com/Obmondo/kubeaid/releases/latest/download/kubeaid-cli-linux-amd64.tar.gz -o kubeaid-cli.tar.gz

# Extract and install
tar -xzf kubeaid-cli.tar.gz
sudo mv kubeaid-cli /usr/local/bin/

# Verify the installation
kubeaid-cli version
```

## Step 2: Generate the Config File

KubeAid uses a config file to define your cluster setup. The CLI can generate a starter config for a local cluster:

```bash
kubeaid-cli config generate local
```

This creates a `general.yaml` file with sensible defaults for a local setup. You'll customize this in a later step.

## Step 3: Generate SSH Keys

KubeAid uses SSH to authenticate with your Git repositories — it only supports SSH-based Git auth. Generate a dedicated key pair for this:

```bash
ssh-keygen -t ed25519 -C "kubeaid" -f ~/.ssh/kubeaid
```

Add the public key to your GitHub account:

1. Copy the public key:

```bash
cat ~/.ssh/kubeaid.pub
```

2. Go to **GitHub** → **Settings** → **SSH and GPG keys** → **New SSH key**
3. Paste the key and save

Make sure your SSH config uses this key for GitHub:

```bash
cat >> ~/.ssh/config <<EOF
Host github.com
  IdentityFile ~/.ssh/kubeaid
  IdentitiesOnly yes
EOF
```

## Step 4: Configure general.yaml

Open the generated `general.yaml` and update it with your details. Here's what the key fields look like:

```yaml
git:
  # SSH URL of your kubeaid-config fork
  url: git@github.com:<your-username>/kubeaid-config.git
  branch: main

forkURLs:
  # SSH URL of your kubeaid fork
  kubeaid: git@github.com:<your-username>/kubeaid.git

cluster:
  name: local
  # The Kubernetes provider for local setup
  provider: kind
```

Replace `<your-username>` with your GitHub username.

Key things to note:

- **git.url** — Points to your fork of the kubeaid-config repo. This is where your cluster's desired state lives.
- **forkURLs.kubeaid** — Points to your fork of the kubeaid repo. KubeAid pulls Helm charts and app definitions from here.
- **cluster.name** — A name for your local cluster.
- **cluster.provider** — The local Kubernetes provider to use (e.g., `kind`).

<!-- TODO: Add remaining steps (cluster creation, ArgoCD setup, verification) -->

---

*If you spot any errors or have suggestions, hit the "Suggest Changes" link above. Find me on [GitHub](https://github.com/ashish1099) or [LinkedIn](https://linkedin.com/in/ashish1099).*
