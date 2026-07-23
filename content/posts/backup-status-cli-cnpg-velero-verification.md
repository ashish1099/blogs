---
title: "You Sure Your Backup Works? We Do, @Obmondo"
date: 2026-07-23T08:30:00+05:30
draft: false
tags: ["kubernetes", "backup", "cnpg", "postgresql", "velero", "prometheus", "go", "cli", "netbird", "sre", "kubeaid"]
author: "Ashish Jaiswal"
summary: "kubeaid-cli backup status reports CNPG and Velero backup health in one command. The design rationale behind it, and four traps worth knowing if you build something similar: proxy-swallowed subresources, double-counted summaries, stream naming, and duration formatting."
showToc: true
TocOpen: true
---

Everyone running Kubernetes in production has backups. Far fewer can tell you, right now,
without opening Grafana, whether last night's backup actually ran for every database and
every volume they care about.

The data usually exists. An in-cluster exporter watches CNPG clusters and Velero volume
backups and publishes Prometheus gauges: latest backup age, oldest backup age, maximum
interval between backups, per resource. That is good enough to alert on and close to useless
when you want an answer in ten seconds.

Getting that answer by hand means knowing the metric names, running three or four queries,
and mentally joining gauges per resource to decide whether a given database is protected.
Nobody does that on a Tuesday afternoon, so it doesn't get checked.

`kubeaid-cli backup status` makes it one command. What follows is why it is built the way it
is, and four traps in this problem space that are worth knowing before you hit them.

## Put the verdict where the domain knowledge lives

The rules for "is this resource backed up" belong next to the code that knows how CNPG and
Velero actually behave. There is exactly one copy of that knowledge, and it is the exporter.

So the exporter serves `GET /api/v1/backups`, which does the gauge join itself and returns one
evaluated status per resource. The CLI fetches, adjusts ages, and prints. Roughly 350 lines of
grouping and RPO comparison stay in one place instead of being reimplemented client-side,
where they would drift from the exporter that owns them the first time either changed.

One subtlety leaks into the API contract regardless. The exporter measures ages at collection
time, not at request time, and reports when each collector last ran. A consumer has to add the
elapsed time since collection or it will under-report every age by however stale the collector
is. A twelve-hour-old backup read through a three-hour-old collection looks nine hours old,
which is well inside most RPOs. That is why the report leads with a freshness line rather than
burying it.

## An L7 proxy can swallow a subresource and look like your app

KubeAid reaches managed clusters through NetBird's `ClusterProxy`, an L7 proxy in front of
kube-apiserver. It forwards the standard REST verbs perfectly well, which is why everything
else about the cluster works normally.

What it does not implement is the API server's service proxy subresource:

```
/api/v1/namespaces/<ns>/services/<scheme:name:port>/proxy/<path>
```

Ask for that path through the proxy, and the proxy's own router answers, not the API server:

```
Error from server (NotFound): the server could not find the requested resource
```

client-go renders that identically to a genuine API server 404. From the error text there is
no way to distinguish "your application does not serve this route" from "this request never
reached your application". Every layer you would normally suspect looks healthy, because every
layer is healthy: the image digest matches, the route is compiled into the binary, the
EndpointSlice has one ready address pointing at the right pod.

The command therefore fetches over `pods/portforward` instead, opening the subresource with
client-go directly rather than spawning a kubectl binary. That negotiates an upgraded
SPDY/WebSocket stream rather than making an HTTP proxy hop, and streams are what a proxy like
this is built to carry. It is the same subresource `kubectl port-forward` uses, which is the
practical tell: if `kubectl port-forward` works against a cluster, this transport works too.

The general form of the trap is worth holding on to. When an error is ambiguous between two
layers, test the layers separately before investigating either one. A port-forward and a curl
settle in thirty seconds a question that reading application code cannot answer at all.

## A summary line needs a denominator

A CNPG cluster does not produce one row in a backup report. It produces two, because it has
two independent backup streams: a logical dump and a WAL archive. They fail independently and
both matter, so both get a row.

That makes the obvious summary implementation wrong. Tally the rows by status, and a cluster
with no logical backup and a broken WAL check is counted once under `no_backup` and again
under `collector_error`. Every resource with multiple unhealthy streams inflates the totals
once per stream.

What makes this hard to catch is a missing denominator. A line that reads
`107 exceeds_rpo, 86 no_backup, 40 collector_error` gives the reader nothing to check the
parts against, so a set of numbers summing to more resources than the cluster contains looks
entirely plausible.

Both halves matter in the fix. Count resources rather than rows, folding each resource's
streams into its worst status so a cluster in trouble is counted once. And print the total:

