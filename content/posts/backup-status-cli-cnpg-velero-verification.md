---
title: "You Sure Your Backup Works? We Do, @Obmondo"
date: 2026-07-23T08:30:00+05:30
draft: false
tags: ["kubernetes", "backup", "cnpg", "postgresql", "velero", "prometheus", "disaster-recovery", "cli", "sre", "kubeaid"]
author: "Ashish Jaiswal"
summary: "Backup in Kubernetes is four or five different mechanisms that each report success differently. Here is how a read-only in-cluster exporter plus one CLI command gives you a single answer for the whole cluster, including the volumes nobody ever set up a backup for."
showToc: true
TocOpen: true
---

Ask anyone running a Kubernetes cluster whether their backups work and you will get a
confident yes. Ask them to prove it for every database and every volume in the cluster,
right now, and the confidence usually turns into a Grafana tab and some scrolling.

That gap is not carelessness. It is a direct consequence of how backup works in Kubernetes.

## Backup in Kubernetes is not one thing

There is no single backup system in a Kubernetes cluster. There are usually four or five,
each covering a different layer, installed at a different time, by different people.

**Velero** handles cluster and namespace level backup, including volumes. It copies PVC data
to object storage either by streaming the filesystem (`PodVolumeBackup`, using restic or
kopia) or by asking the storage layer for a snapshot (`CSISnapshot`). It writes to an
S3-compatible bucket and tracks its own work in its own custom resources.

**Database operators** back up their own databases, on their own terms. CloudNativePG, for
example, has two entirely separate mechanisms running at once: continuous WAL archiving
through the barman-cloud plugin, and periodic logical dumps run by a Kubernetes CronJob.
Those two can and do fail independently. WAL archiving can be healthy while logical dumps
have not run in a week.

**Your own CronJobs** back up the things nothing else covers. Somebody wrote a `pg_dump` to a
bucket, it works, and it has been running unattended since.

**The storage layer** may be taking volume snapshots underneath all of it, on a schedule
configured in a completely different system.

Each of these reports success in its own dialect. Velero has custom resources. The operator
has a status field. The CronJob has a Job exit code, if anyone is looking. None of them know
about each other, and none of them can tell you the one thing you actually want to know:
is everything in this cluster backed up, and how recently.

The failure mode this produces is not a backup that errors loudly. It is a database or a
volume that quietly has no backup configured at all. Nothing errors, because nothing is
running. There is no alert for a job that does not exist.

## What we deploy: a backup exporter

The answer we settled on is a small exporter that runs inside the cluster and does the
cross-referencing that nobody else does.

It is a Deployment, installed by a Helm chart, that runs on a schedule and needs two things:

- **Read-only access to the cluster.** It lists PVCs, CNPG clusters, CronJobs and the
  operators' own resources. It never writes anything.
- **Read access to your backup bucket.** The same S3-compatible storage your backups already
  land in. Read only, and it only ever lists and reads metadata objects.

Everything stays local. The exporter runs in your cluster, reads your bucket, and publishes
its findings as Prometheus metrics on your monitoring stack. Nothing is sent anywhere else,
and there is no external service to sign up for.

## Why the exporter is smarter than reading a status field

The straightforward way to build this would be to read what each backup tool says about
itself: ask Velero if its last backup succeeded, ask the operator if its last dump was fine.
That approach cannot answer the question that actually matters.

The exporter does three things differently.

**It verifies the artifact, not the report.** For Velero it walks the backup directories in
S3, reads the volume metadata each backup writes, and checks the per-volume result. A backup
job that reported success but produced nothing for a given PVC does not pass. The evidence is
the object in the bucket, not a status field.

**It finds what was never backed up.** This is the important one. The exporter lists PVCs
from the cluster and backups from the bucket, then merges them. A PVC that appears in the
cluster and nowhere in the bucket is reported explicitly as having no backup. A tool that
only reads backup records is structurally incapable of telling you this, because the thing
you need to know about left no record anywhere. If you want a volume deliberately excluded,
you label it, and the exporter respects that.

