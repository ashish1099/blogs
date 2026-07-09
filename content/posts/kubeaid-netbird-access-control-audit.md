---
title: "Who touched your cluster at 3am?"
date: 2026-07-10T01:00:00+05:30
draft: false
tags: ["kubernetes", "rbac", "netbird", "zero-trust", "gitops", "audit", "kubeaid"]
author: "Ashish Jaiswal"
summary: "Finer-grained Kubernetes access control and an audit trail that names a human — with KubeAid + NetBird, and no OIDC in your API server."
showToc: true
TocOpen: true
---

Open your cluster's audit log and grep for a `delete` on a Deployment. Whose name is next to it?

If the answer is `kubernetes-admin`, you don't have an audit trail. You have a log file.

That's the default state of most clusters we're handed. A VPN gets you *near* the cluster, a shared kubeconfig with an admin client certificate gets you *into* it, and from that moment every action is attributed to the same certificate CN. Six engineers, one name. Nothing to review, nothing to revoke, nothing to show an auditor except a shrug.

This post is about how we fix that with **KubeAid + NetBird** — and the places where we go further than the hyperscalers.

---

## The three problems, stated plainly

1. **Identity dies at the cluster edge.** You authenticate to your IdP, then to a VPN, and then you present a certificate that has nothing to do with either. The chain breaks exactly where it matters.
2. **Access lives somewhere unreviewable.** A cloud console. A Terraform module nobody wants to touch. A `kubectl create rolebinding` someone ran in 2023. No diff, no PR, no revert.
3. **Everyone is an admin, because scoping is painful.** Hand-writing namespace-scoped RBAC is tedious, so the pragmatic move is `cluster-admin` for the ops group, forever. Standing privilege becomes the shape of the org.

---

## Identity survives every hop — and we never touch the API server

Here's the part people expect to be hard.

The textbook way to get SSO identity into `kubectl` is to wire **OIDC into the kube-apiserver**: `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim`, `--oidc-groups-claim`. That means API-server flags, a restart, a control-plane the apiserver must be able to reach your IdP from, and claim-mapping you get to debug at 3am. Per cluster. Forever. (And no, the kubelet has nothing to do with it — this is an API-server concern, which is itself a common source of confusion.)

**We do none of that.** There is no OIDC configuration anywhere on the control plane.

Instead, NetBird's Kubernetes API-server proxy (`ClusterProxy`) authenticates you by the fact that you're on the mesh, and then rewrites your request to the API server using plain Kubernetes **impersonation**:

```
Keycloak (SSO)  →  NetBird user + groups  →  ClusterProxy  →  kube-apiserver
                                              Impersonate-User
                                              Impersonate-Group
```

`netbird kubernetes write-kubeconfig <cluster>` writes a kubeconfig containing **no user credential at all** — it just points at the proxy. Your credential *is* your mesh identity.

Which means the API server sees *you*. And so does the audit log:

```json
{
  "verb": "delete",
  "objectRef": { "resource": "pods", "namespace": "monitoring", "name": "prometheus-0" },
  "user":             { "username": "system:serviceaccount:netbird:clusterproxy" },
  "impersonatedUser": { "username": "alice@acme.com",
                        "groups": ["operation-lvl2", "oncall"] }
}
```

There it is. The human who did it, and **the group that authorised them**, on one line. Not `kubernetes-admin`. No shared kubeconfig to rotate when someone leaves — you remove them from a group.

A second, quieter benefit: **revocation is immediate.** There is no certificate to wait out and no token to blocklist. Identity is resolved per request, so the moment a binding disappears or someone leaves a group, the very next `kubectl` call is denied.

---

## Access control lives in Git. Not a UI. Not a Terraform hack.

Here is the entire access policy for a cluster:

```yaml
# kubeaid-config/<customer>/k8s/<cluster>/argocd-apps/values-netbird-operator.yaml
clusterProxy:
  enabled: true
  clusterName: prod-eu-1
  rbac:
    - group: Owners
      clusterRole: cluster-admin

    - group: product
      clusterRole: view
      namespaces: [webshop]              # read-only, one namespace

    - group: operation-lvl1
      clusterRole: view                  # read-only, cluster-wide

    - group: operation-lvl2
      clusterRole: cluster-admin
      namespaces: [monitoring, harbor]   # admin, but ONLY here

    - group: operation-lvl3
      clusterRole: cluster-admin
```

That's it. A `namespaces:` list turns a `ClusterRoleBinding` into per-namespace `RoleBinding`s. Omit it and it's cluster-wide. The chart renders `netbird-<group>-<role>` bindings; ArgoCD syncs them.

What this gives you for free:

