// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@_spi(Testing) @testable import CellBase

final class CorrespondenceCellTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDebugFlag = false

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.debugValidateAccessForEverything = previousDebugFlag
        super.tearDown()
    }

    func testS1RejectsPlaintextSendPayload() async throws {
        let (_, owner) = await makeVaultAndOwner()
        let cell = await CorrespondenceCell(owner: owner)

        let response = try await cell.set(
            keypath: "sendMessage",
            value: .object([
                "subject": .string("Visible subject"),
                "content": .string("Visible body")
            ]),
            requester: owner
        )

        XCTAssertEqual(denialReason(response), CorrespondenceDenialReason.plaintextRejected.rawValue)
    }

    func testS1RejectsEnvelopePreparedForStaleMembershipFingerprint() async throws {
        let (vault, owner) = await makeVaultAndOwner()
        let invitee = await vault.identity(for: "correspondence-invitee", makeNewIfNotFound: true)!
        let cell = await CorrespondenceCell(owner: owner)
        let staleFingerprint = cell.membershipFingerprintSnapshot
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: owner, content: "Encrypted body"),
            subject: "Encrypted subject",
            cellID: cell.uuid,
            membershipFingerprint: staleFingerprint,
            recipients: [],
            provider: vault
        )

        _ = try await invite([invitee.uuid], into: cell, owner: owner)
        let request = CorrespondenceSendRequest(
            preparedEnvelope: prepared,
            purposeRef: "purpose://contact.communication"
        )
        let response = try await cell.set(
            keypath: "sendMessage",
            value: try request.valueType(),
            requester: owner
        )

        XCTAssertEqual(
            denialReason(response),
            CorrespondenceDenialReason.membershipFingerprintMismatch.rawValue
        )
    }

    func testS1ChatUmbrellaContractAuthorizesNoCorrespondenceOperation() async throws {
        let (vault, owner) = await makeVaultAndOwner()
        let chatOnlyRequester = await vault.identity(for: "chat-only", makeNewIfNotFound: true)!
        let cell = await CorrespondenceCell(owner: owner)

        let temporarilyBroadenedTemplate = CorrespondenceAgreementTemplates.external(owner: owner)
        temporarilyBroadenedTemplate.addGrant("rw--", for: "chat")
        cell.agreementTemplate = temporarilyBroadenedTemplate

        let chatOnlyAgreement = Agreement(owner: owner)
        chatOnlyAgreement.grants = []
        chatOnlyAgreement.conditions = []
        chatOnlyAgreement.addGrant("rw--", for: "chat")
        let admission = await cell.addAgreement(
            chatOnlyAgreement,
            for: chatOnlyRequester,
            authorizedBy: owner
        )
        XCTAssertEqual(admission, .signed)

        cell.agreementTemplate = CorrespondenceAgreementTemplates.external(owner: owner)

        do {
            _ = try await cell.get(keypath: "inbox", requester: chatOnlyRequester)
            XCTFail("The chat umbrella must not authorize inbox")
        } catch let CellAuthorizationError.denied(decision) {
            XCTAssertEqual(decision.reasonCode, CorrespondenceDenialReason.grantNotHeld.rawValue)
            XCTAssertEqual(decision.request.keypath, "inbox")
        }

        for action in ["readMessage", "sendMessage", "ackMessage"] {
            do {
                _ = try await cell.set(keypath: action, value: .object([:]), requester: chatOnlyRequester)
                XCTFail("The chat umbrella must not authorize \(action)")
            } catch let CellAuthorizationError.denied(decision) {
                XCTAssertEqual(decision.reasonCode, CorrespondenceDenialReason.grantNotHeld.rawValue)
                XCTAssertEqual(decision.request.keypath, action)
            }
        }
    }

    func testS1InboxAndStoredCellContainNoPlaintextOrSubject() async throws {
        let (vault, owner) = await makeVaultAndOwner()
        let recipient = await vault.identity(for: "correspondence-recipient", makeNewIfNotFound: true)!
        let cell = await CorrespondenceCell(owner: owner)
        _ = try await invite([recipient.uuid], into: cell, owner: owner)

        let body = "body-secret-728f4f0d"
        let subject = "subject-secret-3bf4d39c"
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: owner, content: body, contentType: "text/plain"),
            subject: subject,
            cellID: cell.uuid,
            membershipFingerprint: cell.membershipFingerprintSnapshot,
            recipients: [recipient],
            provider: vault
        )
        let sendResponse = try await cell.set(
            keypath: "sendMessage",
            value: try CorrespondenceSendRequest(
                preparedEnvelope: prepared,
                purposeRef: "purpose://contact.communication"
            ).valueType(),
            requester: owner
        )
        let messageID = try XCTUnwrap(stringField("messageID", in: sendResponse))

        let inbox = try await cell.get(keypath: "inbox", requester: owner)
        XCTAssertFalse(containsKey("content", in: inbox))
        XCTAssertFalse(containsKey("subject", in: inbox))

        let encoded = try JSONEncoder().encode(cell)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains(body))
        XCTAssertFalse(serialized.contains(subject))
        XCTAssertFalse(serialized.contains("\"subject\""))
        XCTAssertFalse(serialized.contains("\"content\""))

        let readValue = try await cell.set(
            keypath: "readMessage",
            value: .object(["messageID": .string(messageID)]),
            requester: owner
        )
        let stored = try CorrespondenceCellCodec.decode(
            try XCTUnwrap(readValue),
            as: CorrespondenceStoredEnvelope.self
        )
        XCTAssertEqual(stored.outer.purposeRef, CorrespondenceCell.envelopePurposeRef)
        let opened = try await CorrespondenceEnvelopeUtility.open(
            storedEnvelope: stored,
            recipient: recipient,
            sender: owner,
            provider: vault
        )
        XCTAssertTrue(opened.senderVerified)
        XCTAssertEqual(opened.inner.subject, subject)
        XCTAssertEqual(opened.inner.content, body)
    }

    func testS2TemplatesAreExactAndResolverDeniesOwnerSurfaceToExternalAgreement() async throws {
        let (vault, owner) = await makeVaultAndOwner()
        let external = await vault.identity(for: "external-surface", makeNewIfNotFound: true)!
        let invited = await vault.identity(for: "new-member", makeNewIfNotFound: true)!
        let cell = await CorrespondenceCell(owner: owner)
        let resolver = CellResolver.makeIsolatedForTesting()
        let resolverName = "Correspondence-\(UUID().uuidString)"
        try await resolver.registerNamedEmitCell(
            name: resolverName,
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: owner
        )
        defer { Task { await resolver.unregisterEmitCell(uuid: cell.uuid) } }

        XCTAssertEqual(
            grantMap(CorrespondenceAgreementTemplates.external(owner: owner)),
            [
                "inbox": "r---",
                "readMessage": "-w--",
                "sendMessage": "-w--",
                "ackMessage": "-w--"
            ]
        )
        XCTAssertEqual(
            grantMap(CorrespondenceAgreementTemplates.owner(owner: owner)),
            [
                "audience.inviteIdentities": "-w--",
                "audience.generateInvitationArtifacts": "-w--",
                "audience.acceptInvitationArtifact": "-w--",
                "audience.revokeInvites": "-w--",
                "crypto.requestRekey": "-w--",
                "lifecycle.retentionPolicy": "-w--",
                "lifecycle.close": "-w--"
            ]
        )

        let admission = await cell.addAgreement(
            CorrespondenceAgreementTemplates.external(owner: owner),
            for: external,
            authorizedBy: owner
        )
        XCTAssertEqual(admission, .signed)

        do {
            let inviteURL = try XCTUnwrap(
                URL(string: "cell:///\(resolverName)/audience.inviteIdentities")
            )
            _ = try await resolver.set(
                value: .object(["identityUUID": .string(invited.uuid)]),
                into: inviteURL,
                requester: external
            )
            XCTFail("The external Agreement must not reach owner membership actions")
        } catch let CellAuthorizationError.denied(decision) {
            XCTAssertEqual(decision.reasonCode, CorrespondenceDenialReason.grantNotHeld.rawValue)
            XCTAssertEqual(decision.request.keypath, "audience.inviteIdentities")
        }

        for keypath in CorrespondenceAgreementTemplates.neverGrantedKeypaths {
            let permission = keypath == "crypto.policy" || keypath == "members" || keypath == "participants"
                ? "r---"
                : "-w--"
            let allowed = await cell.validateAccess(permission, at: keypath, for: external)
            XCTAssertFalse(allowed, "External Agreement unexpectedly reached \(keypath)")
        }

        let ownerInviteURL = try XCTUnwrap(
            URL(string: "cell:///\(resolverName)/audience.inviteIdentities")
        )
        let ownerResult = try await resolver.set(
            value: .object(["identityUUID": .string(invited.uuid)]),
            into: ownerInviteURL,
            requester: owner
        )
        XCTAssertEqual(stringField("status", in: ownerResult), "invited")

        _ = try await invite([external.uuid], into: cell, owner: owner)
        let inbox = try await cell.get(keypath: "inbox", requester: external)
        XCTAssertEqual(stringField("schema", in: inbox), "haven.correspondence.inbox.v0")
    }

    func testS2ExploreContractsAreCompleteAndOperationsEmitFlow() async throws {
        let (vault, owner) = await makeVaultAndOwner()
        let recipient = await vault.identity(for: "flow-recipient", makeNewIfNotFound: true)!
        let cell = await CorrespondenceCell(owner: owner)

        for (key, method, permission, returnType) in [
            ("inbox", ExploreContractMethod.get, "r---", "object"),
            ("readMessage", ExploreContractMethod.set, "-w--", "oneof"),
            ("sendMessage", ExploreContractMethod.set, "-w--", "object"),
            ("ackMessage", ExploreContractMethod.set, "-w--", "object"),
            ("audience.inviteIdentities", ExploreContractMethod.set, "-w--", "object")
        ] {
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: key,
                requester: owner,
                expectedMethod: method,
                expectedInputType: method == .get ? "null" : "object",
                expectedReturnType: returnType
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: key,
                requester: owner,
                expected: [permission]
            )
        }

        _ = try await invite([recipient.uuid], into: cell, owner: owner)
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: owner, content: "flow payload"),
            subject: "flow subject",
            cellID: cell.uuid,
            membershipFingerprint: cell.membershipFingerprintSnapshot,
            recipients: [recipient],
            provider: vault
        )

        let flow = try await cell.flow(requester: owner)
        let flowExpectation = expectation(description: "send, read, and receipt flow events")
        flowExpectation.expectedFulfillmentCount = 3
        var observedEvents = [String]()
        let lock = NSLock()
        let cancellable = flow.sink(
            receiveCompletion: { _ in },
            receiveValue: { element in
                guard element.topic == CorrespondenceCell.flowTopic,
                      ["message.stored", "message.read", "message.receipt"].contains(element.title) else {
                    return
                }
                lock.withLock {
                    observedEvents.append(element.title)
                }
                flowExpectation.fulfill()
            }
        )
        defer { cancellable.cancel() }

        let sendResponse = try await cell.set(
            keypath: "sendMessage",
            value: try CorrespondenceSendRequest(
                preparedEnvelope: prepared,
                purposeRef: "purpose://contact.communication"
            ).valueType(),
            requester: owner
        )
        let messageID = try XCTUnwrap(stringField("messageID", in: sendResponse))
        _ = try await cell.set(
            keypath: "readMessage",
            value: .object(["messageID": .string(messageID)]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "ackMessage",
            value: .object(["messageID": .string(messageID)]),
            requester: owner
        )

        await fulfillment(of: [flowExpectation], timeout: 1.0)
        let eventSnapshot = lock.withLock { observedEvents }
        XCTAssertEqual(eventSnapshot, ["message.stored", "message.read", "message.receipt"])
    }

    func testS3ExpiryDeletesOuterAndCiphertextTogether() async throws {
        let clock = CorrespondenceTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (vault, owner) = await makeVaultAndOwner()
        let recipient = await vault.identity(for: "expiry-recipient", makeNewIfNotFound: true)!
        let policy = CorrespondenceRetentionPolicy(
            defaultSecondsByPurpose: ["purpose://contact.communication": 5],
            maximumSeconds: 30
        )
        let cell = await CorrespondenceCell(
            owner: owner,
            retentionPolicy: policy,
            nowProvider: { clock.now }
        )
        _ = try await invite([recipient.uuid], into: cell, owner: owner)

        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: owner, content: "expires-with-outer"),
            subject: "expires-with-inner",
            cellID: cell.uuid,
            membershipFingerprint: cell.membershipFingerprintSnapshot,
            recipients: [recipient],
            provider: vault
        )
        let sendResponse = try await cell.set(
            keypath: "sendMessage",
            value: try CorrespondenceSendRequest(
                preparedEnvelope: prepared,
                purposeRef: "purpose://contact.communication"
            ).valueType(),
            requester: owner
        )
        let messageID = try XCTUnwrap(stringField("messageID", in: sendResponse))
        let before = try JSONEncoder().encode(cell)
        let beforeString = try XCTUnwrap(String(data: before, encoding: .utf8))
        XCTAssertTrue(beforeString.contains(messageID))
        XCTAssertTrue(beforeString.contains("innerCiphertext"))

        clock.now = clock.now.addingTimeInterval(6)
        let inbox = try await cell.get(keypath: "inbox", requester: owner)
        XCTAssertEqual(listField("messages", in: inbox)?.count, 0)

        let after = try JSONEncoder().encode(cell)
        let afterString = try XCTUnwrap(String(data: after, encoding: .utf8))
        XCTAssertFalse(afterString.contains(messageID))
        XCTAssertFalse(afterString.contains(prepared.envelope.combinedCiphertext.base64EncodedString()))
    }

    private func makeVaultAndOwner() async -> (CorrespondenceTestIdentityVault, Identity) {
        let vault = CorrespondenceTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "correspondence-owner", makeNewIfNotFound: true)!
        return (vault, owner)
    }

    private func invite(
        _ identityUUIDs: [String],
        into cell: CorrespondenceCell,
        owner: Identity
    ) async throws -> ValueType? {
        try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .object(["identityUUIDs": .list(identityUUIDs.map(ValueType.string))]),
            requester: owner
        )
    }

    private func denialReason(_ value: ValueType?) -> String? {
        stringField("denialReason", in: value)
    }

    private func stringField(_ key: String, in value: ValueType?) -> String? {
        guard case let .object(object)? = value,
              case let .string(string)? = object[key] else {
            return nil
        }
        return string
    }

    private func listField(_ key: String, in value: ValueType?) -> ValueTypeList? {
        guard case let .object(object)? = value,
              case let .list(list)? = object[key] else {
            return nil
        }
        return list
    }

    private func containsKey(_ target: String, in value: ValueType) -> Bool {
        switch value {
        case .object(let object):
            return object.contains(where: { key, nested in
                key == target || containsKey(target, in: nested)
            })
        case .list(let values):
            return values.contains { containsKey(target, in: $0) }
        default:
            return false
        }
    }

    private func grantMap(_ agreement: Agreement) -> [String: String] {
        Dictionary(uniqueKeysWithValues: agreement.grants.map {
            ($0.keypath, $0.permission.permissionString)
        })
    }
}

