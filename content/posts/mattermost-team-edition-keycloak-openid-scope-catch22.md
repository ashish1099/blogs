---
title: "How to Make Mattermost Team Edition Work with Keycloak 20 and Above"
date: 2026-07-14T09:00:00+05:30
draft: false
tags: ["mattermost", "keycloak", "sso", "oauth", "oidc", "gitlab", "kubernetes", "self-hosted"]
author: "Ashish Jaiswal"
summary: "Any Keycloak from 20 onward enforces the openid scope on /userinfo, which breaks Mattermost Team Edition's Keycloak-as-GitLab SSO. The fix everyone tries first makes it worse. Here's what actually breaks, and the one client scope on Keycloak's side that makes it work."
showToc: true
TocOpen: true
---

I pointed a working Mattermost 10 Team Edition at a newer Keycloak 26. Nothing changed on the Mattermost side but the endpoint URLs and the client secret, yet every SSO login broke immediately. The only clue was an unhelpful error: *"Received invalid response from OAuth service provider."*

So I went looking for the setting that was obviously wrong, and found one: an empty `scope` where both the docs and common sense say `openid` belongs. I set it. Login broke again, this time with a different error pointing at a completely different part of the system: *"Gitlab SSO through OAuth 2.0 not available on this server."*

That second failure is what this post is about. It's a genuine catch-22 between Mattermost Team Edition and Keycloak: two pieces of software, neither one misconfigured, whose defaults happen to be mutually exclusive. The fix isn't a smarter value for that setting. There isn't one. It lives on the Keycloak side.

Here is the whole arrangement in one picture, before any code. Mattermost's built-in GitLab provider is aimed at Keycloak, and the two boxes on the right, a client scope named `openid` and a set of protocol mappers, are the entire fix. Everything below is why each piece has to be there.

