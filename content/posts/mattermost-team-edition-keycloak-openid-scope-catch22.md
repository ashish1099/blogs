---
title: "When the Obvious OAuth Fix Makes It Worse"
date: 2026-07-14T09:00:00+05:30
draft: false
tags: ["mattermost", "keycloak", "sso", "oauth", "oidc", "gitlab", "kubernetes", "self-hosted"]
author: "Ashish Jaiswal"
summary: "Keycloak 25 started enforcing the openid scope on /userinfo, which broke SSO for Mattermost Team Edition's Keycloak-as-GitLab setup. The fix everyone tries first breaks it worse. The real one lives in Keycloak's config, not Mattermost's."
showToc: true
TocOpen: true
---

Every SSO login to chat.example.com started failing inside the same minute. Nobody had touched Mattermost. Someone had bumped Keycloak to a new major version, the kind of change that doesn't usually get its own changelog line. The only clue was an unhelpful error: *"Received invalid response from OAuth service provider."*

So you go looking for the setting that's obviously wrong, and you find one: an empty `scope` where both the docs and common sense say `openid` belongs. You set it. Login breaks again, this time with a different error pointing at a completely different part of the system: *"Gitlab SSO through OAuth 2.0 not available on this server."*

That second failure is what this post is about. It's a genuine catch-22 between Mattermost Team Edition and Keycloak: two pieces of software, neither one misconfigured, whose defaults happen to be mutually exclusive. The fix only shows up once you stop asking "what value goes in this field" and start asking "whose job is it to put a scope on this token at all?"

---

## Why Mattermost Team Edition speaks GitLab, not OIDC

