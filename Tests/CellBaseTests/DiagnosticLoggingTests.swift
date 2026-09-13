// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class DiagnosticLoggingTests: XCTestCase {
    private var savedDomains = Set<CellBase.DiagnosticLogDomain>()
    private var savedHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?

    override func setUp() {
        super.setUp()
        savedDomains = CellBase.enabledDiagnosticLogDomains
        savedHandler = CellBase.diagnosticLogHandler
    }

    override func tearDown() {
        CellBase.enabledDiagnosticLogDomains = savedDomains
        CellBase.diagnosticLogHandler = savedHandler
        super.tearDown()
    }

    func testDiagnosticLoggingIsSilentByDefault() {
        var received = [(CellBase.DiagnosticLogDomain, String)]()
        CellBase.enabledDiagnosticLogDomains = []
        CellBase.diagnosticLogHandler = { domain, message in
            received.append((domain, message))
        }

        CellBase.diagnosticLog("hidden", domain: .resolver)

        XCTAssertTrue(received.isEmpty)
    }

    func testDiagnosticLoggingUsesHandlerForEnabledDomain() {
        var received = [(CellBase.DiagnosticLogDomain, String)]()
        CellBase.enabledDiagnosticLogDomains = [.resolver]
        CellBase.diagnosticLogHandler = { domain, message in
            received.append((domain, message))
        }

        CellBase.diagnosticLog("resolver trace", domain: .resolver)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .resolver)
        XCTAssertEqual(received.first?.1, "resolver trace")
    }

    func testDiagnosticLoggingFiltersOtherDomains() {
        var received = [(CellBase.DiagnosticLogDomain, String)]()
        CellBase.enabledDiagnosticLogDomains = [.flow]
        CellBase.diagnosticLogHandler = { domain, message in
            received.append((domain, message))
        }

        CellBase.diagnosticLog("ignore resolver", domain: .resolver)
        CellBase.diagnosticLog("keep flow", domain: .flow)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .flow)
        XCTAssertEqual(received.first?.1, "keep flow")
    }

    func testResolverDoesNotLogInputOutputOrDeniedPayloadValues() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
        }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "log-owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "log-outsider", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        let secret = "synthetic-secret-key-material"
        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in .string(secret) }
        await cell.addInterceptForSet(requester: owner, key: "secret") { _, value, _ in value }
        let resolver = CellResolver.sharedInstance
        CellBase.defaultCellResolver = resolver
        let name = "LogSecurity-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(name: name, emitCell: cell, identity: owner)
        defer { Task { await resolver.unregisterEmitCell(uuid: cell.uuid) } }
        let lock = NSLock()
        var received = [String]()
        CellBase.enabledDiagnosticLogDomains = [.resolver]
        CellBase.diagnosticLogHandler = { _, message in lock.withLock { received.append(message) } }
        let url = try XCTUnwrap(URL(string: "cell:///\(name)/secret"))
        let read = try await resolver.get(from: url, requester: owner)
        XCTAssertEqual(read, .string(secret))
        let written = try await resolver.set(value: .object(["keyMaterial": .string(secret)]), into: url, requester: owner)
        guard case let .object(writtenObject)? = written else { return XCTFail("Missing write result") }
        XCTAssertEqual(writtenObject["keyMaterial"], .string(secret))
        do {
            _ = try await resolver.set(value: .string("denied-secret-payload"), into: url, requester: outsider)
            XCTFail("Unauthorized write succeeded")
        } catch { }
        let messages = lock.withLock { received }
        XCTAssertTrue(messages.contains { $0.contains("Resolver set completed") })
        XCTAssertFalse(messages.contains { $0.contains(secret) || $0.contains("denied-secret-payload") || $0.contains("keyMaterial") })
    }
}