- **A pull request is an access request.** Granting `operation-lvl2` admin on `harbor` is a diff, with a reviewer and a timestamp.
- **`git revert` is the off-switch** — not a console click that leaves no trace.
- **`git log` answers "who has had what, since when?"** — the question an auditor always asks and a UI can never answer.
- **It reconciles.** Someone hand-edits a RoleBinding in the cluster? ArgoCD puts it back.

No click-ops. No Terraform state that disagrees with reality. Who-can-do-what sits in the same repo, reviewed by the same people, as the workloads themselves.

---

## One connection. The cluster **and** everything behind it. No reverse proxy.

Most teams end up with two access paths: a VPN or bastion for the API server, and an ingress + reverse proxy (plus another auth layer, plus another set of certificates) to reach ArgoCD, Grafana, Harbor, or the internal Traefik.

With NetBird you get both over the same mesh:

- the **ClusterProxy** peer exposes the kube-API;
- a **NetworkRouter** + **NetworkResource** exposes internal Services (e.g. `traefik-internal`) directly onto the mesh, published under a DNS zone.

So `kubectl` and `https://argocd.internal…` travel the same authenticated, encrypted path, gated by the same NetBird groups. No public ingress for internal tooling. No bastion host to patch. No reverse proxy terminating TLS and inventing its own idea of who you are.

> *Why "no reverse proxy" is a bigger deal than it sounds — and what quietly breaks when you have one — deserves its own post. We'll write it.*

---

## The audit trail, and what actually ships

Audit logging is **on by default**. `kubeaid-cli` sets `enableAuditLogging: true` and configures the API server for you:

| flag | default |
|---|---|
| `audit-policy-file` | `/etc/kubernetes/audit-policy.yaml` |
| `audit-log-path` | `/var/log/kubernetes/audit/audit.log` |
| `audit-log-maxage` | `10` (days) |
| `audit-log-maxbackup` | `1` |
| `audit-log-maxsize` | `100` (MB) |

The shipped policy is deliberately boring, which is what you want:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  - level: Metadata          # who, when, which resource, which verb — no bodies
    omitStages: ["RequestReceived"]
