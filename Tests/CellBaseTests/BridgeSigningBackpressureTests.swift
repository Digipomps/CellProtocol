// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import CellBase

final class BridgeSigningBackpressureTests: XCTestCase {
    func testProductionLimitSurvivesOuterAndInnerAttachmentAuthorization() async throws {
        let oldPolicy = CellBase.securityContainmentPolicy
        let oldController = CellBase.securityContainmentController
        defer {
            CellBase.securityContainmentPolicy = oldPolicy
            CellBase.securityContainmentController = oldController
        }
        for (consumed, action) in [(12, "attachments.revoke"), (11, "attachments.upload")] {
            let vault = MockIdentityVault()
            let owner = await vault.identity(for: "backpressure-fixture", makeNewIfNotFound: true)!
            let cell = await CorrespondenceCell(owner: owner)
            let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
            wire.channelSession = try await authenticatedSessionFixture(principal: owner)
            try await bridge.setTransport(wire, connection: .outbound)
            try bridge.activateAuthenticatedChannel()
            bridge.emitCellAtEndpoint = cell
            let controller = CellSecurityContainmentController()
            CellBase.securityContainmentController = controller
            CellBase.securityContainmentPolicy = .localProtection
            wire.beforeAccept = { command in
                if command.command == .sign, case .signData(let data)? = command.payload {
                    let signed = try await owner.sign(data: data)
                    let signature = try XCTUnwrap(signed)
                    try await bridge.consumeResponse(command: orderingReply(to: command, payload: .signature(signature)))
                }
            }
            let proxy = BridgeIdentityVault(cloudBridge: bridge)
            for index in 0..<consumed {
                _ = try await proxy.signMessageForIdentity(messageData: signingData(owner, nonce: UInt8(index)), identity: owner)
            }
            let request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
                agreementID: cell.uuid, senderIdentityUUID: owner.uuid, attachmentID: "fixture")
            let value = try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(request))
            try await bridge.consumeCommand(command: .init(cmd: "set", identity: owner,
                payload: .keyValue(.init(key: action, value: value)), cid: 700))
            let response = try XCTUnwrap(wire.commands.last { $0.cid == 700 })
            guard case .setValueResponse(let result)? = response.payload else { return XCTFail("Missing SET reply") }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            XCTAssertEqual(object["state"] as? String, "error")
            XCTAssertTrue((object["retryAfterSeconds"] as? Int ?? 0) > 0)
            do {
                _ = try await proxy.signMessageForIdentity(messageData: signingData(owner, nonce: 99), identity: owner)
                XCTFail("Returning a retry hint must not reset or bypass the quota")
            } catch {}
            await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
        }
    }

    private func signingData(_ owner: Identity, nonce: UInt8) throws -> Data {
        try IdentitySigningChallenge.signingData(for: owner, trustedIdentity: owner,
            domain: "bridge", resource: "fixture", action: "checkIdentityOrigin", audience: "GeneralCell",
            nonce: Data(repeating: nonce, count: 64))
    }

    func testNewAuthenticatedConnectionDoesNotResetSigningQuota() async throws {
        let oldPolicy = CellBase.securityContainmentPolicy
        let oldController = CellBase.securityContainmentController
        defer {
            CellBase.securityContainmentPolicy = oldPolicy
            CellBase.securityContainmentController = oldController
        }
        CellBase.securityContainmentController = CellSecurityContainmentController()
        CellBase.securityContainmentPolicy = .localProtection
        let vault = MockIdentityVault()
        let owner = await vault.identity(for: "renewal-quota-fixture", makeNewIfNotFound: true)!
        for generation in 0..<2 {
            let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
            wire.channelSession = try await authenticatedSessionFixture(principal: owner)
            try await bridge.setTransport(wire, connection: .outbound)
            try bridge.activateAuthenticatedChannel()
            wire.beforeAccept = { command in
                if command.command == .sign, case .signData(let data)? = command.payload {
                    let signed = try await owner.sign(data: data)
                    let signature = try XCTUnwrap(signed)
                    try await bridge.consumeResponse(command: orderingReply(to: command, payload: .signature(signature)))
                }
            }
            let proxy = BridgeIdentityVault(cloudBridge: bridge)
            if generation == 0 {
                for index in 0..<12 {
                    _ = try await proxy.signMessageForIdentity(messageData: signingData(owner, nonce: UInt8(index)), identity: owner)
                }
            } else {
                do {
                    _ = try await proxy.signMessageForIdentity(messageData: signingData(owner, nonce: 100), identity: owner)
                    XCTFail("A fresh channel must not clear the principal/endpoint proof budget")
                } catch {
                    XCTAssertEqual(String(reflecting: type(of: error)), "CellBase.BridgeSigningBackpressure")
                }
                XCTAssertTrue(wire.commands.allSatisfy { $0.command != .sign })
            }
            await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
        }
    }

    func testLegacySetRepliesHaveNoRetryHint() throws {
        for json in [#"{"state":"error"}"#, #"{"state":"ok","value":"stored"}"#] {
            let decoded = try JSONDecoder().decode(SetValueResponse.self, from: Data(json.utf8))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            XCTAssertNil(encoded["retryAfterSeconds"])
        }
    }

    func testUnknownStorageOutcomeNeverBecomesRetryable() async throws {
        let owner = await MockIdentityVault().identity(for: "storage-failure-fixture", makeNewIfNotFound: true)!
        let cell = await BackpressureStorageFailureCell(owner: owner)
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        try await bridge.consumeCommand(command: .init(cmd: "set", identity: owner,
            payload: .keyValue(.init(key: "write", value: .string("fixture"))), cid: 701))
        let response = try XCTUnwrap(wire.commands.last { $0.cid == 701 })
        guard case .setValueResponse(let result)? = response.payload else { return XCTFail("Missing SET reply") }
        XCTAssertEqual(cell.writes, 1)
        XCTAssertEqual(result.state, .error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(object["retryAfterSeconds"], "An error after an effect must not invite automatic replay")
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }

    func testLateAuthorizationFailureAfterEffectNeverBecomesRetryable() async throws {
        let oldPolicy = CellBase.securityContainmentPolicy
        let oldController = CellBase.securityContainmentController
        defer {
            CellBase.securityContainmentPolicy = oldPolicy
            CellBase.securityContainmentController = oldController
        }
        CellBase.securityContainmentController = CellSecurityContainmentController()
        CellBase.securityContainmentPolicy = .localProtection
        let owner = await MockIdentityVault().identity(for: "storage-failure-fixture", makeNewIfNotFound: true)!
        let cell = await BackpressureLateAuthorizationFailureCell(owner: owner)
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        wire.beforeAccept = { command in
            if command.command == .sign, case .signData(let data)? = command.payload {
                let signed = try await owner.sign(data: data)
                let signature = try XCTUnwrap(signed)
                try await bridge.consumeResponse(command: orderingReply(to: command, payload: .signature(signature)))
            }
        }
        try await bridge.consumeCommand(command: .init(cmd: "set", identity: owner,
            payload: .keyValue(.init(key: "write", value: .string("fixture"))), cid: 701))
        let response = try XCTUnwrap(wire.commands.last { $0.cid == 701 })
        guard case .setValueResponse(let result)? = response.payload else { return XCTFail("Missing SET reply") }
        XCTAssertEqual(cell.writes, 1)
        XCTAssertEqual(result.state, .error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(object["retryAfterSeconds"], "An error after an effect must not invite automatic replay")
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }

    func testChildPreDispatchRejectionAfterParentEffectNeverBecomesRetryable() async throws {
        let oldPolicy = CellBase.securityContainmentPolicy
        let oldController = CellBase.securityContainmentController
        defer {
            CellBase.securityContainmentPolicy = oldPolicy
            CellBase.securityContainmentController = oldController
        }
        CellBase.securityContainmentController = CellSecurityContainmentController()
        CellBase.securityContainmentPolicy = .localProtection
        let owner = await MockIdentityVault().identity(for: "storage-failure-fixture", makeNewIfNotFound: true)!
        let cell = await BackpressureLateAuthorizationFailureCell(owner: owner)
        cell.child = await CorrespondenceCell(owner: owner)
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        wire.beforeAccept = { command in
            if command.command == .sign, case .signData(let data)? = command.payload {
                let signed = try await owner.sign(data: data)
                let signature = try XCTUnwrap(signed)
                try await bridge.consumeResponse(command: orderingReply(to: command, payload: .signature(signature)))
            }
        }
        try await bridge.consumeCommand(command: .init(cmd: "set", identity: owner,
            payload: .keyValue(.init(key: "write", value: .string("fixture"))), cid: 701))
        let response = try XCTUnwrap(wire.commands.last { $0.cid == 701 })
        guard case .setValueResponse(let result)? = response.payload else { return XCTFail("Missing SET reply") }
        XCTAssertEqual(cell.writes, 1)
        XCTAssertEqual(result.state, .error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(object["retryAfterSeconds"], "An error after an effect must not invite automatic replay")
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }

    func testInnerChildRejectionAfterParentEffectNeverBecomesRetryable() async throws {
        let oldPolicy = CellBase.securityContainmentPolicy
        let oldController = CellBase.securityContainmentController
        defer {
            CellBase.securityContainmentPolicy = oldPolicy
            CellBase.securityContainmentController = oldController
        }
        CellBase.securityContainmentController = CellSecurityContainmentController()
        CellBase.securityContainmentPolicy = .localProtection
        let owner = await MockIdentityVault().identity(for: "storage-failure-fixture", makeNewIfNotFound: true)!
        let cell = await BackpressureLateAuthorizationFailureCell(owner: owner)
        cell.child = await CorrespondenceCell(owner: owner)
        cell.innerChildRejection = true
        let wire = BridgeLifecycleWire(), bridge = BridgeBase(owner: owner)
        wire.channelSession = try await authenticatedSessionFixture(principal: owner)
        try await bridge.setTransport(wire, connection: .outbound)
        try bridge.activateAuthenticatedChannel()
        bridge.emitCellAtEndpoint = cell
        wire.beforeAccept = { command in
            if command.command == .sign, case .signData(let data)? = command.payload {
                let signed = try await owner.sign(data: data)
                let signature = try XCTUnwrap(signed)
                try await bridge.consumeResponse(command: orderingReply(to: command, payload: .signature(signature)))
            }
        }
        try await bridge.consumeCommand(command: .init(cmd: "set", identity: owner,
            payload: .keyValue(.init(key: "write", value: .string("fixture"))), cid: 701))
        let response = try XCTUnwrap(wire.commands.last { $0.cid == 701 })
        guard case .setValueResponse(let result)? = response.payload else { return XCTFail("Missing SET reply") }
        XCTAssertEqual(cell.writes, 1)
        XCTAssertEqual(result.state, .error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(object["retryAfterSeconds"], "An error after an effect must not invite automatic replay")
        await bridge.channelDidClose(try XCTUnwrap(wire.channelSession))
    }


}

private final class BackpressureStorageFailureCell: GeneralCell {
    enum Failure: Error { case storage }
    var writes = 0
    override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        writes += 1
        throw Failure.storage
    }
}

private final class BackpressureLateAuthorizationFailureCell: GeneralCell {
    var writes = 0
    var child: CorrespondenceCell?
    var innerChildRejection = false
    override func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        writes += 1
        if let child {
            if innerChildRejection {
                for _ in 0..<11 {
                    let decision = await authorizationDecision(requestedAccess: "-w--", at: keypath, for: requester)
                    XCTAssertTrue(decision.allowed)
                }
                let request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
                    agreementID: child.uuid, senderIdentityUUID: requester.uuid, attachmentID: "fixture")
                let input = try JSONDecoder().decode(ValueType.self, from: JSONEncoder().encode(request))
                return try await child.set(keypath: "attachments.upload", value: input, requester: requester)
            }
            for _ in 0..<13 {
                _ = try await child.set(keypath: "attachments.revoke", value: .null, requester: requester)
            }
            XCTFail("Child's initial gate must eventually reject the exhausted quota")
            return nil
        }
        for _ in 0..<13 {
            let decision = await authorizationDecision(requestedAccess: "-w--", at: keypath, for: requester)
            if !decision.allowed {
                XCTAssertNotNil((requester.identityVault as? BridgeIdentityVault)?.signingBackpressure)
                throw CellAuthorizationError.denied(decision)
            }
        }
        XCTFail("The production signing quota must reject a proof")
        return nil
    }
}