**It understands that one resource can have several backup streams.** A CNPG cluster is
tracked as both its logical dump and its WAL archive, evaluated separately, because they fail
separately and you need to know which one broke.

On top of that it evaluates ages against a configurable RPO rather than handing you raw
numbers, so the output is a verdict rather than a spreadsheet. Collector-level problems are
reported separately from resource-level ones, so if the exporter cannot reach the bucket at
all you are told that plainly instead of being shown a screen of misleading greens.

## Your go-to command: `kubeaid-cli backup status`

The metrics are there for alerting. For the human question, there is one command:

```
kubeaid-cli backup status
```

It uses your current kubeconfig, exactly like kubectl. If `kubectl get svc` works against a
cluster, this works. It finds the exporter itself, so there is nothing to configure and no
namespace or endpoint to pass.

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

Reading it top to bottom:

The **first line** tells you how fresh the answer is. Backup checks run on a schedule, so
knowing the data is three hours old matters as much as the data itself.

**Operator errors** come before the table because they change how much you should trust it.
If the exporter cannot list the bucket, every row below it is a guess.

**`STREAM` and `METHOD`** together tell you what broke and what to go open. `STREAM` is what
is being backed up: `logical`, `wal`, `volume`. `METHOD` is the mechanism doing it: `CronJob`,
`Barman`, `PodVolumeBackup`, `CSISnapshot`. In the first row above, the logical dump for
`demo-pgsql` is failing and the method is `CronJob`, so you know to go look for a missing
CronJob rather than at Postgres.

**`LATEST AGE`** is how old the newest usable backup is. `none` means there is no backup at
all, which is different from a dash, meaning the check has not produced a measurement yet.

**`STATUS`** is the verdict: `healthy`, `exceeds_rpo` (a backup exists but is older than your
RPO), `no_backup` (nothing exists), `collector_error` (the check itself failed, with the
reason in brackets), or `unknown`.

The **last line** counts resources rather than rows, so a database with two streams counts
once, under whichever of its streams is in the worst shape.

Every row carries its namespace, so the output pipes into anything:

```
kubeaid-cli backup status | grep -v healthy
```

leaves you with exactly the rows that need attention, each one complete. There is also
`-o json` if you would rather feed it into something else.

The command exits `0` whenever it can produce a report, however bad the report is. A non-zero
exit means it could not reach the exporter. It is a report rather than a health gate, so
dropping it into a pipeline will not start failing builds over a backup you already knew was
missing.

## What this catches

The things that turn up are rarely dramatic failures. They are gaps.

A database with no logical backup CronJob deployed at all, so nothing has ever run and
nothing has ever alerted. A collector quietly timing out because its storage credentials were
never configured, meaning nobody has actually checked that bucket in months. A volume added
during a migration that nobody added to the backup schedule.

None of these announce themselves. All of them are visible in ten seconds once something
cross-references what exists against what has been backed up.

## What this does not tell you

Being straight about the limits, because the title of this post is a boast.

This tells you a backup exists and how recent it is. It does not tell you the backup
restores. Those are different questions, and the second one is harder, because answering it
honestly means standing the data up somewhere and checking it came back intact.

Freshness is the floor. It is worth having first, because anything missing or three days
stale fails a restore test too, and this catches that class immediately and for free. Restore
verification is the next piece of work.

## Getting started

The exporter is at
[github.com/Obmondo/backup-exporter](https://github.com/Obmondo/backup-exporter) and installs
via its Helm chart. Point it at your backup bucket with read-only credentials.

`backup status` ships in `kubeaid-cli` v0.31.0,
[github.com/Obmondo/kubeaid-cli](https://github.com/Obmondo/kubeaid-cli). Once the exporter is
running, the command needs no configuration at all.