```

`Metadata` on every request. You capture the *who / what / when / which* of every API call — including `impersonatedUser` — without hauling around request and response bodies, which is how audit logs become a storage bill and a secret-leak vector.

**The logs are node-local by default, and that's on purpose.** KubeAid mounts the audit directory onto the control-plane host and writes there. Nothing leaves your infrastructure unless you say so. No phone-home, no vendor endpoint, no "telemetry" toggle.

**You configure log shipping.** KubeAid captures; where the logs go is your call, and the pieces are already in the chart catalogue:

- **fluent-bit** or the **OpenTelemetry Operator** to collect — point it at `/var/log/kubernetes/audit/`
- **Loki**, **OpenObserve**, or **Graylog** to store
- **k8s-event-logger** for Kubernetes Events
- **kube-prometheus** + **grafana-operator** for the metrics half

Self-hosted, on your infra, no egress. *(Docs for wiring this end-to-end are coming.)*

**Keycloak needs no exporter either — and no webhook.** This one surprises people. A realm's `eventsEnabled` / `adminEventsEnabled` flags gate **database storage only**. The `jboss-logging` event listener that every realm gets by default **already receives every login and admin event regardless of those flags**. It isn't missing; it's muted. Two flags un-mute it as structured JSON on stdout:

```
--spi-events-listener-jboss-logging-success-level=info
--log-console-output=json
```

No SPI. No custom Keycloak image. No version-lockstep upgrade treadmill. (The popular webhook SPI, `p2-inc/keycloak-events`, is **Elastic License 2.0** — it forbids offering the software as a hosted or managed service. A non-starter for anyone running clusters on behalf of customers, and incompatible with an AGPL codebase. We read the `COPYING` file so you don't have to.)

Once those events land in the same store as your audit log, the picture closes:

```
Keycloak event   →  alice@acme.com authenticated            (03:11)
NetBird          →  peer alice-laptop connected; groups: [oncall]
NetBird          →  netbird kubernetes list  →  requested prod-eu-1
kube audit log   →  impersonatedUser=alice@acme.com  verb=create  pods/exec  ns=monitoring  (03:14)
```

Four systems, one human, one continuous story — from "someone typed a password" to "someone opened a shell in `monitoring`". None of it required a SaaS vendor, and none of it required touching the API server's flags.

---

## What it costs

Your **NetBird cluster** — three control-plane nodes on Hetzner, managed by Obmondo. This is the cluster that runs the mesh and your identity provider; your workload clusters are separate.

| item | qty | € / month |
|---|---|---|
| Control-plane server (~€19.49 each) | 3 | 58.47 |
| Load Balancer (LB11) | 1 | 7.49 |
| Floating IPv4 (failover) | 1 | 3.00 |
| **Hetzner subtotal** | | **68.96** |
| Obmondo *Basic* — €29 per server | 3 | 87.00 |
| **Total** | | **≈ €156** |

**Under €160 a month** for SSO-backed, group-scoped, fully-audited access to your clusters *and* your internal services.

And look at what those three nodes are actually running. Not just a control plane: **NetBird's Management server and your own Keycloak** — the identity provider backing every hop in this post. Your SSO isn't a line item on this bill, because there is no identity vendor on it. No per-seat tax, no per-cluster PAM licence, no egress to anyone's SaaS. Keycloak is just another workload on a cluster you already pay for.

*All figures ex-VAT, correct as of July 2026 at new-order pricing. Hetzner adjusted cloud prices twice in 2026 (1 April and 15 June); existing instances keep their previous rate unless rescaled, so an established fleet bills lower than a fresh order. Obmondo's per-server price drops with volume.*

---

## Where most people stop. And where we're going.

Everything above ships today. It is also, honestly, table stakes for anyone who thinks about this for a week.

Here's the part almost nobody does — and to be clear, **this is our roadmap, not something you can `helm install` this afternoon**:

> **Even scoped, standing privilege is still standing privilege.**

Suppose `operation-lvl2` permanently holds `cluster-admin` on `monitoring` and `harbor`. That RBAC is genuinely good: two namespaces, not the whole cluster.

Now phish one engineer's laptop. Not during an incident — at 3pm on a Tuesday, when nothing is wrong.

The attacker inherits her session, and with it, admin on `monitoring` and `harbor`. They don't have to wait for anything. They don't have to do anything loud. And since `exec` in a namespace hands you the ServiceAccount of every pod in it, "admin on `monitoring`" quietly means "whatever Prometheus's ServiceAccount can reach."

The scoping shrank the **blast radius**. It did nothing about the **window** — which is open every hour of every day, including all the hours nobody is looking.

So we're building the next step: **write access only while something is on fire.**

- On-call holds **no standing write anywhere.** Their permanent grant is read-only over nodes, events, PVs and metrics — enough to see *what* is broken and *where*, and nothing more.
- A **critical alert firing in namespace X** makes namespace X *eligible*.
- The on-call engineer then elevates **deliberately**, with a reason, and an in-cluster agent creates a **time-bound RoleBinding** naming *that human*, in *that namespace*, referencing *that alert*.
- It expires. On a TTL, not on someone's good intentions.

Now run the same attack against that model. Same laptop, same 3pm Tuesday.

Our engineer is on-call, so she holds… read-only sight of nodes and events. No pods. No logs. No secrets. No write, anywhere, on any cluster. There is no RoleBinding, because nothing is on fire.

To get write, the attacker would have to wait for a critical alert to fire, and then **deliberately elevate** — an act that names a human, records a reason, posts to Slack, and expires on a timer. Meanwhile her NetBird session dies after eight hours regardless, forcing a fresh trip through Keycloak and whatever MFA it demands.

> Standing privilege leaves the attacker a window that is **always open**. JIT leaves them one that is **usually shut, and loud to open**.

You don't get to wander the cluster. **We don't jaywalk.** You get a scoped, expiring, reasoned grant to fix the thing that is actually burning — and the grant tells a future auditor exactly why it existed.

Two design decisions we care about:

- **The grant never goes through Git.** Git holds the *capability* — the narrow role, the namespace allowlist, reviewed in a PR. The *grant* is an ephemeral in-cluster object with a TTL. A thirty-minute RoleBinding is no more "configuration" than a Job is, and nobody should be auto-merging one into a customer's repo at 3am.
- **The alert never authorises anything by itself.** It defines *eligibility*; a human, already on-call, performs the *activation*. Telemetry is evidence, never an authorisation source. (Ask yourself who can `POST` to your Alertmanager.)

### And seeing what actually happened

The audit log tells you a shell was opened. It cannot tell you what was typed inside it — that's the trade you make for cheap, metadata-only logging.

So the other thing landing in KubeAid is **Tetragon**: eBPF process- and file-level auditing, from the same Cilium project we already ship on every cluster. Two policies do the work:

- **`execve` monitoring** — every command run, enriched with pod, namespace and workload.
- **A file-access policy on `/var/run/secrets/kubernetes.io/serviceaccount/token`** — which catches the single nastiest thing a shell can do, and which nothing in a stock cluster sees today.

It is not a terminal replay, and it's better than that sounds. It answers *what ran*, joined to the audit log's *who ran it*, on `(namespace, pod, time window)` — and the JIT grant's TTL conveniently bounds that window.

---

## How this compares

|  | VPN + shared kubeconfig | AKS + Entra PIM | GCP PAM | Teleport | **KubeAid + NetBird** |
|---|---|---|---|---|---|
| Audit log names the human | ❌ `kubernetes-admin` | ✅ `user.username` | ✅ `user.username` | ✅ `impersonatedUser` | ✅ `impersonatedUser` |
| OIDC on the API server | — | managed by Azure | managed by Google | not required | **not required** (you self-manage the control plane) |
| Where access is defined | kubeconfig, ad-hoc | Entra UI + static RBAC | GCP IAM | Teleport roles | **Git → ArgoCD** |
| Reviewable as a PR | ❌ | ❌ | ❌ | partial | ✅ |
| Granularity | cluster | cluster (via group) | GCP resource | namespace | **namespace** |
| JIT elevation | ❌ | ✅ *membership* | ✅ IAM grant | ✅ access request | 🔜 *binding* |
| Reaches internal services too | ❌ bastion/proxy | ❌ | ❌ | ✅ | ✅ same mesh |
| Session recording | ❌ | ❌ | ❌ | ✅ full replay | 🔜 eBPF exec + file auditing |
| Self-hosted, no vendor egress | ✅ | ❌ | ❌ | partial | ✅ |

The interesting row is **JIT**.

Microsoft and Google both JIT the **identity**, never the **binding**. Activating an Entra PIM role puts you into a group; AKS maps that group to a RoleBinding that was static and pre-created all along. GKE + GCP PAM works the same way. Which means: if you want *namespace*-granular JIT on those platforms, you need **one group per namespace**, pre-bound, forever. That is why neither vendor markets namespace-scoped JIT — they stop at the cluster boundary.

We intend to invert it. Membership stays coarse (`oncall`); the **binding** is what gets created and destroyed. Namespace granularity comes free, with no group sprawl.

Teleport is the honest comparable — architecturally our twin, also using impersonation for Kubernetes access — and it's ahead of us on **session recording** (a full, replayable transcript of everything typed in an `exec` session) and per-session MFA. Our answer there is eBPF auditing rather than stream capture: *what ran*, not *what was typed*. If a replayable shell transcript is a hard compliance requirement, buy Teleport. If you want your access policy to live in the same Git repo as your workloads, on your own infrastructure, with nothing leaving your network, keep reading our docs.

---

## What we're not going to pretend

You'd rather hear this from us than from your pentester:

- **`exec` is namespace-root.** Anyone with `pods/exec` in a namespace can read the ServiceAccount token of every pod in it — `/var/run/secrets/kubernetes.io/serviceaccount/token` — and then act as those identities, plus read every Secret those pods mount. So a role that says "no `secrets`" doesn't mean "cannot obtain secrets". It means the **namespace allowlist**, not the role, is the real privilege boundary. Never put `kube-system`, `argocd`, or an operator's namespace on it: `exec` in `argocd` *is* cluster-admin.
- **The proxy's ServiceAccount is tier-0.** ClusterProxy works by holding `impersonate` on `users` and `groups`, cluster-wide, with no `resourceNames` pinning. That grant is exactly what lets it stamp `alice@acme.com` onto a request — and it means anyone who can read that ServiceAccount's token can become anyone, `Owners` included. This is inherent to impersonating proxies, not specific to us: Teleport's Kubernetes agent needs the same grant, and asks for `serviceaccounts` on top, which we don't. Two consequences. The proxy's namespace must never appear in a `namespaces:` allowlist — by the rule above, `exec` there *is* cluster-admin. And the grant is worth pinning with `resourceNames` to a known set of groups, so that `system:masters` — which bypasses RBAC entirely — is not among the identities it can mint.
- **`level: Metadata` records that a shell was opened, not what was typed.** You get `create pods/exec by alice@acme.com at 03:14`. You do not get the transcript — that's the trade for cheap, low-risk audit logs. Tetragon closes most of that gap, but not all of it: shell **builtins** (`cd`, `echo $VAR`) never fork a process, so even eBPF `execve` monitoring cannot see them. The file-access policy catches the token read regardless of which binary does it, which is why you want both.
- **You have to configure log shipping.** Capture is solved out of the box; delivery is a decision you make. A default cluster holds ~10 days of audit history on a control-plane disk, and Keycloak's structured JSON dies with the pod until you point a collector at it.
- **No step-up MFA at the moment of elevation.** Authentication itself is bounded — a NetBird session expires after **8 hours**, so you re-authenticate through Keycloak, and whatever MFA policy it enforces, at least that often. But there is no second factor demanded at the instant you reach for a privileged action. That's on the list.

---

## The shape of it

Identity from Keycloak. Transport and group membership from NetBird. Authorisation from Kubernetes RBAC, defined in Git, reconciled by ArgoCD. Audit from the API server, shipped by collectors you already run, into a store you already own.

No OIDC flags on your control plane. No vendor in the middle. No console holding the truth.

And when someone asks *"who touched the cluster at 3am, and who said they could?"* — the answer is a name, a group, a reason, and a pull request.

---

*KubeAid is Obmondo's open-source Kubernetes platform. Everything above is configuration, not a product tier.*
