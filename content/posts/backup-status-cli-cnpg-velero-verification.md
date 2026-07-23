---
title: "You Sure Your Backup Works? We Do, @Obmondo"
date: 2026-07-23T08:30:00+05:30
draft: false
tags: ["kubernetes", "backup", "cnpg", "postgresql", "velero", "prometheus", "go", "cli", "netbird", "sre", "kubeaid"]
author: "Ashish Jaiswal"
summary: "Building kubeaid-cli backup status: why a 404 from an L7 proxy looked exactly like a missing route, why the first summary line counted more resources than existed, and what changes when checking your backups is one command instead of a metrics query."
showToc: true
TocOpen: true
---

Everyone running Kubernetes in production has backups. Far fewer can tell you, right now,
without opening Grafana, whether last night's backup actually ran for every database and
every volume they care about.

We had the data. CNPG clusters and Velero volume backups were both being watched by an
in-cluster exporter publishing Prometheus gauges: latest backup age, oldest backup age,
maximum interval between backups, per resource. Good enough to alert on. Close to useless
when you want an answer in ten seconds.

To get that answer by hand you had to know the metric names, run three or four queries, and
mentally join gauges per resource to decide whether a given database was actually protected.
Nobody does that on a Tuesday afternoon. So it didn't get checked.

That gap is what `kubeaid-cli backup status` closes. The interesting parts of building it
were not the parts I expected.

## Reconcile on the server, not in the CLI

The first design decision was where to turn gauges into a verdict.

An early version of this command pulled the raw metric families out of the exporter and did
the reconciliation client-side: group samples by resource, find the age gauge, compare
against the RPO, decide if it counts as healthy. That was around 350 lines of gauge-joining
logic living in a CLI.

It was the wrong place for it. The rules for "is this resource backed up" belong next to the
code that knows how CNPG and Velero actually behave, and there is exactly one copy of that
knowledge: the exporter. Any second implementation drifts.

So the exporter grew a `GET /api/v1/backups` endpoint that does the join itself and returns
one evaluated status per resource, and the CLI became a thin client. Fetch, adjust the ages,
print. All 350 lines of reconciliation went away.

One subtlety survived into the API contract. The exporter measures ages at collection time,
not at request time, and it reports when each collector last ran. A consumer has to add the
elapsed time since collection or it will quietly under-report every age by however stale the
collector is. That is a real trap, and the reason the report leads with a freshness line
instead of burying it.

## The 404 that wasn't ours

First live run against a real cluster:

```
Error from server (NotFound): the server could not find the requested resource
```

That is precisely what you see when an application does not serve the path you asked for. So
I went looking for a missing route.

Was the deployed image older than I thought? The pod's `imageID` digest matched the published
image byte for byte. Was the route compiled in? Running `strings` on the binary found both the
path and the handler symbol. Was the Service pointing at the wrong pod? The EndpointSlice had
exactly one address, ready and serving, with a `targetRef` uid matching the running pod.

Every hop between kubectl and the container checked out. Which meant the 404 was not coming
from the application at all. Something in the middle was answering.

KubeAid reaches managed clusters through NetBird's `ClusterProxy`, an L7 proxy sitting in
front of kube-apiserver. It forwards the standard REST verbs perfectly well, which is why
everything else about the cluster works. What it does not implement is the API server's
service proxy subresource:

```
/api/v1/namespaces/<ns>/services/<scheme:name:port>/proxy/<path>
```

Ask for that through the proxy and its own router, not the API server, returns a plain 404.
client-go renders that identically to a genuine API server 404. From the error text there is
no way to tell "your app has no such route" from "this path never reached your app".

The fix was to stop using the service proxy. `pods/portforward` negotiates an upgraded
SPDY/WebSocket stream rather than making an HTTP proxy hop, and streams are exactly what a
proxy like this is built to carry. Proof took thirty seconds: `kubectl port-forward` to the
same pod through the same proxy, then curl, and the JSON came back immediately.

So the command now opens the `pods/portforward` subresource with client-go directly, the same
subresource `kubectl port-forward` uses, forwards an ephemeral local port, issues the GET
against localhost and tears the tunnel down. No kubectl binary is spawned.

The lesson I would want back at hour one: when a 404 is ambiguous between "the app lacks the
route" and "the transport lacks support for this path", test the transport by itself. I spent
hours proving the application was correct when a single port-forward would have moved the
suspicion to the right layer immediately.

## The summary line that counted more than existed

With connectivity solved, the first fleet-wide run produced a summary along the lines of:

```
107 exceeds_rpo, 86 no_backup, 40 collector_error
```

The individual row statuses were right. The arithmetic was not.

A CNPG cluster does not produce one row in this report. It produces two, because it has two
independent backup streams: a logical dump and a WAL archive. They fail independently and
both matter, so both get a row.

