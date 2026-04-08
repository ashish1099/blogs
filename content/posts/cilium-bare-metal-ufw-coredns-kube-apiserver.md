---
title: "Cilium on Bare Metal: How UFW Silently Breaks CoreDNS and kube-apiserver Connectivity"
date: 2026-03-19
tags: ["kubernetes", "cilium", "networking", "bare-metal", "ufw", "coredns", "debugging"]
categories: ["infrastructure", "kubernetes"]
---

## The Symptom

After standing up a Kubernetes cluster on a bare-metal node with Cilium as the CNI, CoreDNS pods were
running but completely unable to reach the kube-apiserver service IP (`10.96.0.1`). DNS resolution inside
the cluster was broken, and any pod trying to talk to the API server via the service IP timed out.

The apiserver itself was healthy — direct connections to the node's IP worked fine. The problem was
specifically with the virtual service IP routed through Cilium's BPF dataplane.

## Debugging Step 1: Cilium Picking Up the Wrong NICs

The first clue came from `cilium status` — Cilium had auto-detected all four network interfaces on the
node, including three that were administratively DOWN. With multiple interfaces detected, Cilium's BPF
maps can become inconsistent about which device to use for forwarding, leading to packets being routed
to the wrong interface or dropped silently.

Fix: set the device explicitly in the Cilium Helm values rather than relying on auto-detection.

```yaml
# In your Cilium Helm values
devices: ["eth0"]  # or whatever your single active interface is
```

This helped stabilise interface selection but did not fully resolve the connectivity issue.

## Debugging Step 2: Native Routing + BPF Host Routing

The cluster was initially configured with tunnel (VXLAN) mode. Switching to native routing with BPF
host routing eliminated an encapsulation layer and made the packet path easier to reason about:

```yaml
routingMode: native
autoDirectNodeRoutes: true
bpf:
  hostLegacyRouting: false
```

Checking `cilium monitor` output showed BPF socket LB activity with `pre-xlate-fwd` events but no
corresponding `post-xlate-fwd` events — translation was starting but packets were not completing the
forward path. This is a strong signal that something upstream of Cilium was dropping the translated
packets.

## Root Cause: UFW Default DROP Policy

The actual root cause had nothing to do with Cilium itself. UFW was installed and active on the node
with its default policies:

```
Chain INPUT (policy DROP)
Chain FORWARD (policy DROP)
```

UFW's default `DROP` on `FORWARD` means that any packet Cilium forwards between the pod CIDR, the
service CIDR, and the host is silently discarded by the kernel's netfilter layer — after Cilium has
already translated the destination IP, but before the packet can exit.

This explains the BPF `pre-xlate-fwd` without `post-xlate-fwd`: Cilium did its job, but iptables dropped
the packet on the way out.

## The Fix: UFW Rules for Kubernetes

Add explicit allow rules for the Kubernetes service CIDR, pod CIDR, and routed traffic:

```bash
# Allow traffic to/from the K8s service CIDR
ufw allow in from 10.96.0.0/12
ufw allow out to 10.96.0.0/12

# Allow traffic to/from the pod CIDR
ufw allow in from 10.244.0.0/16
ufw allow out to 10.244.0.0/16

# Allow forwarded traffic (required for Cilium native routing)
ufw route allow in on eth0
ufw route allow out on eth0
```

After applying these rules and restarting Cilium, `post-xlate-fwd` events appeared in `cilium monitor`
and CoreDNS was immediately able to reach `10.96.0.1`.

## Key Takeaways

- **UFW's FORWARD DROP is invisible to Cilium.** Cilium operates at the BPF layer and does its
  translation correctly, but kernel netfilter (which UFW manages) runs after BPF socket LB and will
  drop forwarded packets if there is no matching ACCEPT rule.
- **Auto-detect interfaces carefully on multi-NIC nodes.** Cilium picking up DOWN interfaces causes
  unpredictable BPF map state. Always set `devices` explicitly on bare-metal nodes with multiple NICs.
- **`pre-xlate-fwd` without `post-xlate-fwd` in cilium monitor means the packet was dropped after
  translation.** This is the BPF-level signal that points to an iptables/nftables policy above Cilium,
  not a Cilium bug.
- **Native routing + BPF host routing reduces the debugging surface** compared to VXLAN tunnel mode on
  bare metal — fewer moving parts means packet drops are easier to trace.
