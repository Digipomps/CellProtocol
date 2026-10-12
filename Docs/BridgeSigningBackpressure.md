# Proof backpressure before an operation takes effect

Candidate implementation; not a deployment claim.

`CellScaffold` selects `localProtection` outside its testing environment. Its
default signing policy permits 12 attempts per 60 seconds. A correspondence
operation can need more than one origin proof. A large attachment therefore
reaches this limit even when its sender and Agreement are valid. Testing only
with `monitorOnly` misses that boundary.

The limit, denial accounting, proof validation, Agreement checks, storage
quotas and free-space reserve are unchanged. A denied attempt still consumes
the existing limiter's accounting. A retry starts a fresh operation and must
pass all of its checks again; it does not reuse an identity proof.

## Reply contract

An outbound origin-signing request rejected by the local signing limiter
produces `BridgeSigningBackpressure`. The command's `BridgeIdentityVault`
records that diagnostic. The state belongs to that proxy, not to a shared
bridge-wide last-error slot. The proxy unwraps `AsyncError.other` only to retain
this specific failure; shared Combine behavior is unchanged.

At the initial explicit authorization gate of the final `CorrespondenceCell`,
a rejection is bound to that exact receiver object and keypath. Only when they
match the bridge's top-level operation may its SET error include the optional
positive integer `retryAfterSeconds`. A late `CellAuthorizationError`, a raw
signing error, or a child-cell rejection propagated through a parent does not
qualify. Other cells retain their existing authorization error. Older SET
replies decode without the field; older clients still treat it as an error.

Correspondence also checks authority inside its attachment handler and before
publication. These known pre-storage rejection points throw the same internal,
receiver-bound rejection. Only BridgeBase creates the SET retry field after
validating the binding. Application SET return values never become retry hints.
An initial GET rejection uses the reserved wire error object below, likewise
created by BridgeBase only after validating the receiver binding:

```json
{
  "status": "error",
  "message": "attachmentUnavailable",
  "&bridgeRetry": "signing_before_effect.v1",
  "reasonCode": "signing_rate_limited",
  "retryAfterSeconds": 60
}
```

The `&bridgeRetry` marker is reserved protocol metadata. Ordinary application
objects with `status`, `reasonCode` and `retryAfterSeconds` but without the
marker are not interpreted as protocol backpressure. SET application payloads
are never interpreted as that marker. No identity, storage path, request value or
signing material is included.

`BridgeBase.get/set` exposes the typed error to a new client. It does not retry
the operation itself. Storage errors, transport failures, timeouts, quarantine
and ordinary opaque `attachmentUnavailable` replies do not become retry hints.
In particular, a failure after a storage effect retains its unknown outcome.

## Caller responsibility

A caller may wait and retry only this explicit pre-effect rejection. A quota
wait does not replace the authenticated connection. Native channels retain their
existing five-minute lifetime; normal expiry requires a new authenticated
connection before the next operation. The native signing budget now follows
the verified principal, endpoint and logical publisher/consumer across bridge
instances, so this renewal cannot reset the quota. Multiple connections to that
same scope share the budget; peer/legacy transport scopes are unchanged. Cancellation, a finite retry budget
and an upper bound on remotely requested waiting are required. Retention and
expiry still apply during a long transfer.

The paired HavenAgentD change waits at most 120 seconds per hint and retries at
most three times per operation. It never retries a generic SET failure or opaque
attachment error. Both server and client revisions are required for automatic
recovery; old servers continue to fail closed without automatic guessing.

## Regression boundaries

`BridgeSigningBackpressureTests` exercises the unchanged production quota at
the outer revoke and inner upload authorization boundaries, legacy replies,
ordinary application objects and an error after a simulated storage effect.
The paired client tests cover bounded retry, cancellation and unknown outcomes.
Its separate authenticated loopback test transfers and revokes a 1,100,037-byte
fixture in both directions with the real default quota and checks that any
replacement connection follows normal expiry. A protocol regression proves
that a newly authenticated channel cannot reset the quota. Consult the k15 handoff for measured results and platform limits;
test existence alone is not a passing result.