![Architecture: Mattermost Team Edition's GitLab OAuth provider aimed at Keycloak 20+, with a Default client scope named openid feeding the token endpoint and five dedicated protocol mappers shaping the userinfo response.](/images/mattermost-keycloak-architecture.svg)

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

There's nothing exotic about this. OAuth 2.0 doesn't care what the provider calls itself, only that the endpoints behave the way the client expects. (Both sides here were self-hosted on Kubernetes, but that's incidental; the contract below holds no matter how either is deployed.) I'd been running this setup for years across Keycloak 19 and 20 without touching it.

None of that changed when I moved to Keycloak 26. The trigger was entirely on the new server, and it starts at one endpoint.

---

## Failure one: Keycloak now insists on the `openid` scope

Since Keycloak **19.0.2** (so in practice every Keycloak 20 and above), the `/userinfo` endpoint enforces something that was always technically correct: UserInfo is an OIDC feature, not a plain OAuth 2.0 one, and Keycloak won't answer for a token that never asked for OIDC. The check is blunt:

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

The thing to notice is that my configuration hadn't changed in any way that should matter. The exact same environment variables had worked against Keycloak 19 and 20. What changed was the enforcement on Keycloak's side, not anything on mine.

---

## Failure two: the obvious fix reroutes you into a wall

The error all but tells you the fix, and Keycloak literally names the missing thing: "openid scope." Every SSO integration guide agrees. Set the scope.

```yaml
MM_GITLABSETTINGS_SCOPE: "openid profile email"
```

Login breaks again. Different error this time:

> Gitlab SSO through OAuth 2.0 not available on this server.

This one is stranger. It doesn't read like a Keycloak problem at all; it reads like Mattermost thinks GitLab SSO was never configured, even though the only thing I'd changed was one line of config.

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

![The catch-22: with the scope unset, Keycloak rejects /userinfo with 403 Missing openid scope; with the scope set to openid, Mattermost reroutes to an OpenID provider Team Edition does not ship. Both paths end in a failed login.](/images/mattermost-keycloak-catch22.svg)

There's no third value to try. Every string you can put in `MM_GITLABSETTINGS_SCOPE` either omits `openid`, and Keycloak rejects the token, or contains it, and Mattermost reroutes off the GitLab provider. Neither side is misconfigured. It's two reasonable defaults that happen to be mutually exclusive.

I wasn't the first to hit this. The same question sits, unanswered, on the [keycloak-user mailing list](https://groups.google.com/g/keycloak-user/c/MxsCK-9oxmI). The obvious ask, a Keycloak flag to relax the `/userinfo` scope check for legacy integrations like this, was raised and [closed as not planned](https://github.com/keycloak/keycloak/issues/32973). There's no config-only escape.

---

## The fix: put openid on the token from Keycloak's side

You can't win this from Mattermost's config. Leave the scope empty and Keycloak returns a 403; set it to `openid` and Mattermost reroutes. So take Mattermost out of it: leave the setting empty and have Keycloak put `openid` on the token itself.

That works because Keycloak's `/userinfo` check reads the token, not the request:

```java
if (!TokenUtil.hasScope(token.getScope(), OAuth2Constants.SCOPE_OPENID)) {
```

`token.getScope()` is the scope claim on the issued token, and Keycloak builds that claim from the names of the client scopes attached to the client, not from what the client asked for:

```java
// DefaultClientSessionContext.getScopeString() (simplified)
String scopeParam = getClientScopesStream()
        .filter(scope -> scope.isIncludeInTokenScope() || ignoreIncludeInTokenScope)
        .map(ClientScopeModel::getName)        // <-- the client scope's NAME, not the request
        .collect(Collectors.joining(" "));
```

A **Default** client scope is applied to every token for that client, whether the request asked for it or not. So give the Mattermost client a default scope whose name happens to be `openid`:

- Create a client scope named `openid`, type **Default**, with **Include in token scope** turned on. It needs no mappers; it only has to exist.
- Attach it to the Mattermost client as a default scope.
- Leave `MM_GITLABSETTINGS_SCOPE` empty.

Mattermost never sends `openid`, so it stays on the GitLab provider. Keycloak adds `openid` to the token's scope claim anyway, so `/userinfo` returns `200`. Both errors are gone at once.

I checked this on a clean Keycloak 26.7.0. With no scope on the request, the token's scope claim came back `email openid profile` and `/userinfo` returned `200` with a non-zero `id`. Remove the `openid` client scope and it drops straight back to `403`.

To be clear about what this is not: no ID token is issued, and Mattermost never becomes an OIDC client. Only the access token's scope claim changes.

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

## This breaks on Mattermost v11

Worth knowing before you build this: it stops working on Mattermost v11. The GitLab login button moves behind the same license gate as OIDC. In `server/config/client.go`, `EnableSignUpWithGitLab` now sits inside `if *license.Features.OpenId`, so on an unlicensed v11 the button just doesn't render. The `/oauth/gitlab/login` route still works server-side, so a direct link will get you through an upgrade if you're stuck.

The catch: any license that brings the button back also gives you native OIDC. Once you have that, drop all of this (the client scope, the mappers, the numeric-ID attribute) and point Mattermost at Keycloak as a proper OIDC provider. I'm on 10.11.14 (Team Edition, ESR) for now, so it holds until I upgrade.

---

## The pattern underneath

Take Mattermost and Keycloak out of it and what's left is a config value overloaded to mean two unrelated things, on two sides of an integration, where satisfying one meaning breaks the other. Keycloak reads the scope claim as "which capabilities does this token carry." Mattermost reads the scope string as "which provider should handle this login." Neither reading is wrong on its own. Wired together, nothing the client can send satisfies both.

The way out was never a cleverer value for the setting; there wasn't one. It was noticing that one side builds the claim from its own server-side config, independent of the client, and routing through that instead of the path that kept fighting itself. When a config value is stuck like this, the useful question usually isn't "what goes here." It's "does this have to come from the client at all, or can the side that enforces the rule just satisfy it itself?"

---

*This was Mattermost Team Edition, self-hosted on Kubernetes. The outage lasted about eighty minutes, nearly all of it spent reading Mattermost and Keycloak source rather than changing anything. Five minutes in the Evaluate tab before the upgrade, instead of after, would have caught it for free.*
