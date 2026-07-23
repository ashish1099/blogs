---
title: "Building an On-Call Pager from GoAlert, ntfy, and a Chat Emoji"
date: 2026-07-23T09:00:00+05:30
draft: false
tags: ["goalert", "ntfy", "mattermost", "on-call", "paging", "prometheus", "alertmanager", "sre", "self-hosted"]
author: "Ashish Jaiswal"
summary: "GoAlert handles on-call schedules and escalation. ntfy handles phone push. Neither one, out of the box, closes the loop when someone actually acknowledges an alert. This post walks through designing a bridge between the two — a chat emoji reaction as the acknowledgment, a GraphQL API key cryptographically locked to one query, and a free-text field repurposed as a state channel because the platform didn't ship a better one."
showToc: true
TocOpen: true
---

## The Gap

Alerts land in a Mattermost channel. Critical ones also ping a chat bot for whoever's on call. Nobody's phone actually rings. If it's 3am and the on-call engineer's phone is face-down on the nightstand, the alert just sits there until someone happens to glance at chat. That's not paging — that's hoping.

The fix looked obvious on paper: [GoAlert](https://github.com/target/goalert) for schedules and escalation, [ntfy](https://ntfy.sh) for a push notification that can actually wake someone up. Wire Alertmanager into GoAlert, wire GoAlert into ntfy, done.

Then I got to the acknowledgment step and the obvious plan fell apart. GoAlert doesn't have an ntfy integration. It also doesn't have a public "ack this alert" API. Both of those are load-bearing for a pager — escalation only means something if *not* acking actually escalates, and it only stops if acking is possible in the first place.

## What GoAlert v0.34.1 Actually Ships

Before designing around a gap, I wanted to be sure it was a real gap and not a doc-reading miss. I read the GoAlert source directly — v0.34.1, the latest tagged release as of writing (October 2025); master is only about 42 commits ahead of it, and nearly all of those are dependency bumps, not features. This isn't "wait a month and it'll land upstream" territory.

Confirmed:

- **No ntfy notification channel.** GoAlert ships email, Slack, Twilio (SMS + voice), and generic webhooks. ntfy isn't one of the options.
- **No public per-alert ack endpoint.** The generic integration API — the one you'd point Alertmanager at — supports exactly two actions: create an alert, and `action=close` (`genericapi/handler.go:78-81,126`). There is no `action=ack`.
- **The ack surfaces that do exist are all tied to a specific channel**: Slack's interactive buttons, a reply code over Twilio SMS, a DTMF digit on a Twilio voice call, or the authenticated GraphQL `updateAlerts` mutation (`graphql2/graph/_Mutation.graphqls:31`).

So the real options were: fork GoAlert to add an ntfy channel and a webhook ack action, or build a small bridge on top of the interfaces GoAlert already exposes. I went with the bridge. Forking a project you don't intend to maintain upstream is a debt you pay on every future GoAlert release, forever — a bridge is just a client of GoAlert's stable public API, not a patch on its internals.

## Composing, Not Forking

The design leans on three systems, each kept doing the one thing it's already good at:

- **GoAlert** owns *who* is on call and *when* to escalate — schedules, rotations, and the escalation-policy step timers that decide how long to wait for an ack before paging someone else. That state machine is genuinely hard to get right, and GoAlert already has it.
- **ntfy** owns getting a notification onto a phone with pager-like urgency — self-hosted, no vendor lock-in, priority levels that map to real phone behavior.
- **A small Go service** — call it the *alert router*, since routing and grouping alerts is what it already did before this design — owns everything alert-shaped: grouping firings from Prometheus Alertmanager, posting to Mattermost, and now, the bridge between GoAlert and ntfy plus the emoji-ack loop.

The bridge is possible specifically because GoAlert exposes a generic integration API (create/close, authenticated with a bare integration key) and a GraphQL API (everything else, properly authenticated). Nothing here requires touching GoAlert's Go code.

## Architecture

![Flow diagram: two customer Alertmanagers feed the alert router (step 1), which posts one Mattermost thread per alert-group and creates a GoAlert alert carrying the thread link (step 2). GoAlert's first escalation pages the on-call SRE's ntfy app through the self-hosted ntfy server (steps 3 and 4). To ack, the SRE opens the chat link and adds an emoji reaction (step 5A); the alert router polls the thread every 30 seconds (step 6) and acks the alert back in GoAlert (step 7). No ack escalates to senior/management via ntfy plus an SMS pointer (step 5B).](/images/oncall-pager-goalert-ntfy-flow.svg)

### The ack loop, precisely

```
SRE taps the ntfy notification
        │
        ▼
  Mattermost thread opens
        │
        ▼
  SRE adds any emoji reaction to the root post
        │
        ▼
  ReactionSync cron (polls every 30s) sees it via GetReactions
        │
        ▼
  GoAlert updateAlerts(StatusAcknowledged)   ← query-locked API key
        │
        ▼
  escalation stops · MTTA recorded · thread gets a reply


  no reaction before the step timeout
        │
        ▼
  GoAlert fires the next escalation step ──▶ senior's ntfy topic
```

One Mattermost thread per alert-group, reusing the grouping identity the router already uses for issue-tracker dedup — no new concept, just a new place to post. Re-fires, resolves, acks, and escalations become replies in that same thread, never new roots, so the whole lifecycle of one alert reads top-to-bottom in one place.

## The Trick: Smuggling State Through `details`

This is the part of the design I'd want to remember a year from now.

GoAlert's outbound webhook — the payload that fires when an alert is created, escalated, or changes status — is exactly this shape at v0.34.1 (`notification/webhook/sender.go:20-30`):

```
{ AppName, Type, AlertID, Summary, Details, ServiceID, ServiceName, Meta }
```

No URL field. No custom-fields map. (A `GoAlertURL` field exists on master, unreleased at time of writing — not something to design around yet.) Of everything in that payload, the only field the *creator* of the alert controls is `Details` — free text, nominally meant for a human-readable summary.

So `details`, at alert-creation time, becomes:

```
<mattermost thread permalink>
group: <alert-group key>
```

That decision carries the entire bridge. The alert router needs to know which GoAlert `AlertID` maps to which Mattermost thread *before* it can publish an ntfy notification with a working click-through link, and the only place that mapping can come from is the round trip through GoAlert. The **first webhook delivery** GoAlert sends back is where the router parses `Details`, learns `AlertID → group`, and stores it. Every webhook after that resolves the mapping from a reverse index instead, so the create-response race doesn't matter past the first hop.

It's not an elegant abstraction — it's a free-text field carrying structured state because the platform didn't ship a better carrier. That's fine, as long as it's written down as intentional rather than discovered by whoever debugs it in six months.

## Ack: an API Key That Can Do Exactly One Thing

The ack path is a GraphQL mutation:

```graphql
mutation Ack($id: ID!) {
  updateAlerts(input: { alertIDs: [$id], newStatus: StatusAcknowledged }) {
    id
  }
}
```

authenticated with a GraphQL API key (`Authorization: Bearer`, `auth/gettoken.go:37`). The detail that made me actually comfortable handing this key to an automated cron: GoAlert locks a GraphQL API key to the **exact query document** it was created with, enforced by a sha256 policy check (`CreateGQLAPIKeyInput.query`, `apikey/policyinfo.go:32`). This isn't role-based scoping where "ack-only" is a convention someone has to maintain — the key is cryptographically incapable of executing any mutation other than the one it was minted for. If it leaks, the blast radius is "someone can ack alerts," full stop.

The same mechanism issues a second, separate key scoped to a read-only schedule query (see below) — two keys, two blast radii, neither one able to do what the other does.

Ack handling is idempotent: an "already acknowledged" or "already closed" response counts as success, since a reaction can arrive after someone already acked from the GoAlert UI directly. That path is covered too — GoAlert's `AlertStatus` webhook fires on any status change regardless of source, so a UI-side ack resolves through the same reverse index and gets recorded the same way.

## ntfy Delivery

Publish is a single authenticated `PUT` to the ntfy server root:

```json
{
  "topic": "oncall-jdoe",
  "title": "[critical] KubeAPIDown — customer-x",
  "message": "prod cluster, firing 2m. Tap to open the alert thread, react with any emoji to ack.",
  "priority": 5,
  "click": "https://chat.example.com/team/pl/<postID>",
  "tags": ["rotating_light"]
}
```

One topic per on-call engineer (`oncall-<username>`), with per-topic ACLs — a page for you shouldn't buzz the whole team. Team-wide visibility already lives in the Mattermost channel; ntfy's only job here is "wake up this one person."

The alternative — one shared team topic where every phone fires and the first to react wins — is easier to provision: no per-user topics, tokens, or ACLs. It lost on two grounds. It spends everyone's sleep to buy redundancy, waking people the schedule says are off. And it quietly re-makes a decision GoAlert already owns: the schedule knows who holds the pager, so the push should follow it — broadcast turns escalation into a race. If you don't run real on-call schedules yet, the shared topic is a legitimate v0; it just isn't a pager.

## Why Poll for Reactions Instead of a Websocket

Detecting the emoji is a cron, not a live event listener: every 30 seconds, for each open, paged, un-acked alert-group, call `GetReactions` on the thread root and check for the first reaction from a non-bot user.

Mattermost does have a `reaction_added` websocket event. I didn't use it, on purpose:

- The alert router is already cron-idiomatic — every other periodic behavior in it is a poll, including the circuit breaker that trips when Mattermost is unreachable. A websocket consumer would be the one component with a fundamentally different failure mode (reconnect logic, backoff, a long-lived connection to keep alive) in a service that otherwise doesn't need one.
- 30 seconds of ack-detection latency is noise against escalation step timers measured in minutes. There's no real-time requirement hiding here — polling is restart-safe, and a crashed cron just runs again 30 seconds later with zero state to reconcile.

Reach for the event stream when the latency actually matters. Here it didn't, and the poll is strictly simpler to operate and to reason about at 3am.

## If You're Building This

The pieces that need wiring up, roughly in provisioning order:

- A GoAlert generic-integration key (create/close alerts) and two GraphQL API keys — one query-locked to the ack mutation, one to a schedule-shifts query. Two keys, two blast radii.
- A GoAlert webhook contact method per on-call engineer, restricted to the bridge service's URL via `AllowedURLs` (`config.go:139-142`).
- A self-hosted ntfy instance, one topic per engineer, with per-topic ACLs.
- A cron for the reaction poll — 30s is a reasonable default; tune it against your escalation step timers, not the other way around.

That, plus the `details` round-trip, is the entire integration surface. No GoAlert fork required.

GoAlert also turns out to be a better source of on-call schedule data than whatever scraping I had before: `Query.schedule(id).shifts(start, end)` returns the shift table directly, and `Service.onCallUsers` answers "who's on call right now" without scraping anything.

## Naming the Metric Honestly

The original ask was "add an MTTR metric." What firing → ack actually measures is **MTTA** — mean time to *acknowledge*, not mean time to *resolve*. Those are different numbers with different meanings, and calling the wrong one MTTR doesn't make the dashboard more useful — it makes it wrong in a way nobody notices until someone's staring at an SLA report mid-incident.

So the metric is named for what it measures:

```
alert_ack_duration_seconds{customer, severity, acked_via}   # histogram, firing → ack
goalert_requests_failed_total{operation}                    # counter
ntfy_publish_failed_total                                   # counter
```

True MTTR (firing → resolved) is a legitimate follow-up metric — both timestamps already exist in the same record, so it's a cheap addition later. It just isn't the same thing MTTA is, and shouldn't share a name with it.

## Phone Reality, Told Straight

It's easy to design a push notification on a whiteboard and quietly assume it behaves like a pager. It doesn't, by default, on either platform — and the gaps are different enough on each that they need separate treatment instead of one "push notifications enabled" checkbox.

**Android** gets genuinely pager-grade behavior, but only after two settings most people never touch: ntfy creates one notification channel per priority level, and the on-call engineer has to enable "Override Do Not Disturb" and "Insistent" on the priority-5 channel specifically. Self-hosted topics use the app's own foreground service for instant delivery — no dependency on Google's FCM relay — so it's worth exempting the app from battery optimization too. All three are onboarding-checklist items, not defaults.

**iOS** has no equivalent to Android's override for a self-hosted app — there's no entitlement a self-hosted service can obtain that lets it bypass Focus modes the way Apple's own critical alerts can. Self-hosting still works, but only by relaying through `ntfy.sh`'s APNS bridge (`upstream-base-url: https://ntfy.sh` in the server config): Apple requires push delivery to go through their own push service, and only the public ntfy.sh instance holds the app's push certificate. What crosses that relay is a message ID and a topic checksum, not notification content — an acceptable tradeoff, but worth stating plainly instead of glossing over.

The honest conclusion: treat iOS delivery as best-effort. What actually guarantees someone gets paged on iOS is the escalation timer stepping to the next person, not the push notification itself. Don't market it as more reliable than it is.

## Failure Modes

Worth working through on paper before any of this ships — a paging system's failure modes matter more than its happy path:

| If this is down | What happens | Why it's safe |
|---|---|---|
| ntfy | GoAlert's step timers keep firing webhooks regardless; each retries the publish | The paging trigger lives in GoAlert's state, not the bridge's memory |
| Mattermost | ntfy still fires with the summary text, just no click-through link | A plain page beats a pretty one |
| GoAlert | The existing Prometheus → Mattermost path is untouched | The old pipeline was never coupled to GoAlert |
| The bridge service | GoAlert escalates on its own timers to whatever contact methods are configured (SMS/voice as a last-resort step) | The escalation brain doesn't live in the piece that can go down |
| Ack arrives after escalation already fired | Ack still records; the senior's page still stands | A late ack must never silently un-page someone already notified |

## What's Still Open

A few things left as open questions rather than guessed at:

- Should an ack also drop a comment on the tracking issue for the audit trail, separate from stopping escalation?
- If an already-acked alert-group re-fires hours later, should that force GoAlert back to unacknowledged so it re-pages? Left alone, GoAlert just stays silent — which might be the wrong default.
- One shared paging service, or one per customer/team? Affects how escalation policies and service topology get modeled in GoAlert.
- Does *every* alert-group get a Mattermost thread, or only the ones severe enough to page? Threading everything is simpler; threading only pages is less noisy.

## Takeaways

- **Compose, don't fork.** GoAlert was missing exactly two things I needed. Forking it to add them would mean maintaining a diverging fork forever. A bridge that only talks to GoAlert's public API surface stays a client, not a patch.
- **A field you fully control end-to-end is a legitimate state carrier**, even a free-text one meant for something else, as long as the load-bearing use is written down instead of discovered later by whoever's debugging it.
- **Cryptographically-scoped API keys** — locked to one query, not just "a role called ack" — are worth specifically seeking out when you're about to hand automation the keys to something that pages people.
- **Name metrics for what they measure**, not for what the ticket asked them to be called. MTTA and MTTR aren't interchangeable, and a mislabeled one becomes a lying dashboard the first time someone builds a decision on it.
- **Say the quiet part about push notifications out loud.** Android can be pager-grade with the right settings; iOS structurally can't, no matter how the notification is configured. Design the escalation path assuming the push might not land — not as a rare edge case.