private final class CorrespondenceTestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private actor CorrespondenceTestIdentityVault: IdentityVaultProtocol, IdentityKeyRoleProviderProtocol {
    private var identitiesByContext = [String: Identity]()
    private var identitiesByUUID = [String: Identity]()
    private var signingKeysByUUID = [String: Curve25519.Signing.PrivateKey]()
    private var keyAgreementKeysByUUID = [String: Curve25519.KeyAgreement.PrivateKey]()
    private var nextID = 1

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identitiesByContext[identityContext] = identity
        identitiesByUUID[identity.uuid] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let identity = identitiesByContext[identityContext] {
            return identity
        }
        guard makeNewIfNotFound else { return nil }

        let suffix = String(format: "%012d", nextID)
        nextID += 1
        let uuid = "10000000-0000-0000-0000-\(suffix)"
        let identity = Identity(uuid, displayName: uuid, identityVault: self)
        let signingKey = Curve25519.Signing.PrivateKey()
        let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        signingKeysByUUID[uuid] = signingKey
        keyAgreementKeysByUUID[uuid] = keyAgreementKey
        identity.publicSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .signature,
            algorithm: .EdDSA,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: signingKey.publicKey.rawRepresentation
        )
        identity.publicKeyAgreementSecureKey = SecureKey(
            date: Date(),
            privateKey: false,
            use: .keyAgreement,
            algorithm: .X25519,
            size: 256,
            curveType: .Curve25519,
            x: nil,
            y: nil,
            compressedKey: keyAgreementKey.publicKey.rawRepresentation
        )
        identitiesByContext[identityContext] = identity
        identitiesByUUID[uuid] = identity
        return identity
    }

    func identity(forUUID uuid: String) async -> Identity? {
        identitiesByUUID[uuid]
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
        identitiesByUUID[identity.uuid] = identity
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        guard let stored = identitiesByUUID[identity.uuid] else { return false }
        return stored.signingPublicKeyFingerprint == identity.signingPublicKeyFingerprint
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let signingKey = signingKeysByUUID[identity.uuid] else {
            throw IdentityVaultError.noVaultIdentity
        }
        return try signingKey.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let keyData = identity.publicSecureKey?.compressedKey else { return false }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0xBC, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("correspondence-test-key-\(tag)", "correspondence-test-iv-\(tag)")
    }

    func publicSecureKey(for identity: Identity, role: IdentityKeyRole) async throws -> SecureKey? {
        switch role {
        case .signing:
            return identity.publicSecureKey
        case .keyAgreement:
            return identity.publicKeyAgreementSecureKey
        }
    }

    func privateKeyData(for identity: Identity, role: IdentityKeyRole) async throws -> Data? {
        switch role {
        case .signing:
            return signingKeysByUUID[identity.uuid]?.rawRepresentation
        case .keyAgreement:
            return keyAgreementKeysByUUID[identity.uuid]?.rawRepresentation
        }
    }
}