```
4 resources: 2 healthy, 1 exceeds_rpo, 1 collector_error
```

The table still lists every stream, so nothing is hidden. Only the tally is deduplicated. A
summary line is a claim about the world, and a claim without a denominator cannot be checked
by the person reading it.

## Name things after the object to go open

Consider a row that says stream `logical`, status `collector_error (cronjob_not_found)`.
Accurate, and not actionable unless you already know that CNPG's logical backup is taken by a
Kubernetes CronJob and that WAL archiving is handled by the barman-cloud plugin declared in
the Cluster CR. Without that, you know something is broken but not what object to open.

Two different questions are hiding in one column, so the table asks them separately. `STREAM`
answers what is being backed up: `logical`, `wal`, `volume`. `METHOD` answers what takes it:
`CronJob`, `Barman`, `PodVolumeBackup`, `CSISnapshot`.

Velero reports its own method. CNPG reports none, because from its point of view there is
nothing to report, so the method is derived from the stream where that mapping is fixed. A
method the exporter does report always wins over the derived one, so this never overrides real
data, and an unrecognised stream gets no method rather than a guess.

## Formats people can read at a glance

Kubernetes' `HumanDuration` renders anything under three hours as raw minutes, so a backup
taken just under three hours ago reads `177m`. Nobody parses that as a clock. Ages here render
as `2h 57m` and `3d 2h`.

`LATEST AGE` also distinguishes two things that both look like nothing. `none` means the
exporter published an age of exactly zero, the shared sentinel for "no backup exists". A dash
means no series was published at all, so there is nothing to measure yet. Collapsing those
into one symbol hides a real difference between a backup that is missing and a check that has
not run.

## What it looks like

```
collected 2h 57m ago: cnpg | velero

Operator errors:
  cnpg: s3_list_failed

NAMESPACE    RESOURCE       TYPE           STREAM    METHOD            LATEST AGE   STATUS
demo         demo-pgsql     cnpg_cluster   logical   CronJob           none         collector_error (cronjob_not_found)
demo         demo-pgsql     cnpg_cluster   wal       Barman            4h 9m        healthy
demo         demo-uploads   pvc            volume    PodVolumeBackup   14h 57m      healthy
monitoring   obs-postgres   cnpg_cluster   logical   CronJob           3d 2h        exceeds_rpo
monitoring   prom-data      pvc            volume    CSISnapshot       14h 57m      healthy
4 resources: 2 healthy, 1 exceeds_rpo, 1 collector_error
```

The table is plain aligned columns rather than a bordered box, because a box breaks `grep`.
Every row carries its namespace, so `backup status | grep -v healthy` leaves each failing row
complete and actionable, which matters more than the border does.

Operator errors print above the table because they change how much you should trust everything
below. If Velero cannot list its bucket, every Velero row underneath it is a guess.

The command exits `0` whenever it can produce a report, however bad the news is. A non-zero
exit means the fetch itself failed. This is a report rather than a health gate, and wiring an
unhealthy status into an exit code sounds appealing right up until a pipeline starts failing
on a backup everyone already knew was missing.

## What surfaces once you can see it

Running this against real clusters turns up the kind of thing that hides well in metrics
nobody queries. A CNPG collector with no S3 credentials configured, falling back to instance
metadata and timing out on every check. Databases with no logical backup CronJob deployed at
all.

None of that is created by a reporting command. It is already true. The difference is that
seeing it costs one command and ten seconds instead of a metrics query nobody was going to
run.

## The honest caveat

The title overclaims, so let me correct it.

This tells you a backup exists and how old it is. It does not tell you the backup restores.
Those are different questions, and the second is harder, because answering it properly means
standing the data up somewhere and checking it came back intact.

Freshness verification is the floor rather than the ceiling. It is worth building first
because anything missing or three days stale fails the restore test too, and this catches that
class immediately and cheaply. Restore verification is the next piece of work.

## Takeaways

- Put reconciliation logic next to the domain knowledge. A CLI that reimplements the rules
  will drift from the exporter that owns them.
- Summary lines need denominators. Without a total, wrong arithmetic looks reasonable.
- When an error is ambiguous between two layers, test the layers separately. A 404 from an L7
  proxy is indistinguishable from a 404 from your application.
- Name things after the object someone has to go open. `CronJob` and `Barman` tell you where
  to look; `logical` and `wal` do not.
- Verification that is not one command does not happen.

`kubeaid-cli backup status` shipped in v0.31.0. The CLI is at
[github.com/Obmondo/kubeaid-cli](https://github.com/Obmondo/kubeaid-cli), and the exporter it
talks to is at
[github.com/Obmondo/backup-exporter](https://github.com/Obmondo/backup-exporter).
