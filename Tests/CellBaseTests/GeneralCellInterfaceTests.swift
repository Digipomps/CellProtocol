// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class GeneralCellInterfaceTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDebugFlag: Bool = false
    private var previousExploreEnforcementMode: CellBase.ExploreContractEnforcementMode = .permissive

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        previousExploreEnforcementMode = CellBase.exploreContractEnforcementMode
        CellBase.debugValidateAccessForEverything = false
        CellBase.exploreContractEnforcementMode = .permissive
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        CellBase.exploreContractEnforcementMode = previousExploreEnforcementMode
        super.tearDown()
    }

    func testGetInterceptReturnsValue() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "echo") { _, _ in
            return .string("ok")
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "echo",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "echo",
            requester: owner,
            expected: .string("*")
        )
        try await CellContractHarness.assertGet(
            on: cell,
            key: "echo",
            requester: owner,
            expectedValue: .string("ok")
        )
    }

    func testSetInterceptRegistersSchemaAndReturnsValue() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "echo") { _, _, _ in
            return .string("set-ok")
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "echo",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "unknown",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "echo",
            requester: owner,
            expected: .string("*")
        )
        try await CellContractHarness.assertSet(
            on: cell,
            key: "echo",
            input: .string("hi"),
            requester: owner,
            expectedResponse: .string("set-ok")
        )
    }

    func testNonOwnerDeniedWithoutContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "secret") { _, _ in
            return .string("nope")
        }

        do {
            _ = try await cell.get(keypath: "secret", requester: other)
            XCTFail("Expected denied error")
        } catch {
            XCTAssertTrue(error is GeneralCell.KeyValueErrors)
        }
    }

    func testNonOwnerAllowedWithSignedContract() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "other", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "shared") { _, _ in
            return .string("shared-ok")
        }

        let agreement = Agreement(owner: owner)
        agreement.addGrant("r--", for: "shared")
        agreement.signatories.append(other)

        let state = await cell.addAgreement(agreement, for: other)
        XCTAssertEqual(state, .signed)

        let value = try await cell.get(keypath: "shared", requester: other)
        XCTAssertEqual(value, .string("shared-ok"))
    }

    func testExplicitSchemaRegistrationForGetAndSet() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForGet(requester: owner, key: "readOnly") { _, _ in
            .string("ok")
        }

        await cell.registerExploreSchema(
            requester: owner,
            key: "readOnly",
            schema: .object([
                "method": .string("get"),
                "returns": .string("String")
            ]),
            description: .string("Read-only key")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "readOnly",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "string"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "readOnly",
            requester: owner,
            expected: .string("Read-only key")
        )

        await cell.addInterceptForSet(requester: owner, key: "writeOnly") { _, _, _ in
            .string("set-ok")
        }
        await cell.registerExploreSchema(
            requester: owner,
            key: "writeOnly",
            schema: .object([
                "method": .string("set"),
                "payload": .string("Object")
            ]),
            description: .string("Write-only key")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "writeOnly",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "unknown"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "writeOnly",
            requester: owner,
            expected: .string("Write-only key")
        )
    }

    func testRegisterExploreContractSupportsFlowEffects() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "publish") { [weak cell] _, value, requester in
            let flowContent: FlowElementValueType
            switch value {
            case let .object(object):
                flowContent = .object(object)
            case let .string(string):
                flowContent = .string(string)
            case let .list(list):
                flowContent = .list(list)
            case let .bool(bool):
                flowContent = .bool(bool)
            case let .number(number):
                flowContent = .number(number)
            case let .integer(number):
                flowContent = .number(number)
            case let .float(number):
                flowContent = .number(Int(number))
            case let .data(data):
                flowContent = .data(data)
            default:
                flowContent = .object(["value": value])
            }
            var flowElement = FlowElement(
                id: UUID().uuidString,
                title: "publish",
                content: flowContent,
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = "publish.completed"
            cell?.pushFlowElement(flowElement, requester: requester)
            return .object(["status": .string("ok")])
        }

        await cell.registerExploreContract(
            requester: owner,
            key: "publish",
            method: .set,
            input: ExploreContract.objectSchema(
                properties: [
                    "message": ExploreContract.schema(type: "string")
                ],
                requiredKeys: ["message"]
            ),
            returns: ExploreContract.objectSchema(
                properties: [
                    "status": ExploreContract.schema(type: "string")
                ],
                requiredKeys: ["status"]
            ),
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                ExploreContract.flowEffect(
                    trigger: .set,
                    topic: "publish.completed",
                    contentType: "object",
                    minimumCount: 1
                )
            ],
            description: .string("Publishes a message and emits a completion flow element")
        )

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "publish",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "publish",
            requester: owner,
            expected: .string("Publishes a message and emits a completion flow element")
        )
        try await CellContractHarness.assertSetTriggersFlow(
            testCase: self,
            on: cell,
            key: "publish",
            input: .object(["message": .string("Hello")]),
            requester: owner,
            expectedTopic: "publish.completed",
            expectedResponse: .object(["status": .string("ok")])
        )
    }

    func testStrictModeRejectsImplicitSetRegistration() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.addInterceptForSet(requester: owner, key: "strict.writeOnly") { _, _, _ in
            .string("should-not-register")
        }

        let keys = try await cell.keys(requester: owner)
        XCTAssertFalse(keys.contains("strict.writeOnly"))

        do {
            _ = try await cell.set(
                keypath: "strict.writeOnly",
                value: .string("hi"),
                requester: owner
            )
            XCTFail("Expected strict mode to reject implicit registration")
        } catch {
            XCTAssertTrue(error is GeneralCell.KeyValueErrors)
        }
    }

    func testStrictModeAllowsExplicitRegisterSetHelper() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        CellBase.exploreContractEnforcementMode = .strict
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)

        await cell.registerSet(
            key: "strict.writeOnly",
            owner: owner,
            input: ExploreContract.schema(type: "string"),
            returns: ExploreContract.schema(type: "string"),
            permissions: ["-w--"],
            description: .string("Strictly registered write key")
        ) { _, payload in
            payload
        }

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "strict.writeOnly",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "string",
            expectedReturnType: "string"
        )
        try await CellContractHarness.assertDescription(
            on: cell,
            key: "strict.writeOnly",
            requester: owner,
            expected: .string("Strictly registered write key")
        )
        try await CellContractHarness.assertSet(
            on: cell,
            key: "strict.writeOnly",
            input: .string("hi"),
            requester: owner,
            expectedResponse: .string("hi")
        )
    }

    func testAttachSignContractWithUnmetConditionEmitsConnectChallenge() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [LookupCondition(keypath: "identity.contractApproval", expectedValue: .bool(true))]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(state) = payload["state"] {
                XCTAssertEqual(state, "unmet")
            } else {
                XCTFail("Expected unmet state in connect.challenge payload")
            }

            if case let .string(requiredAction) = payload["requiredAction"] {
                XCTAssertFalse(requiredAction.isEmpty)
            } else {
                XCTFail("Expected requiredAction in connect.challenge payload")
            }

            XCTAssertNotNil(payload["agreement"])
            XCTAssertNotNil(payload["context"])
            if case let .string(sessionID) = payload["sessionId"] {
                XCTAssertFalse(sessionID.isEmpty)
            } else {
                XCTFail("Expected sessionId in connect.challenge payload")
            }
            if case let .cellConfiguration(configuration) = payload["helperCellConfiguration"] {
                XCTAssertEqual(configuration.discovery?.sourceCellEndpoint, "cell:///AgreementWorkbench")
                XCTAssertEqual(configuration.cellReferences?.first?.endpoint, "cell:///AgreementWorkbench")
            } else {
                XCTFail("Expected AgreementWorkbench helperCellConfiguration in connect.challenge payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "challenge", requester: requester)
        XCTAssertEqual(state, .signContract)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testAttachDeniedEmitsConnectChallenge() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .denied)

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge denied emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(state) = payload["state"] {
                XCTAssertEqual(state, "denied")
            } else {
                XCTFail("Expected denied state in connect.challenge payload")
            }

            if case let .string(reasonCode) = payload["reasonCode"] {
                XCTAssertEqual(reasonCode, "connect_denied")
            } else {
                XCTFail("Expected connect_denied reasonCode in payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "denied", requester: requester)
        XCTAssertEqual(state, .denied)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testAttachSignContractWithConditionalEngagementIncludesHelperConfiguration() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [ConditionalEngagement()]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "conditional engagement challenge emitted")
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }

            if case let .string(requiredAction) = payload["requiredAction"] {
                XCTAssertEqual(requiredAction, "open_helper_configuration")
            } else {
                XCTFail("Expected open_helper_configuration action")
            }

            if case .cellConfiguration = payload["helperCellConfiguration"] {
                // expected helper present
            } else {
                XCTFail("Expected helperCellConfiguration in connect.challenge payload")
            }
            if case let .string(sessionID) = payload["sessionId"] {
                XCTAssertFalse(sessionID.isEmpty)
            } else {
                XCTFail("Expected sessionId in connect.challenge payload")
            }
            challengeExpectation.fulfill()
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "engagement", requester: requester)
        XCTAssertEqual(state, .signContract)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testRetryAdmissionSessionReconnectsAfterConditionBecomesMet() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .signContract)

        let agreement = Agreement(owner: emitterOwner)
        agreement.conditions = [LookupCondition(keypath: "target.ticketValid", expectedValue: .bool(true))]
        emitCell.agreementTemplate = agreement

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge with session emitted")
        var capturedSessionID: String?
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge",
                  case let .object(payload) = flowElement.content else {
                return
            }
            if case let .string(sessionID) = payload["sessionId"] {
                capturedSessionID = sessionID
                challengeExpectation.fulfill()
            }
        })

        let initialState = try await absorbCell.attach(emitter: emitCell, label: "auto-retry", requester: requester)
        XCTAssertEqual(initialState, .signContract)
        await fulfillment(of: [challengeExpectation], timeout: 1.0)

        _ = try await emitCell.set(keypath: "ticketValid", value: .bool(true), requester: emitterOwner)
        let retriedState = try await absorbCell.retryAdmissionSession(id: try XCTUnwrap(capturedSessionID), requester: requester)
        XCTAssertEqual(retriedState, .connected)

        cancellable.cancel()
    }
}
