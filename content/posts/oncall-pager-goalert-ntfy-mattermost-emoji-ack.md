---
title: "Obmondo's Open-Source On-Call Paging: GoAlert, ntfy, and a Chat Emoji"
date: 2026-07-27T09:00:00+05:30
draft: false
tags: ["goalert", "ntfy", "mattermost", "on-call", "paging", "sre", "self-hosted", "open-source"]
author: "Ashish Jaiswal"
summary: "How we page on-call SREs at Obmondo with only open-source parts: GoAlert decides who gets woken up and when to escalate, ntfy makes the phone ring, and the acknowledgement is an emoji reaction on the alert's Mattermost thread."
showToc: true
TocOpen: true
---

## The problem

Our alerts land in Mattermost. That works fine during the day. At 3am it does not: a chat message does not wake anyone up, and an alert nobody saw does not escalate to anyone else. The two things a pager actually does — ring a phone, and hand over to the next person when there is no response — were missing.

The commercial answer is PagerDuty or Opsgenie. We run open-source infrastructure for our customers, we did not want alert data leaving our platform, and we did not want a per-seat pager bill. So we built paging from open-source parts.

## The parts

- **[GoAlert](https://github.com/target/goalert)** — on-call schedules, rotations, and escalation policies. It decides *who* should be paged right now and *when* to give up on them and page the next person.
- **[ntfy](https://ntfy.sh)** — self-hosted push notifications. It makes the phone ring, loudly, including on silent-ish setups (more on phones below).
- **[Mattermost](https://mattermost.com)** — where our SREs already work. Every alert gets its own thread there.
- **Opsmondo** — our alert engine. It already receives everything from Prometheus Alertmanager across customer clusters, groups related alerts, and opens tickets. It now also connects GoAlert and ntfy, because the two do not speak to each other out of the box.

GoAlert has no ntfy integration and no public "acknowledge this alert" endpoint. We did not want to fork it — a fork is maintenance debt forever. Opsmondo already sits in the middle of every alert, so it takes the extra role of translator, using only GoAlert's standard APIs.

## The architecture

![Obmondo on-call paging flow: Alertmanagers feed Opsmondo, which posts a Mattermost thread per alert group and creates the alert in GoAlert. GoAlert pages the on-call SRE through ntfy. The SRE acks by reacting on the thread; no ack escalates to management.](/images/oncall-pager-goalert-ntfy-flow.svg)

Following the numbered steps in the diagram:

1. Alertmanager (one per customer cluster) sends alerts to Opsmondo.
2. Opsmondo groups them, posts **one Mattermost thread per alert group**, and creates the alert in GoAlert with a link to that thread.
3. GoAlert checks the on-call schedule and starts its escalation clock. First escalation goes out to ntfy.
4. The on-call SRE's phone gets a maximum-priority push. Tapping it opens the Mattermost thread.
5. The SRE adds an emoji reaction to the thread — any emoji. That is the acknowledgement. If no reaction comes in time, GoAlert escalates: second page goes to management, via ntfy and SMS.
6. Opsmondo watches the thread and picks up the reaction.
7. Opsmondo acknowledges the alert in GoAlert, which stops the escalation clock. A reply lands in the thread saying who took it.

## Why an emoji, of all things

Because it is the one acknowledgement that needs nothing new. No app to install, no ack button to build, no second system to log into at 3am. The push notification already lands the SRE inside the alert's thread — the place where the work is going to happen anyway. Reacting there is one tap, everyone in the channel sees who took it, and the thread becomes the war room.

The other property we wanted: **silence escalates**. Acknowledging is a human action; not acknowledging is the absence of one. GoAlert's escalation timers treat no-reaction as "page the next person", so a dead phone, a missed notification, or a sleeping SRE never silently swallows an alert.

## What the phones actually do

Honesty matters here, because push notifications are not pagers by default.

On **Android**, ntfy can behave like a real pager: the max-priority channel can override Do Not Disturb and keep ringing until dismissed, and self-hosted delivery works without Google's push service. This needs a couple of one-time settings on the SRE's phone, which we make part of on-call onboarding.

On **iOS**, Apple does not allow a self-hosted app to break through Focus mode. Pushes arrive, but "the phone will definitely scream" cannot be promised. That is fine — the guarantee in this design is the escalation chain, not any single phone.

## What this gives us

- The **right person's** phone rings — the schedule in GoAlert decides, not a broadcast to the whole team.
- Unacknowledged alerts **escalate on their own**, all the way to management.
- We measure the time from alert firing to acknowledgement, so on-call response is a number, not a feeling.
- The pieces fail safe: if ntfy or Mattermost is down, GoAlert keeps escalating; if GoAlert is down, the normal alert flow to chat and tickets is untouched.
- Everything is **self-hosted and open source**. No alert data leaves our platform, and there is no per-seat pager subscription.

A follow-up post will cover the integration details for anyone who wants to build the same thing.
