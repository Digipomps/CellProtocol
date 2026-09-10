# Dependency security review, 2026-09-10

The initial 34-pin Package.resolved was queried against OSV using both Swift
package versions and immutable Git commits. The commit queries found four
advisories. An empty version-query result alone was not evidence of safety.
Maintainer advisories and the actual dependency graph were then checked.

| Dependency | Previous pin | New pin | Maintainer fix |
| --- | --- | --- | --- |
| swift-nio | 2.94.1 | 2.102.0 | 2.101.0; [CVE-2026-43678](https://github.com/apple/swift-nio/security/advisories/GHSA-qcc5-f287-vgmq) |
| swift-nio-ssl | 2.36.0 | 2.37.4 | 2.37.2; [CVE-2026-43820](https://github.com/apple/swift-nio-ssl/security/advisories/GHSA-xfxg-9975-pc2j) |
| swift-nio-http2 | 1.39.1 | 1.46.0 | 1.45.0; [CVE-2026-64785](https://github.com/apple/swift-nio-http2/security/advisories/GHSA-q3g2-m552-3r9c) |
| swift-crypto | 3.15.1 | 4.5.2 | 4.5.1; [CVE-2026-43823](https://github.com/apple/swift-crypto/security/advisories/GHSA-8q93-f6xh-4f6f) |

The WebSocket decoder could trap on an oversized wire length before applying
its frame-size limit. This is directly relevant to WebSocket hosts. The TLS SAN
API could read outside its intended memory object for non-string SAN types.
The HTTP/2 header validation gap matters particularly for HTTP/2-to-HTTP/1
forwarding; the standard NIO HTTP/1 outbound validator already provides a
mitigation. The Crypto flaw is a double free on failed RSA public-key parsing.
CellProtocol does not directly use RSA, but the resolved graph includes X509
certificate parsing, and CellScaffold also uses WebAuthn. Absence of a direct
CellProtocol RSA call was therefore insufficient grounds to retain the old pin.

Package.swift now constrains these minimum safe transport versions, rather than
relying only on a root lockfile that downstream SwiftPM consumers ignore.
CellVapor explicitly lists NIOCore, NIOSSL and NIOHTTP2 product dependencies:
merely declaring otherwise-unused package requirements is insufficient because
SwiftPM can prune them. A real consumer pinned to NIOSSL 2.36.1 resolves against
the earlier `b605c5e` manifest and is rejected by `f1036dc`. The permanent
`Scripts/verify-transport-security-floor.sh` gate requires that exact dependency
conflict, so a network or compiler failure cannot count as successful rejection.
Pure CellBase/CellApple consumers still own unrelated transport dependencies;
their application lockfiles must also select patched versions.
Crypto requires 4.5.2, including the follow-up RSA modulus-size corrections.
The Linux test manifests use the same Crypto version. These dependencies require
Swift 6.1 or later; verification uses Swift 6.2.4. Older compilers need an
explicit upgrade and cannot consume this dependency set unchanged.

DiMyMint and DiMyMicropayments previously constrained Crypto to major version 3.
Their published compatibility PRs now admit version 4 and pin the tested
CellProtocol graph. Sprout also needed a compatible Crypto range for HavenAgentD;
its Crypto 3 and 4 builds were independently verified. Exact commits, consumer
tests and integration order are in `SecurityIntegrationVerification-2026-09-10.md`.

`DependencySecurityEvidence-2026-09-10.json` records the exact 34 dependency
versions, immutable commits, Package.resolved hash and zero-match OSV rescan.

The OSV record for Crypto initially labelled 4.5.1 as affected, contradicting the
maintainer advisory and its fix commit. The maintainer identifies 4.5.1 as fixed;
the selected 4.5.2 also avoids that database-boundary ambiguity. A clean scan is
only a point-in-time advisory check, not proof that dependencies have no defects.
