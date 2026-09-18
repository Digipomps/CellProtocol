# CellNearby — finding a human entity's invitation

Optional Apple transport adapter, separate from CellBase semantics. The shared
offer model uses Foundation; discovery uses Network (`NWBrowser`, `NWListener`).
It does not enroll a scaffold, service, administrator or agent as a human.

The user explicitly publishes an existing person-entity invitation for at most
five minutes. Bonjour `_haven-link._tcp` TXT contains only version, exact trusted
HTTPS origin, random 256-bit offer ID and expiry. No person name, identity key,
EntityAnchor reference or capability is broadcast. A nearby party can redeem the
published invitation over HTTPS and see its invitation label; publication must
therefore be opt-in. The listener rejects all TCP connections. An advertisement,
device name or proximity gives no authority.

After selection the browser stops. The client retrieves the invitation at the
independently trusted HTTPS origin, rejects redirects and reviews both personal
entities with the user. Existing enrollment signatures, independently calculated
control words, fresh user authentication and runtime policy decide the link.
Keep permissions, roles and agent delegation out of this discovery adapter.

Supported package minimums are macOS13 and iOS16. The APIs are available earlier
(NWBrowser macOS10.15/iOS13), so no Multipeer fallback is needed for those minimums.
Existing MPC peers use their existing protocol or QR; Network cannot speak MPC's
wire protocol. Wi-Fi Aware and its newer hardware are not required. This package
does not promise continuous background discovery on iOS. Stop on dismissal or
background, and include NSLocalNetworkUsageDescription / NSBonjourServices in
the containing application. Browser discovery is bounded to two minutes.

References checked 2026-09-11:

- [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [Apple TN3111](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)
- [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Standalone candidate test

Run from this package directory:

```sh
swift test -j 2 --disable-automatic-resolution
python3 Scripts/smoke_nearby.py --binary .build/debug/haven-nearby
```

The smoke test creates two actual Network processes, advertises a synthetic
unresolvable invitation, verifies discovery and expiry, and stops its processes.
It does not connect to staging or establish a person link. Local-network access
is required. A physical iPhone/Mac test and the full owner approval ceremony
remain separate gates.

Install the `haven-nearby` companion next to sprout, or point the candidate CLI's
`SPROUT_NEARBY_HELPER` at the built binary. `sprout nearby browse` and
`sprout nearby advertise --offer-file …` then use this exact adapter, with no copy
of protocol authority or heavy CellBase dependency in sprout's core.
