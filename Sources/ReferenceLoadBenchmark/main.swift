// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
//
// Måler hva parallell oppkobling av cellReferences er verdt.
//
// Bakgrunn: CellResolver.loadCell(from:into:requester:) lastet tidligere hver
// referanse i en sekvensiell løkke. Rundturen per referanse — WebSocket-
// oppkobling, handshake og retrieveProxyRepresentation — er uavhengig per
// endepunkt, så en flate med N eksterne referanser betalte summen av N
// rundturer. Fase 1 starter dem nå samtidig; fase 2 kobler dem inn i deklarert
// rekkefølge.
//
// Kjør mot en lokal scaffold, f.eks. PyPalazzoConciergeScaffold:
//   .venv/bin/palazzo-concierge serve --host 127.0.0.1 --port 8098
//   swift run ReferenceLoadBenchmark ws://127.0.0.1:8098/bridgehead 3
//
// Hver runde bruker en fersk CellResolver. Uten det ville runde to bare målt
// bro-cachen.

import Foundation
@_spi(Testing) import CellBase

let arguments = CommandLine.arguments
let bridgeBase = arguments.count > 1 ? arguments[1] : "ws://127.0.0.1:8098/bridgehead"
let rounds = arguments.count > 2 ? (Int(arguments[2]) ?? 3) : 3  // "--trace" faller til 3
let cellNames = ["EntityAnchor", "GraphIndex", "PalazzoConciergeKnowledge", "TrustedIssuers", "Vault"]

func endpoints(_ count: Int) -> [String] {
    cellNames.prefix(count).map { "\(bridgeBase)/\($0)" }
}

func makeConfiguration(referenceCount: Int) -> CellConfiguration {
    var configuration = CellConfiguration(name: "ReferenceLoadBenchmark")
    for (index, endpoint) in endpoints(referenceCount).enumerated() {
        var reference = CellReference(endpoint: endpoint, subscribeFeed: false, label: "ref\(index)")
        reference.subscribeFeed = false
        configuration.addReference(reference)
    }
    return configuration
}

func milliseconds(_ block: () async throws -> Void) async rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try await block()
    let end = DispatchTime.now().uptimeNanoseconds
    return Double(end - start) / 1_000_000.0
}

func median(_ values: [Double]) -> Double {
    guard values.isEmpty == false else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

/// Én måling: fersk resolver, fersk source-celle, ferske broer.
func measureOneLoad(referenceCount: Int) async -> Double? {
    // CellResolver er en singleton i drift; denne SPI-en gir en isolert
    // instans slik at hver runde starter uten varm bro-cache.
    let resolver = CellResolver.makeIsolatedForTesting()
    CellBase.defaultCellResolver = resolver
    do {
        try await resolver.registerDefaultWebSocketBridgeTransports()
    } catch {
        print("  klarte ikke registrere transporter: \(error)")
        return nil
    }
    guard let identity = await CellBase.defaultIdentityVault?.identity(for: "benchmark", makeNewIfNotFound: true) else {
        print("  ingen identitet tilgjengelig")
        return nil
    }
    // proveRemoteBridgePrincipal krever både signeringsnøkkel og et
    // hjemmehvelv; uten referansen svarer den ownerAuthorityUnavailable.
    if identity.homeVaultReference?.isEmpty != false {
        identity.homeVaultReference = await CellBase.defaultIdentityVault?.identityVaultReference() ?? "benchmark-vault"
    }
    print("  [resolver ok, identitet ok, lager source-celle]")
    // Source-cellen må eies av den samme identiteten, ellers nektes attach
    // med deniedNoGrant før vi rekker å måle noe.
    let source = await GeneralCell(owner: identity)
    let configuration = makeConfiguration(referenceCount: referenceCount)
    // Tiden måles uansett utfall. Det interessante her er hvor lenge lastingen
    // *tar*, ikke om hver referanse svarer: en referanse som venter ut en
    // timeout koster like mye enten den ender i svar eller i feil, og det er
    // nettopp den kostnaden parallelliseringen skal kollapse.
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        _ = try await resolver.loadCell(from: configuration, into: source, requester: identity)
    } catch {
        let shortError = String(describing: error).prefix(60)
        print("  (lasting endte i feil etter måling: \(shortError))")
    }
    let end = DispatchTime.now().uptimeNanoseconds
    return Double(end - start) / 1_000_000.0
}

/// Én lasting med full diagnostikk og millisekund-stempel per hendelse.
/// Svarer på «hvor blir tiden av», ikke «hvor fort går det».
func trace() async {
    setvbuf(stdout, nil, _IONBF, 0)
    CellBase.webSocketSecurityPolicy = .developmentOnlyInsecureAllowed
    CellBase.debugValidateAccessForEverything = true
    CellBase.defaultIdentityVault = BenchmarkIdentityVault()
    CellBase.enabledDiagnosticLogDomains = Set(CellBase.DiagnosticLogDomain.allCases)
    let origin = DispatchTime.now().uptimeNanoseconds
    CellBase.diagnosticLogHandler = { domain, message in
        let ms = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000.0
        print(String(format: "[%9.1f ms] %@: %@", ms, domain.rawValue, String(message.prefix(220))))
    }
    print("TRACE: én lasting av \(endpoints(1).first ?? "?")")
    if let total = await measureOneLoad(referenceCount: 1) {
        print(String(format: "TRACE: totalt %.1f ms", total))
    }
}

func run() async {
    setvbuf(stdout, nil, _IONBF, 0)
    if arguments.contains("--trace") {
        await trace()
        return
    }
    print("start")
    CellBase.webSocketSecurityPolicy = .developmentOnlyInsecureAllowed
    // Målebenken skal måle transport og oppkobling, ikke tilgangsstyring.
    // Uten dette nektes attach med deniedNoGrant før noe er målt.
    CellBase.debugValidateAccessForEverything = true
    CellBase.defaultIdentityVault = BenchmarkIdentityVault()

    print("Målebenk: parallell vs sekvensiell lasting av cellReferences")
    print("Bro: \(bridgeBase)")
    print("Runder per punkt: \(rounds)\n")
    // %s krever en C-streng; med Swift String krasjer String(format:).
    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    print(pad("N", 6) + pad("sekvensiell", 14) + pad("parallell", 14) + "faktor")
    print(String(repeating: "-", count: 50))

    for referenceCount in [1, 2, 3, 5] where referenceCount <= cellNames.count {
        var sequential = [Double]()
        var parallel = [Double]()

        setenv("CELLPROTOCOL_SEQUENTIAL_REFERENCE_LOAD", "1", 1)
        for _ in 0..<rounds {
            if let value = await measureOneLoad(referenceCount: referenceCount) { sequential.append(value) }
        }

        unsetenv("CELLPROTOCOL_SEQUENTIAL_REFERENCE_LOAD")
        for _ in 0..<rounds {
            if let value = await measureOneLoad(referenceCount: referenceCount) { parallel.append(value) }
        }

        let sequentialMedian = median(sequential)
        let parallelMedian = median(parallel)
        let factor = parallelMedian > 0 ? sequentialMedian / parallelMedian : 0
        print(
            pad("\(referenceCount)", 6)
                + pad(String(format: "%.1f", sequentialMedian), 14)
                + pad(String(format: "%.1f", parallelMedian), 14)
                + String(format: "%.2fx", factor)
        )
    }
    print("\nAlle tall i millisekunder, median.")
}

await run()
