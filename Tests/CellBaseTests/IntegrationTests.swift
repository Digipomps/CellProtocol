// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
import CellApple

final class IntegrationTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDocumentRoot: String?
    private var previousDebugFlag: Bool = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDocumentRoot = CellBase.documentRootPath
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testAppInitializerBootstrapsResolverAndVault() async throws {
        await AppInitializer.initialize()
        XCTAssertNotNil(CellBase.defaultIdentityVault)
        XCTAssertNotNil(CellBase.defaultCellResolver)
    }

    func testPortholeSkeletonDescriptionDecodes() throws {
        let config = SkeletonDescriptions.skeletonDescriptionFromJson()
        XCTAssertNotNil(config.skeleton)
    }

    func testFlowThroughResolverAndPusherCell() async throws {
        let resolver = CellResolver.sharedInstance
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!

        // Register a test cell and fetch it through resolver
        let name = "FlowTest-\(UUID().uuidString)"
        try await resolver.addCellResolve(name: name, cellScope: .scaffoldUnique, identityDomain: "private", type: GeneralCell.self)
        let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(name)", requester: owner)

        // Attach a pusher and ensure it can push a flow element without errors
        let pusher = FlowElementPusherCell(owner: owner)
        let absorb = cell as? Absorb
        XCTAssertNotNil(absorb)
        let state = try await absorb?.attach(emitter: pusher, label: "push", requester: owner)
        XCTAssertEqual(state, .connected)
        try await absorb?.absorbFlow(label: "push", requester: owner)

        let flow = try await cell.flow(requester: owner)
        let expectation = expectation(description: "Receive flow element")
        let cancellable = flow.sink(receiveCompletion: { _ in },
                                    receiveValue: { element in
                                        if element.title == "test" {
                                            expectation.fulfill()
                                        }
                                    })

        let element = FlowElement(title: "test", content: .string("payload"), properties: .init(type: .event, contentType: .string))
        pusher.pushFlowElement(element, requester: owner)

        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
}
