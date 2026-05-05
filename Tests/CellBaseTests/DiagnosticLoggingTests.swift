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
}
