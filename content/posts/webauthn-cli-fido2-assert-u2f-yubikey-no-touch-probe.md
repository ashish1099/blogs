---
title: "The No-Touch Probe a YubiKey 4 Can't Answer: WebAuthn Logins from a Go CLI"
date: 2026-10-29T09:00:00+05:30
draft: true
tags: ["webauthn", "fido2", "u2f", "yubikey", "libfido2", "keycloak", "go", "cli", "testing"]
author: "Ashish Jaiswal"
summary: "Our internal CLI logs in through Keycloak and signs the security-key step itself by shelling out to libfido2's fido2-assert. It worked until an account had two registered keys: the silent 'does this key hold this credential?' probe fails on U2F-only keys like the YubiKey 4, so login claimed none of the connected keys was registered. This post covers why the probe can't work there, the fix that still costs exactly one tap, and how to test it without hardware."
showToc: true
TocOpen: true
---

## The Setup

Our internal time-registration CLI used to log in with a password. Then the API dropped password login and moved everything to Keycloak, using the OAuth2 authorization-code flow with PKCE. A colleague did the migration, and one of the design choices is that the default `login` never opens a browser. The CLI fetches Keycloak's login page, submits the form with ordinary HTTP requests the way a browser would, and reads the authorization code out of the redirect without following it.

That is easy for passwords and one-time codes. Security keys are the interesting case, because normally the *browser* talks to the key. Without one, the CLI has to be the WebAuthn client.

## The CLI Is the WebAuthn Client

Everything `navigator.credentials.get()` does for a web page, the CLI does by hand:

1. Pull the challenge, the relying party ID and the list of registered credential IDs out of Keycloak's security-key page.
2. Build the client data JSON itself: `{"type":"webauthn.get","challenge":"...","origin":"https://login.example.com","crossOrigin":false}`.
3. Ask the key to sign it by running libfido2's `fido2-assert -G`, which reads a small text file: the base64 client data hash, the relying party ID, and **one** base64 credential ID.
4. Post back the same form fields the page's JavaScript would: `clientDataJSON`, `authenticatorData`, `signature`, `credentialId` and `userHandle`.

Look at step 3 again: one credential ID per run. An account can have several registered credentials (I have two YubiKeys registered), and `fido2-assert` signs with whichever one you hand it. So before signing, the CLI has to answer a question: which of these credentials does the plugged-in key actually hold?

## First Version: Ask Silently

The first version answered with a probe. With exactly one key and one credential it skipped straight to signing. Otherwise it tried every (key, credential) pair with a no-touch assertion, `fido2-assert -G -t up=false`, and used the first pair that didn't error. Trimmed down:

```go
for _, device := range devices {
    for _, id := range credentialIDs {
        _, err := runAssert([]string{"-G", "-t", "up=false"}, device, rpID, clientDataHash, id, false)
        if err == nil {
            return device, id, nil
        }
    }
}
return "", nil, errors.New("none of the connected security keys is registered for this account")
```

(`runAssert` is a thin wrapper: write the input file, run the tool, decode the base64 output lines.)

The idea is sound on FIDO2 keys. `up=false` tells the key not to wait for user presence, so a key that holds the credential answers silently and one that doesn't says no. No blinking, no tapping, no guessing.

## Where It Broke

With two credentials registered and the YubiKey 4 plugged in, login failed with "none of the connected security keys is registered for this account". The key *was* registered.

The YubiKey 4 is a U2F-only device, and U2F-only keys can't do a no-touch assertion. Every probe failed, including the one for the credential the key actually holds, and the code reasonably concluded that nothing matched.

It had stayed hidden because of the shortcut. With one key and one credential there is no probe at all, so the fragile path only ran for accounts with two or more credentials. Mine had two.

## The Fix: Just Try Each One

If a silent probe isn't available, the question "does this key hold this credential?" can still be answered by attempting a real assertion and letting the key say no. Trimmed:

```go
touch() // tell the user to touch the key, once
var lastErr error
for _, device := range devices {
    for _, id := range credentialIDs {
        out, err := runAssert(args, device, rpID, clientDataHash, id, userVerification)
        if err != nil {
            lastErr = err
            continue
        }
        // parse authenticator data and signature, return the assertion for id
    }
}
return nil, fmt.Errorf("none of the connected security keys is registered for this account: %w", lastErr)
```

This still costs exactly one tap. A key rejects a credential it doesn't hold immediately, before it ever asks for presence (a U2F key answers "wrong data", a CTAP2 key "no credentials"). So the only attempt that blocks waiting for a finger is the one for the credential the key really holds. And once it succeeds, the CLI knows *which* credential signed, which Keycloak needs in the `credentialId` field.

Two details worth keeping:

- **Why not hand over the whole allow-list in one call?** It would be fewer round-trips, but `fido2-assert` doesn't report which credential a U2F key used, and the server needs that answer.
- **Terminal handling.** The terminal is only attached to `fido2-assert` when a PIN may have to be typed (user verification). Otherwise stderr is captured, so the instant rejections don't spray errors across the prompt. The last error is wrapped into the final message if nothing matches, so a real failure (permission denied on the device, say) isn't swallowed.

## Testing It Without a YubiKey

I didn't want a test that needs hardware on the desk. The CLI shells out to two tools, so the test replaces the tools: it writes fake `fido2-token` and `fido2-assert` shell scripts into a temp directory and puts that first in `PATH`.

The fake `fido2-assert` appends its input to a file, so the test can inspect which credentials were tried and with which flags. It also behaves like a real key that holds only one credential, exiting 1 for everything else:

```sh
held='<base64 of the credential this fake key holds>'
if [ -n "$held" ] && [ "$(sed -n 3p "$in")" != "$held" ]; then exit 1; fi
```

The test then asserts three things: the returned credential is the held one, both credentials were attempted, and `up=false` never appears in the recorded arguments. The last assertion is the one I like most, because it pins the invariant the bug taught me ("don't depend on a silent probe") instead of only checking the happy path. After that I confirmed it against the real key.

## A Packaging Gotcha

`fido2-assert` ships in the `fido2-tools` package, and on Ubuntu 24.04 mine wouldn't install: an orphaned `libfido2-1` build from a jammy PPA (1.15.0~ppa~jammy1) was on the box, and apt wouldn't mix it with the archive's `fido2-tools` 1.14. Pinning both packages to the archive version in a single command sorted it out:

```sh
sudo apt install --allow-downgrades libfido2-1=1.14.0-1build3 fido2-tools=1.14.0-1build3
```

(Those are the 24.04 archive versions; check `apt-cache policy libfido2-1` for yours.)

## Takeaways

- **Test optional protocol features on the oldest authenticator you support.** `up=false` is a perfectly good silent probe on a FIDO2 key and not available on a YubiKey 4.
- **A fast path for the common case can hide a broken slow path.** One key and one credential never touched the probe, so the first person to register a second key found the bug.
- **With U2F, "try it and see" is the native shape.** A key that doesn't hold a credential rejects it at once and silently, so walking the allow-list costs a few process spawns and no extra taps.
- **Fake the tool, not the hardware.** A stand-in `fido2-assert` that rejects the wrong credentials covers the multi-credential path in a plain unit test.
