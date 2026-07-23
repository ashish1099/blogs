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

<style>
.bk-hero{--bk-live:#1a7f52;background:var(--code-bg);border:1px solid var(--border);border-radius:var(--radius);padding:22px 24px;margin:0 0 34px}
:root[data-theme="dark"] .bk-hero{--bk-live:#4cc38a}
.bk-hero__marks{display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.bk-hero__wordmark{height:21px;width:auto;color:var(--primary);flex:none}
.bk-hero__join{color:var(--secondary);flex:none}
.bk-hero__k8s{display:inline-flex;align-items:center;gap:8px;color:var(--primary);font-weight:600;font-size:.95rem}
.bk-hero__k8s svg{width:26px;height:26px;flex:none}
.bk-hero__line{margin:15px 0 18px;color:var(--secondary);font-size:.92rem;line-height:1.5}
.bk-hero__cov{display:flex;flex-direction:column;gap:11px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.82rem}
.bk-hero__grp{display:flex;align-items:baseline;gap:16px}
.bk-hero__lbl{flex:none;width:38px;font-size:.66rem;letter-spacing:.11em;text-transform:uppercase;color:var(--secondary)}
.bk-hero__items{display:flex;flex-wrap:wrap;gap:7px 20px}
.bk-hero__eng{display:inline-flex;align-items:center;gap:7px;color:var(--secondary);white-space:nowrap}
.bk-hero__eng--live{color:var(--primary)}
.bk-hero__eng i{width:7px;height:7px;border-radius:50%;border:1.5px solid var(--secondary);box-sizing:border-box;flex:none}
.bk-hero__eng--live i{background:var(--bk-live);border-color:var(--bk-live)}
@media (max-width:480px){.bk-hero{padding:18px 16px}.bk-hero__grp{flex-direction:column;gap:6px}}
</style>

<div class="bk-hero">
  <div class="bk-hero__marks">
    <svg class="bk-hero__wordmark" viewBox="0 0 137 24" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Obmondo">
      <path fill-rule="evenodd" clip-rule="evenodd" d="M23.3333 12.3333C23.3333 18.7767 18.11 24 11.6667 24C5.22334 24 0 18.7767 0 12.3333C0 5.89001 5.22334 0.666667 11.6667 0.666667C18.11 0.666667 23.3333 5.89001 23.3333 12.3333ZM11.6667 20.6667C16.269 20.6667 20 16.9357 20 12.3333C20 7.73096 16.269 4 11.6667 4C7.06429 4 3.33333 7.73096 3.33333 12.3333C3.33333 16.9357 7.06429 20.6667 11.6667 20.6667Z" fill="currentColor"/>
      <path fill-rule="evenodd" clip-rule="evenodd" d="M84.6667 15.3333C84.6667 20.1198 80.7865 24 76 24C71.2135 24 67.3333 20.1198 67.3333 15.3333C67.3333 10.5469 71.2135 6.66667 76 6.66667C80.7865 6.66667 84.6667 10.5469 84.6667 15.3333ZM76 20.6667C78.9455 20.6667 81.3333 18.2789 81.3333 15.3333C81.3333 12.3878 78.9455 10 76 10C73.0545 10 70.6667 12.3878 70.6667 15.3333C70.6667 18.2789 73.0545 20.6667 76 20.6667Z" fill="currentColor"/>
      <path fill-rule="evenodd" clip-rule="evenodd" d="M136.667 15.3333C136.667 20.1198 132.786 24 128 24C123.214 24 119.333 20.1198 119.333 15.3333C119.333 10.5469 123.214 6.66667 128 6.66667C132.786 6.66667 136.667 10.5469 136.667 15.3333ZM128 20.6667C130.946 20.6667 133.333 18.2789 133.333 15.3333C133.333 12.3878 130.946 10 128 10C125.054 10 122.667 12.3878 122.667 15.3333C122.667 18.2789 125.054 20.6667 128 20.6667Z" fill="currentColor"/>
      <path fill-rule="evenodd" clip-rule="evenodd" d="M28 0H24.6667V15.3333C24.6667 20.1198 28.5469 24 33.3333 24C38.1198 24 42 20.1198 42 15.3333C42 10.5469 38.1198 6.66667 33.3333 6.66667C31.322 6.66667 29.4706 7.35185 28 8.50154V0ZM28 15.3333C28 18.2789 30.3878 20.6667 33.3333 20.6667C36.2789 20.6667 38.6667 18.2789 38.6667 15.3333C38.6667 12.3878 36.2789 10 33.3333 10C30.3878 10 28 12.3878 28 15.3333Z" fill="currentColor"/>
      <path fill-rule="evenodd" clip-rule="evenodd" d="M114.667 0H118V15.3333C118 20.1198 114.12 24 109.333 24C104.547 24 100.667 20.1198 100.667 15.3333C100.667 10.5469 104.547 6.66667 109.333 6.66667C111.345 6.66667 113.196 7.35185 114.667 8.50154V0ZM114.667 15.3333C114.667 18.2789 112.279 20.6667 109.333 20.6667C106.388 20.6667 104 18.2789 104 15.3333C104 12.3878 106.388 10 109.333 10C112.279 10 114.667 12.3878 114.667 15.3333Z" fill="currentColor"/>
      <path d="M43 13.6667V24H46.3333V13.6667C46.3333 11.8257 47.8257 10.3333 49.6667 10.3333C51.5076 10.3333 53 11.8257 53 13.6667V24H56.3333V13.6667C56.3333 11.8257 57.8257 10.3333 59.6667 10.3333C61.5076 10.3333 63 11.8257 63 13.6667V24H66.3333V13.6667C66.3333 9.98477 63.3486 7 59.6667 7C57.6753 7 55.8878 7.87342 54.6667 9.25698C53.4455 7.87342 51.658 7 49.6667 7C45.9848 7 43 9.98477 43 13.6667Z" fill="currentColor"/>
      <path d="M86.3333 13.6667V24H89.6667V13.6667C89.6667 11.8257 91.159 10.3333 93 10.3333C94.841 10.3333 96.3333 11.8257 96.3333 13.6667V24H99.6667V13.6667C99.6667 9.98477 96.6819 7 93 7C89.3181 7 86.3333 9.98477 86.3333 13.6667Z" fill="currentColor"/>
    </svg>
    <span class="bk-hero__join" aria-hidden="true">&#215;</span>
    <span class="bk-hero__k8s">
      <svg viewBox="0 0 100 100" fill="none" role="img" aria-label="Kubernetes">
        <path d="M50 8 L82.84 23.81 L90.95 59.35 L68.22 87.84 L31.78 87.84 L9.05 59.35 L17.16 23.81 Z" stroke="currentColor" stroke-width="5.5" stroke-linejoin="round"/>
        <circle cx="50" cy="50" r="9" stroke="currentColor" stroke-width="4.5"/>
        <g stroke="currentColor" stroke-width="4.5" stroke-linecap="round">
          <path d="M50 41 L50 22"/>
          <path d="M57.04 44.39 L71.89 32.54"/>
          <path d="M58.77 52.00 L77.30 56.23"/>
          <path d="M53.90 58.11 L62.15 75.23"/>
          <path d="M46.10 58.11 L37.85 75.23"/>
          <path d="M41.23 52.00 L22.70 56.23"/>
          <path d="M42.96 44.39 L28.11 32.54"/>
        </g>
      </svg>
      Kubernetes
    </span>
  </div>

  <p class="bk-hero__line">One command to see whether every database and every volume in your cluster
  is actually backed up, and how recently.</p>

  <div class="bk-hero__cov">
    <div class="bk-hero__grp">
      <span class="bk-hero__lbl">now</span>
      <span class="bk-hero__items">
        <span class="bk-hero__eng bk-hero__eng--live"><i></i>CloudNativePG</span>
        <span class="bk-hero__eng bk-hero__eng--live"><i></i>Velero</span>
      </span>
    </div>
    <div class="bk-hero__grp">
      <span class="bk-hero__lbl">next</span>
      <span class="bk-hero__items">
        <span class="bk-hero__eng"><i></i>MongoDB</span>
        <span class="bk-hero__eng"><i></i>RabbitMQ</span>
        <span class="bk-hero__eng"><i></i>Redis</span>
      </span>
    </div>
  </div>
</div>

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

Today that covers CloudNativePG and Velero, which between them account for most of what
needs backing up in a typical cluster. MongoDB, RabbitMQ and Redis are next, each following
the same principle: check the artifact in storage, and name the things that were never set up
in the first place.

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