The summary was tallying rows. A cluster with no logical backup and a broken WAL check was
counted once under `no_backup` and again under `collector_error`. Every cluster with two
unhealthy streams inflated the totals twice.

What made it hard to notice is that the line never printed a denominator. There was no
resource total to check the parts against, so numbers that summed to more resources than the
cluster contained looked perfectly plausible.

The fix has two halves. Count resources rather than rows, folding each resource's streams
into its worst status, so a cluster in trouble is counted once. And print the total:

```
4 resources: 2 healthy, 1 exceeds_rpo, 1 collector_error
```

The table still lists every stream, so nothing is hidden. Only the tally is deduplicated.

The general point is that a summary line is a claim about the world, and a claim without a
denominator cannot be checked by the person reading it. If I had printed the total on day
one, the double-count would have been obvious the first time I ran it.

## Naming that points at the thing to go fix

An early version of the table produced rows like this:

```
demo   demo-pgsql   cnpg_cluster   logical   none   collector_error (cronjob_not_found)
```

Everything there is accurate. It is still not actionable unless you already know that CNPG's
logical backup is taken by a Kubernetes CronJob, and that WAL archiving is handled by the
barman-cloud plugin declared in the Cluster CR. Without that context you know something is
broken but not what object to open.

The exporter reports the stream, and for Velero it also reports the backup method
(`PodVolumeBackup`, `CSISnapshot`). For CNPG it reports no method at all, because from its
point of view there is nothing to report.

The split that made the table useful was to treat those as two different questions. `STREAM`
answers what is being backed up: `logical`, `wal`, `volume`. `METHOD` answers what takes it:
`CronJob`, `Barman`, `PodVolumeBackup`, `CSISnapshot`. For CNPG the method is derived from
the stream, since the mapping is fixed. A method the exporter does report always wins over
the derived one, so this never overrides real data.

Now a failing row names the object to go look at.

The other readability fix was durations. Kubernetes' `HumanDuration` renders anything under
three hours as raw minutes, so a backup taken just under three hours ago showed as `177m`.
Nobody reads that as a clock. Ages now render as `2h 57m` and `3d 2h`.

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

A few choices worth naming.

The table is plain aligned columns rather than a bordered box. An earlier version drew a
rounded border with dividers grouping each resource's streams, and it looked good. It also
broke `grep`. Since every row carries its namespace, `backup status | grep -v healthy` leaves
each failing row complete and actionable, which matters more than the border.

`LATEST AGE` distinguishes two things that both look like nothing. `none` means the exporter
published an age of exactly zero, which is the shared sentinel for "no backup exists". A dash
means no series was published at all, so there is nothing to measure yet. Collapsing those
two into one symbol would hide a real difference.

Operator errors print above the table because they change how much you should trust
everything below. If Velero cannot list its bucket, every Velero row underneath is a guess.

The command exits `0` whenever it can produce a report, however bad the news is. Non-zero
means the fetch itself failed. It is a report, not a health gate. Wiring an unhealthy status
into an exit code sounds appealing until a pipeline starts failing on a backup that was known
to be missing.

## What it actually found

The first honest run across real clusters was not comfortable reading.

One cluster had no S3 credentials configured for the CNPG collector at all, so it was falling
back to instance metadata and timing out on every check. It had been doing that silently for
a while. The metrics existed the whole time. Nothing surfaced them in a form anyone read.

Others had databases with no logical backup CronJob deployed, which is exactly the class of
problem you find out about at the worst possible moment.

None of this was caused by the new command. All of it was already true. The difference is
that it now takes one command and ten seconds to see, instead of a metrics query nobody was
going to run.

## The honest caveat

The title of this post overclaims slightly, so let me correct it.

This tells you a backup exists and how old it is. It does not tell you the backup restores.
Those are genuinely different questions, and the second one is harder, because answering it
properly means standing up the data somewhere and checking it came back intact.

Freshness verification is the floor, not the ceiling. It is worth building first because a
backup that is missing or three days stale fails the restore test too, and this catches that
class immediately and cheaply. Restore verification is the next piece of work.

## Takeaways

- Put the reconciliation logic next to the domain knowledge. A CLI that reimplements the
  rules will drift from the exporter that owns them.
- Summary lines need denominators. Without a total, wrong arithmetic looks reasonable.
- When an error is ambiguous between two layers, test the layers separately. A 404 from an L7
  proxy is indistinguishable from a 404 from your application.
- Name things after the object someone has to go open. `CronJob` and `Barman` tell you where
  to look. `logical` and `wal` do not.
- Verification that is not one command does not happen.

`kubeaid-cli backup status` shipped in v0.31.0. The CLI is at
[github.com/Obmondo/kubeaid-cli](https://github.com/Obmondo/kubeaid-cli), and the exporter it
talks to is at
[github.com/Obmondo/backup-exporter](https://github.com/Obmondo/backup-exporter).