[Mattermost](https://mattermost.com/) Team Edition, the free self-hosted build, doesn't ship OpenID Connect. OIDC login is a licensed feature. What you get for free is a single OAuth 2.0 provider hardcoded to GitLab's API shape, configured entirely through `MM_GITLABSETTINGS_*` variables.

The trick, well known to anyone who's run self-hosted Mattermost for a while, is to point that "GitLab" provider at Keycloak and get Keycloak's endpoints to answer in a shape close enough to GitLab's that Mattermost's client code can't tell the difference:

```yaml
MM_GITLABSETTINGS_ENABLE: "true"
MM_GITLABSETTINGS_ID: "mattermost"
MM_GITLABSETTINGS_SECRET: "<client secret>"
MM_GITLABSETTINGS_AUTHENDPOINT: "https://keycloak.example.com/realms/myrealm/protocol/openid-connect/auth"
MM_GITLABSETTINGS_TOKENENDPOINT: "https://keycloak.example.com/realms/myrealm/protocol/openid-connect/token"
MM_GITLABSETTINGS_USERAPIENDPOINT: "https://keycloak.example.com/realms/myrealm/protocol/openid-connect/userinfo"
```

There's nothing exotic about this. OAuth 2.0 doesn't care what the provider calls itself, only that the endpoints behave the way the client expects. (Both sides here were self-hosted on Kubernetes, but that's incidental; the contract below holds no matter how either is deployed.) The setup had run for years across Keycloak 19 and 20 without anyone touching it.

Then we moved the same Mattermost instance to a newer Keycloak, version 25, changing nothing but the endpoint URLs and the client secret. Every SSO login broke at once.

---

## Failure one: Keycloak now insists on the `openid` scope

Since Keycloak **19.0.2**, the `/userinfo` endpoint enforces something that was always technically correct: UserInfo is an OIDC feature, not a plain OAuth 2.0 one, and Keycloak won't answer for a token that never asked for OIDC. The check is blunt:

```java
// UserInfoEndpoint.java
if (!TokenUtil.hasScope(token.getScope(), OAuth2Constants.SCOPE_OPENID)) {
    throw error.insufficientScope("Missing openid scope");     // HTTP 403
}
```

No `openid` in the token's `scope` claim, no `/userinfo` response. Just a `403`. And this isn't a fringe case; the same enforcement has caught other legacy integrations ([keycloak#16168](https://github.com/keycloak/keycloak/issues/16168), [discussion #15331](https://github.com/keycloak/keycloak/discussions/15331)).

Mattermost's GitLab provider happens to be the only built-in SSO provider that defaults its scope to empty:

```go
// model/config.go
o.GitLabSettings.setDefaults("", "", "", "", "")   // last param is Scope — defaults to ""
```

and when the scope is empty, Mattermost's OAuth client doesn't even send the parameter:

```go
if scope != "" {
    authURL += "&scope=" + url.QueryEscape(scope)
}
```

So Keycloak got an authorize request with no `scope` parameter, minted a plain OAuth2 token with no `openid` in its scope claim, and `/userinfo` rejected it. Mattermost reported that rejection as a generic `api.user.authorize_oauth_user.response.app_error`, which renders as *"Received invalid response from OAuth service provider."*

The thing to notice is that our configuration hadn't changed in any way that should matter. The exact same environment variables had worked against Keycloak 19 and 20. What changed was the enforcement on Keycloak's side, not anything on ours.

---

## Failure two: the obvious fix reroutes you into a wall

The error all but tells you the fix, and Keycloak literally names the missing thing: "openid scope." Every SSO integration guide agrees. Set the scope.

```yaml
MM_GITLABSETTINGS_SCOPE: "openid profile email"
```

Login breaks again. Different error this time:

> Gitlab SSO through OAuth 2.0 not available on this server.

This one is stranger. It doesn't read like a Keycloak problem at all; it reads like Mattermost thinks GitLab SSO was never configured, even though nothing changed except one string thirty seconds ago.

The cause is a second overload, this time on Mattermost's side. `getSSOProvider()` treats the scope string not as a request parameter but as a provider selector:

```go
providerType := service
if strings.Contains(*sso.Scope, OpenIDScope) {   // OpenIDScope == "openid"
    providerType = model.ServiceOpenid            // silent reroute
}
provider := einterfaces.GetOAuthProvider(providerType)
if provider == nil {
    return nil, model.NewAppError(..., "api.user.login_by_oauth.not_available.app_error", ...)
}
```

The moment the scope string contains `"openid"` as a raw substring (not a parsed, space-delimited token), Mattermost stops treating this as a GitLab login and goes looking for a registered OpenID provider. Team Edition doesn't register one. `GetOAuthProvider("openid")` returns `nil`, and the user is told SSO "is not available on this server." That reads like a licensing problem. It's actually a substring match firing on the wrong string.

Lay the two failures side by side and the shape of the trap is obvious:

```
      scope left unset                          scope = "openid profile email"
             │                                              │
             ▼                                              ▼
  Keycloak issues a plain OAuth2               Mattermost's getSSOProvider() sees
  token — no "openid" in the                   "openid" as a substring, reroutes to
  scope claim                                  the OpenID provider
             │                                              │
             ▼                                              ▼
  /userinfo → 403 insufficient_scope           GetOAuthProvider("openid") → nil
  "Missing openid scope"                       (Team Edition ships none)
             │                                              │
             ▼                                              ▼
  "Received invalid response from              "Gitlab SSO through OAuth 2.0
   OAuth service provider."                      not available on this server."
```

There's no third value to try. Every string you can put in `MM_GITLABSETTINGS_SCOPE` either omits `openid`, and Keycloak rejects the token, or contains it, and Mattermost reroutes off the GitLab provider. Neither side is misconfigured. It's two reasonable defaults that happen to be mutually exclusive.

We weren't the first to hit this. The same question sits, unanswered, on the [keycloak-user mailing list](https://groups.google.com/g/keycloak-user/c/MxsCK-9oxmI). The obvious ask, a Keycloak flag to relax the `/userinfo` scope check for legacy integrations like this, was raised and [closed as not planned](https://github.com/keycloak/keycloak/issues/32973). There's no config-only escape.

---

## The question that actually breaks the deadlock

Every fix so far assumed the scope claim on the token is a direct echo of what Mattermost asked for. That assumption is the trap. Look again at Keycloak's `/userinfo` check:

```java
if (!TokenUtil.hasScope(token.getScope(), OAuth2Constants.SCOPE_OPENID)) {
```

It reads `token.getScope()`, the claim that ended up on the issued token, not the `scope` parameter the client sent on the authorize request. Those two are related but not the same. Keycloak doesn't build the claim purely from client input; it builds it from the names of the client scopes attached to the client:

```java
// DefaultClientSessionContext.getScopeString() (simplified)
String scopeParam = getClientScopesStream()
        .filter(scope -> scope.isIncludeInTokenScope() || ignoreIncludeInTokenScope)
        .map(ClientScopeModel::getName)        // <-- the client scope's NAME, not the request
        .collect(Collectors.joining(" "));
```

The key detail: default client scopes are applied to every token issued to that client, whether or not the authorize request mentioned them. That exists so an admin can guarantee certain claims land on every token without trusting each client to ask for them correctly. Which is exactly our situation, except we're using it to inject a scope *name* rather than a claim value.

So: create a Keycloak client scope literally named `openid`, set its type to **Default** (not Optional), and turn on **Include in token scope**. It needs no mappers. It just has to exist and be attached.

```
Client scope "openid"
  Type:                   Default
  Protocol:               openid-connect
  Include in token scope: On
        │
        ▼
 attach to the Mattermost client as a Default client scope
        │
        ▼
 every token minted for this client carries "openid" in its scope claim
        │
        ├──▶ Keycloak: /userinfo sees "openid" in token.getScope() → 200
        └──▶ Mattermost: MM_GITLABSETTINGS_SCOPE stays unset →
             getSSOProvider() never sees the substring → stays on the GitLab provider
```

Leave `MM_GITLABSETTINGS_SCOPE` unset. That's the part that feels wrong until you trace it through. Mattermost never asks for `openid`, so it never trips its own substring check and never reroutes off the GitLab provider. Keycloak stamps `openid` into the scope claim anyway, because the client scope is attached as a default, independent of what the client requested. `/userinfo` reads the claim, is satisfied, and returns `200`.

Both jaws of the trap open at once, because the fix doesn't argue with either assumption directly. It moves responsibility for satisfying Keycloak's contract onto the side of the handshake that can actually satisfy it. Mattermost was never going to ask for `openid` safely, so stop making it ask.

We reproduced this from scratch against a clean Keycloak 26.7.0 container, to rule out anything specific to our realm's history. With no `scope` parameter on the authorize request, the token's scope claim came back `email openid profile`, and `/userinfo` returned `200` with a populated, non-zero `id`. Detaching the client scope flipped it straight back to `403 insufficient_scope`. Nothing else changed between the two runs.

One clarification, because it matters: no ID token is issued or consumed anywhere in this flow, and Mattermost never becomes an OIDC client. Only the access token's `scope` claim changes.

---

## Making Keycloak's `/userinfo` answer look like GitLab's

Getting past the scope check earns you a `200`, but not a usable one. Mattermost still has to parse the body. The GitLab provider decodes `/userinfo` straight into this struct:

```go
type GitLabUser struct {
    Id       int64  `json:"id"`
    Username string `json:"username"`
    Login    string `json:"login"`
    Email    string `json:"email"`
    Name     string `json:"name"`
}
```

and `IsValid()` rejects it outright if `Id == 0` or `Email` is empty.

Two things make this awkward. First, Keycloak's `sub` claim is a UUID, so there's no numeric identity on a default Keycloak user to satisfy an `int64 id`. Second, Keycloak stores every user attribute as a string, and Go's `encoding/json` won't coerce a quoted `"42"` into an `int64` field tagged plain `json:"id"`. You get `cannot unmarshal string into Go struct field GitLabUser.id of type int64`, and the user sees a login failure with no explanation.

The fix is to store a numeric ID as a Keycloak user attribute, then add five protocol mappers on the client's dedicated scope (not the shared `profile` scope, for reasons that follow):

| Claim | Mapper type | Source | Claim JSON type |
|---|---|---|---|
| `id` | User Attribute | user attribute `id` | **long** |
| `username` | User Property | `username` | String |
| `login` | User Property | `username` | String |
| `email` | User Property | `email` | String |
| `name` | User's full name | — | — |

Every row here has a way to fail silently:

- **`id`'s JSON type has to be `long`, not `String`.** Get it wrong and you're back to the `int64` unmarshal error above, with nothing actionable in the message.
- **"Add to userinfo" has to be on for all five.** The GitLab provider never reads the ID token; Mattermost's OAuth client only ever calls the `UserAPIEndpoint`, which is `/userinfo`. A mapper that's perfect except for this one toggle produces claims that exist and are never sent anywhere.
- **`username` and `login` both need explicit mappers pointed at the `username` property.** Keycloak's built-in `profile` scope emits `preferred_username`, and `GitLabUser` has no field by that name, so the claim gets dropped.
- **The mapper's source has to match the User Profile attribute's internal name, not its display label.** If you give the attribute a friendly label in the admin console ("Mattermost ID," say), it's easy to wire the mapper to the label by mistake. Then no claim is emitted, Mattermost reads `Id: 0`, `IsValid()` rejects it, and you get no error to grep for, just a failed login.

Two more landmines, both specific to jumping from an older Keycloak straight to a modern one:

**Keycloak 24+ turns on the declarative User Profile and disables unmanaged attributes by default.** A custom attribute has to be declared in the realm's User Profile schema before Keycloak will store it. Set it on a user without declaring it and the write silently no-ops.

**The numeric ID is a join key, not a display field.** If users previously logged in through this same GitLab-shaped flow, Mattermost already has their GitLab numeric ID and matches new logins against it. Whatever lands in the Keycloak attribute has to equal what's already stored, or every returning user gets a fresh empty account instead of their real one. Mattermost's REST API strips this field from every response (neither `mmctl` nor the System Console will show it), so the only place to read the existing values is Postgres:

```sql
SELECT username, email, authdata
FROM users
WHERE authservice = 'gitlab' AND deleteat = 0
ORDER BY username;
```

---

## Checking the contract without touching Mattermost at all

The single most useful thing in this whole exercise is a Keycloak feature that has nothing to do with Mattermost: **Clients → your client → Client scopes → Evaluate**.

Leave the scope parameter on that screen empty (that's exactly what Mattermost sends) and read the "Generated user info" panel. It shows the literal JSON body `/userinfo` will return under your current mapper and default-scope setup, including whether `id` comes out as a bare number or a quoted string. You can change mappers and default scopes and watch the wire contract change live, with no deploys and no test logins against the real app.

Run that once before any IdP cutover that touches an integration like this, and there's no incident to write up afterward.

---

## The shim has an expiry date

This whole thing is a narrow shim: a scope-claim trick layered onto an OAuth-shaped integration so it satisfies Keycloak's `/userinfo` contract. It's deliberate, and it comes with a built-in expiry date.

Mattermost **v11** moves the GitLab login button behind the same license gate as native OIDC. `EnableSignUpWithGitLab` now lives inside `if *license.Features.OpenId` in `server/config/client.go`. On an unlicensed v11 the button stops rendering, though the server-side `/oauth/gitlab/login` route still works, so a direct link is a stopgap if you're caught mid-upgrade. Here's the part that closes the loop: any license tier that gives you the GitLab button back also unlocks native OIDC. Once you're there, delete this shim entirely (the fake client scope, the five mappers, the numeric-ID join key) and use Mattermost's real OIDC provider instead. We're on 10.11.14 as I write this, with the ESR line's end-of-life a few weeks out. Whichever upgrade crosses that license boundary is the same one that makes this whole post unnecessary.

---

## The pattern underneath

Take Mattermost and Keycloak out of it and what's left is a config value overloaded to mean two unrelated things, on two sides of an integration, where satisfying one meaning breaks the other. Keycloak reads the scope claim as "which capabilities does this token carry." Mattermost reads the scope string as "which provider should handle this login." Neither reading is wrong on its own. Wired together, nothing the client can send satisfies both.

The way out was never a cleverer value for the setting; there wasn't one. It was noticing that one side builds the claim from its own server-side config, independent of the client, and routing through that instead of the path that kept fighting itself. When a config value is stuck like this, the useful question usually isn't "what goes here." It's "does this have to come from the client at all, or can the side that enforces the rule just satisfy it itself?"

---

*This was Mattermost Team Edition, self-hosted on Kubernetes. The outage lasted about eighty minutes, nearly all of it spent reading Mattermost and Keycloak source rather than changing anything. Five minutes in the Evaluate tab before the upgrade, instead of after, would have caught it for free.*
