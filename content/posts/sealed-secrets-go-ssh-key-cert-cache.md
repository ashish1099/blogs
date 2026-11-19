---
title: "Sealing SSH Keys in Go with a TTL Cert Cache for Bitnami Sealed Secrets"
date: 2026-04-14
tags: ["go", "kubernetes", "sealed-secrets", "security", "concurrency"]
categories: ["development"]
---

## The Problem

You want to provision an SSH private key into a Kubernetes cluster without storing it in plaintext in Git.
Bitnami Sealed Secrets is the standard answer: you encrypt the secret with the controller's public key, commit the ciphertext, and the controller decrypts it in-cluster.

But if you want to do this programmatically in Go — for example, as part of a cluster bootstrap tool — there are a few non-obvious things to get right:

1. The full client-side sealing flow (building the Secret, fetching the cert, encrypting, applying the CR)
2. The controller renews its sealing key every 30 days by default, so you should not hardcode or cache its cert forever
3. In a concurrent service, naive cert fetching causes a thundering herd on every cache miss

This post walks through all three.

## Generating the SSH Key

```bash
ssh-keygen -t ed25519 -C "deploy@example.com" -f deploy_key -N ""
```

This gives you `deploy_key` (private) and `deploy_key.pub` (public). The private key is what you want to seal.

## The Full Sealing Flow in Go

The Bitnami Sealed Secrets Go library (`github.com/bitnami/sealed-secrets/pkg/apis/sealedsecrets/v1alpha1`, under `github.com/bitnami-labs/sealed-secrets` before v0.38.0) handles the crypto. The flow is:

```go
import (
    "context"
    "fmt"

    ssv1 "github.com/bitnami/sealed-secrets/pkg/apis/sealedsecrets/v1alpha1"
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/dynamic"
    "k8s.io/client-go/kubernetes/scheme"
)

func sealSSHKey(ctx context.Context, dynClient dynamic.Interface, privKeyBytes []byte, namespace string) error {
    // 1. Build a plain Secret
    secret := &corev1.Secret{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "ssh-deploy-key",
            Namespace: namespace,
        },
        Data: map[string][]byte{
            "id_ed25519": privKeyBytes,
        },
    }

    // 2. Fetch the controller's public key from its cert
    pubKey, err := fetchControllerCert(ctx)
    if err != nil {
        return fmt.Errorf("fetch cert: %w", err)
    }

    // 3. Seal
    sealedSecret, err := ssv1.NewSealedSecret(scheme.Codecs, pubKey, secret)
    if err != nil {
        return fmt.Errorf("seal: %w", err)
    }

    // 4. Apply the SealedSecret CR
    return applySealedSecret(ctx, dynClient, sealedSecret)
}
```

The `fetchControllerCert` call hits the controller's `/v1/cert.pem` endpoint through the API server's service proxy, the same way `kubeseal` does, and parses the PEM with `kubeseal.ParseKey` (from `github.com/bitnami/sealed-secrets/pkg/kubeseal`) into the `*rsa.PublicKey` that `NewSealedSecret` takes. The `applySealedSecret` call uses the dynamic client to create or update the `SealedSecret` custom resource.

## Why the Cert Cache Matters

The controller renews its sealing key every 30 days by default, and `/v1/cert.pem` serves the cert of the newest key. If you fetch the cert on every sealing operation, you pay an API round-trip each time and put unnecessary load on the controller in high-frequency scenarios. But if you cache it naively without expiry, your cached cert will eventually become stale after a renewal. Secrets sealed with it still decrypt, because the controller keeps old keys, but every new secret keeps getting sealed with the old key. After an early renewal for a suspected compromise (`--key-cutoff-time`), that means sealing new secrets with the compromised key. And if someone prunes old keys by hand, the secrets sealed with them can no longer be decrypted.

The right answer is a TTL cache, which bounds how long you keep sealing with a superseded key after a renewal.

## TTL Cert Cache with Double-Check Locking

```go
type certCache struct {
    mu        sync.RWMutex
    key       *rsa.PublicKey
    fetchedAt time.Time
    ttl       time.Duration // 25 days
}

func (c *certCache) get(ctx context.Context) (*rsa.PublicKey, error) {
    // Fast path: read lock only
    c.mu.RLock()
    if c.key != nil && time.Since(c.fetchedAt) < c.ttl {
        key := c.key
        c.mu.RUnlock()
        return key, nil
    }
    c.mu.RUnlock()

    // Slow path: take write lock and re-check
    c.mu.Lock()
    defer c.mu.Unlock()

    // Double-check: another goroutine may have refreshed while we waited
    if c.key != nil && time.Since(c.fetchedAt) < c.ttl {
        return c.key, nil
    }

    key, err := fetchControllerCertFromAPI(ctx)
    if err != nil {
        return nil, err
    }
    c.key = key
    c.fetchedAt = time.Now()
    return key, nil
}
```

The double-check pattern matters in any service that handles concurrent sealing requests. Without it, every goroutine that finds a stale cache simultaneously races to the write lock and fires a redundant API call. With it, only the first one through the write lock does the actual fetch (as long as it succeeds); all others re-read the freshly cached cert.

## Why 25 Days?

The Sealed Secrets controller renews its key every 30 days by default (`--key-renew-period=720h`). With the TTL at 25 days:

- Secrets sealed with a superseded cert are still valid (the controller keeps old keys for decryption)
- Your cache will never serve a cert fetched more than 25 days ago
- A renewal can land right after a fetch, so you may keep sealing with the previous key for up to 25 days

So the TTL is the longest you keep sealing with a superseded key, and nothing ties the 25 days to the 30-day renewal period. No TTL value breaks decryption, so size it by how quickly new secrets should move to a renewed key, whatever `--key-renew-period` the controller runs with. After an early renewal for a suspected compromise, restart the service, since the cache only refreshes at startup or when the TTL expires.

## Startup Integration

Populate the cache eagerly at startup and fail fast if the controller is unreachable:

```go
func main() {
    ctx := context.Background()

    cache := &certCache{ttl: 25 * 24 * time.Hour}

    // Fail fast — if the controller is not reachable, there is no point continuing
    if _, err := cache.get(ctx); err != nil {
        log.Fatalf("sealed secrets controller unreachable at startup: %v", err)
    }

    // From here, cache.get(ctx) is safe to call from any goroutine
    // and will transparently refresh after 25 days
}
```

Eager population means your first real sealing request hits the fast path (RLock only) rather than blocking on the initial fetch under load.

## Key Takeaways

- The Bitnami Sealed Secrets Go library handles all crypto; your job is to wire up the Secret, fetch the cert, and apply the CR
- Never hardcode or cache the controller cert indefinitely. The controller renews its key every 30 days by default, and new secrets should use the newest key
- Old keys keep decrypting, so the TTL only bounds how long you seal with a superseded key; after an early renewal, restart to refresh the cache
- Double-check locking on the cache prevents thundering herd under concurrent load
- Fail fast at startup: if the controller is unreachable, surface the error immediately rather than deferring it to the first sealing operation
