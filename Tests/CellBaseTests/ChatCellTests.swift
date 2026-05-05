// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
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
@testable import CellBase

final class ChatCellTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testSendMessageUpdatesMessagesParticipantsAndFlow() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        let publisher = try await cell.flow(requester: owner)
        let flowExpectation = expectation(description: "Receives chat.message flow element")
        var receivedFlow: FlowElement?

        publisher
            .sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
                guard flowElement.topic == "chat.message" else { return }
                receivedFlow = flowElement
                flowExpectation.fulfill()
            })
            .store(in: &cancellables)

        let response = try await cell.set(
            keypath: "sendMessage",
            value: .object([
                "content": .string("Hei fra test"),
                "contentType": .string("markdown")
            ]),
            requester: owner
        )

        guard case let .object(responseObject)? = response,
              case let .object(sentMessageValue)? = responseObject["message"] else {
            XCTFail("Expected sendMessage response with message payload")
            return
        }
        XCTAssertEqual(responseObject["status"], .string("sent"))
        XCTAssertEqual(sentMessageValue["content"], .string("Hei fra test"))
        XCTAssertEqual(sentMessageValue["contentType"], .string("text/markdown"))
        XCTAssertEqual(sentMessageValue["ownerInitials"], .string("P"))
        XCTAssertEqual(sentMessageValue["formatLabel"], .string("Markdown"))
        XCTAssertEqual(sentMessageValue["isMarkdown"], .bool(true))

        let messagesValue = try await cell.get(keypath: "messages", requester: owner)
        guard case let .list(messages) = messagesValue else {
            XCTFail("Expected messages list")
            return
        }
        XCTAssertEqual(messages.count, 1)
        guard case let .object(firstMessage) = messages[0] else {
            XCTFail("Expected first message object")
            return
        }
        XCTAssertEqual(firstMessage["content"], .string("Hei fra test"))
        XCTAssertEqual(firstMessage["contentType"], .string("text/markdown"))
        XCTAssertEqual(firstMessage["ownerDisplayName"], .string("private"))
        XCTAssertEqual(firstMessage["ownerInitials"], .string("P"))
        XCTAssertEqual(firstMessage["formatLabel"], .string("Markdown"))
        XCTAssertEqual(firstMessage["isMarkdown"], .bool(true))

        let participantsValue = try await cell.get(keypath: "participants", requester: owner)
        guard case let .list(participants) = participantsValue else {
            XCTFail("Expected participants list")
            return
        }
        XCTAssertEqual(participants.count, 1)
        guard case let .object(firstParticipant) = participants[0] else {
            XCTFail("Expected first participant object")
            return
        }
        XCTAssertEqual(firstParticipant["displayName"], .string("private"))
        XCTAssertEqual(firstParticipant["initials"], .string("P"))
        XCTAssertEqual(firstParticipant["presenceLabel"], .string("Aktiv"))
        XCTAssertEqual(firstParticipant["messageCountLabel"], .string("1 melding"))
        guard case let .integer(messageCount)? = firstParticipant["messageCount"] else {
            XCTFail("Expected integer messageCount")
            return
        }
        XCTAssertEqual(messageCount, 1)

        await fulfillment(of: [flowExpectation], timeout: 1.0)
        XCTAssertEqual(receivedFlow?.id, try? firstMessage["id"]?.stringValue())
    }

    func testComposerDraftIsScopedPerRequesterAndClearedAfterSend() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let other = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(keypath: "compose.body", value: .string("Utkast fra gjest"), requester: other)
        _ = try await cell.set(keypath: "compose.contentType", value: .string("markdown"), requester: other)

        let ownerDraftBefore = try await cell.get(keypath: "compose.body", requester: owner)
        XCTAssertEqual(ownerDraftBefore, .string(""))

        let guestDraftBefore = try await cell.get(keypath: "compose.body", requester: other)
        XCTAssertEqual(guestDraftBefore, .string("Utkast fra gjest"))

        let sendResponse = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: other)
        guard case let .object(responseObject)? = sendResponse else {
            XCTFail("Expected response object from sendComposedMessage")
            return
        }
        XCTAssertEqual(responseObject["status"], .string("sent"))

        let guestDraftAfter = try await cell.get(keypath: "compose.body", requester: other)
        XCTAssertEqual(guestDraftAfter, .string(""))

        let contentTypeAfter = try await cell.get(keypath: "compose.contentType", requester: other)
        XCTAssertEqual(contentTypeAfter, .string("text/markdown"))

        let messagesValue = try await cell.get(keypath: "messages", requester: other)
        guard case let .list(messages) = messagesValue,
              messages.count == 1,
              case let .object(firstMessage) = messages[0] else {
            XCTFail("Expected one persisted message")
            return
        }
        XCTAssertEqual(firstMessage["content"], .string("Utkast fra gjest"))
        XCTAssertEqual(firstMessage["ownerDisplayName"], .string("guest"))
    }

    func testComposerStateProvidesPreviewMetadata() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "compose.body",
            value: .string("## Agenda\n- Demo\n- Q&A"),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "compose.contentType",
            value: .string("markdown"),
            requester: owner
        )

        let composerState = try await cell.get(keypath: "compose.state", requester: owner)
        guard case let .object(composerObject) = composerState else {
            XCTFail("Expected compose.state object")
            return
        }

        XCTAssertEqual(composerObject["contentType"], .string("text/markdown"))
        XCTAssertEqual(composerObject["formatLabel"], .string("Markdown"))
        XCTAssertEqual(composerObject["isMarkdown"], .bool(true))
        guard case let .integer(characterCount)? = composerObject["characterCount"] else {
            XCTFail("Expected integer characterCount")
            return
        }
        XCTAssertEqual(characterCount, 22)
        guard case let .integer(lineCount)? = composerObject["lineCount"] else {
            XCTFail("Expected integer lineCount")
            return
        }
        XCTAssertEqual(lineCount, 3)
        XCTAssertEqual(composerObject["characterCountLabel"], .string("22 tegn"))
        XCTAssertEqual(composerObject["lineCountLabel"], .string("3 linjer"))
        XCTAssertEqual(composerObject["previewSummary"], .string("## Agenda - Demo - Q&A"))
        XCTAssertEqual(composerObject["previewRichText"], .string("## Agenda\n- Demo\n- Q&A"))

        let previewRows = try await cell.get(keypath: "compose.previewRows", requester: owner)
        guard case let .list(rows) = previewRows,
              rows.count == 1,
              case let .object(previewObject) = rows[0] else {
            XCTFail("Expected compose.previewRows with a single preview row")
            return
        }

        XCTAssertEqual(previewObject["id"], .string("compose-\(owner.uuid)"))
        XCTAssertEqual(previewObject["sendHint"], .string("Klar til sending som markdown til alle klienter som absorberer samme chat."))

        _ = try await cell.set(keypath: "clearComposer", value: .bool(true), requester: owner)
        let clearedComposerState = try await cell.get(keypath: "compose.state", requester: owner)
        guard case let .object(clearedComposerObject) = clearedComposerState else {
            XCTFail("Expected cleared compose.state object")
            return
        }
        XCTAssertEqual(clearedComposerObject["body"], .string(""))
        XCTAssertEqual(clearedComposerObject["previewSummary"], .string("Ingen melding ennå"))
        XCTAssertEqual(clearedComposerObject["isEmpty"], .bool(true))
    }

    func testExploreContractsAdvertiseMessageAndComposerSchemas() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "sendMessage",
            requester: owner,
            expectedMethod: .set,
            expectedInputType: "oneOf",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "compose.state",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: cell,
            key: "crypto.state",
            requester: owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertPermissions(
            on: cell,
            key: "sendMessage",
            requester: owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: cell,
            key: "sendMessage",
            input: .string("hei"),
            requester: outsider
        )
    }

    func testCryptoStateDeclaresBootstrapPolicyAndPreferredSuite() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        let cryptoState = try await cell.get(keypath: "crypto.state", requester: owner)
        guard case let .object(cryptoObject) = cryptoState else {
            XCTFail("Expected crypto.state object")
            return
        }

        XCTAssertEqual(cryptoObject["status"], .string("preview-ready"))
        XCTAssertEqual(cryptoObject["encryptionEnabled"], .bool(false))
        XCTAssertEqual(cryptoObject["bootstrapOnly"], .bool(true))
        XCTAssertEqual(cryptoObject["envelopePreparationAvailable"], .bool(true))
        XCTAssertEqual(cryptoObject["preferredSuiteID"], .string("haven.chat.message.v1"))
        XCTAssertEqual(cryptoObject["supportsForwardSecrecy"], .bool(true))
        XCTAssertEqual(cryptoObject["requiresSenderSignature"], .bool(true))

        guard case let .object(policy)? = cryptoObject["policy"] else {
            XCTFail("Expected crypto policy object")
            return
        }
        XCTAssertEqual(policy["preferredSuiteID"], .string("haven.chat.message.v1"))
        XCTAssertEqual(policy["allowLegacyFallback"], .bool(false))

        guard case let .list(supportedSuites)? = cryptoObject["supportedSuites"],
              supportedSuites.count == 1,
              case let .object(firstSuite) = supportedSuites[0] else {
            XCTFail("Expected supported crypto suite list")
            return
        }
        XCTAssertEqual(firstSuite["id"], .string("haven.chat.message.v1"))
        XCTAssertEqual(firstSuite["purpose"], .string("chatMessage"))
        XCTAssertEqual(firstSuite["contentAlgorithm"], .string("chachaPoly"))
        XCTAssertEqual(firstSuite["keyAgreementAlgorithm"], .string("x25519HKDFSHA256"))
        XCTAssertEqual(firstSuite["curveType"], .string("Curve25519"))

        let stateValue = try await cell.get(keypath: "state", requester: owner)
        guard case let .object(stateObject) = stateValue,
              case let .object(nestedCrypto)? = stateObject["crypto"] else {
            XCTFail("Expected nested state.crypto object")
            return
        }
        XCTAssertEqual(nestedCrypto["preferredSuiteID"], .string("haven.chat.message.v1"))
        XCTAssertEqual(nestedCrypto["bootstrapOnly"], .bool(true))
    }

    func testMembershipChangeMarksRekeyRequiredUntilCheckpointIsAcknowledged() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        let initialStatus = try await cell.get(keypath: "crypto.rekeyStatus", requester: owner)
        guard case let .object(initialStatusObject) = initialStatus else {
            XCTFail("Expected crypto.rekeyStatus object")
            return
        }
        XCTAssertEqual(initialStatusObject["rekeyRequired"], .bool(false))
        XCTAssertEqual(initialStatusObject["membershipVersion"], .integer(1))
        XCTAssertEqual(initialStatusObject["currentEnvelopeGeneration"], .integer(1))

        _ = try await cell.flow(requester: guest)

        let changedStatus = try await cell.get(keypath: "crypto.rekeyStatus", requester: owner)
        guard case let .object(changedStatusObject) = changedStatus,
              case let .object(currentMembership)? = changedStatusObject["currentMembership"] else {
            XCTFail("Expected changed crypto.rekeyStatus object")
            return
        }
        XCTAssertEqual(changedStatusObject["rekeyRequired"], .bool(true))
        XCTAssertEqual(changedStatusObject["membershipVersion"], .integer(2))
        XCTAssertEqual(changedStatusObject["currentEnvelopeGeneration"], .integer(1))
        XCTAssertEqual(currentMembership["recipientCount"], .integer(2))
        XCTAssertEqual(currentMembership["envelopeGeneration"], .integer(1))
        XCTAssertEqual(currentMembership["lastMembershipChangeReason"], .string("contextMemberJoined"))

        let acknowledgeResponse = try await cell.set(
            keypath: "crypto.requestRekey",
            value: .object(["reason": .string("contextMemberJoined")]),
            requester: owner
        )
        guard case let .object(acknowledgeObject)? = acknowledgeResponse,
              case let .object(rekeyStatus)? = acknowledgeObject["rekeyStatus"] else {
            XCTFail("Expected crypto.requestRekey response object")
            return
        }
        XCTAssertEqual(acknowledgeObject["status"], .string("rekeyed"))
        XCTAssertEqual(acknowledgeObject["envelopeGeneration"], .integer(2))
        XCTAssertEqual(rekeyStatus["rekeyRequired"], .bool(false))
        XCTAssertEqual(rekeyStatus["lastRekeyReason"], .string("contextMemberJoined"))
        XCTAssertEqual(rekeyStatus["lastRekeyMembershipVersion"], .integer(2))
        XCTAssertEqual(rekeyStatus["currentEnvelopeGeneration"], .integer(2))
        XCTAssertEqual(rekeyStatus["lastRekeyEnvelopeGeneration"], .integer(2))
    }

    func testRekeyCheckpointSurvivesRoundTripAndLaterMembershipMutation() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "audience.acceptInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "crypto.requestRekey",
            value: .string("acceptedInvite"),
            requester: owner
        )

        let restoredCell = try await roundTrip(cell)

        let restoredStatus = try await restoredCell.get(keypath: "crypto.rekeyStatus", requester: owner)
        guard case let .object(restoredStatusObject) = restoredStatus else {
            XCTFail("Expected restored crypto.rekeyStatus object")
            return
        }
        XCTAssertEqual(restoredStatusObject["rekeyRequired"], .bool(false))
        XCTAssertEqual(restoredStatusObject["lastRekeyReason"], .string("acceptedInvite"))
        XCTAssertEqual(restoredStatusObject["currentEnvelopeGeneration"], .integer(2))
        XCTAssertEqual(restoredStatusObject["lastRekeyEnvelopeGeneration"], .integer(2))

        _ = try await restoredCell.set(
            keypath: "audience.revokeInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let mutatedStatus = try await restoredCell.get(keypath: "crypto.rekeyStatus", requester: owner)
        guard case let .object(mutatedStatusObject) = mutatedStatus,
              case let .object(currentMembership)? = mutatedStatusObject["currentMembership"] else {
            XCTFail("Expected mutated crypto.rekeyStatus object")
            return
        }
        XCTAssertEqual(mutatedStatusObject["rekeyRequired"], .bool(true))
        XCTAssertEqual(mutatedStatusObject["currentEnvelopeGeneration"], .integer(2))
        XCTAssertEqual(currentMembership["lastMembershipChangeReason"], .string("invitationStatusChanged:revoked"))
        XCTAssertEqual(currentMembership["envelopeGeneration"], .integer(2))
        XCTAssertEqual(currentMembership["recipientCount"], .integer(1))
    }

    func testPrepareDraftEnvelopeReturnsRecipientsHeaderAndCiphertext() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda"), requester: owner)
        _ = try await cell.set(keypath: "compose.contentType", value: .string("markdown"), requester: owner)

        let result = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(response)? = result else {
            XCTFail("Expected prepared envelope response")
            return
        }

        XCTAssertEqual(response["status"], .string("prepared"))
        XCTAssertEqual(response["senderIdentityUUID"], .string(owner.uuid))
        XCTAssertEqual(response["senderDisplayName"], .string("private"))
        XCTAssertEqual(response["contentType"], .string("text/markdown"))
        guard case let .integer(recipientCount)? = response["recipientCount"] else {
            XCTFail("Expected integer recipientCount")
            return
        }
        XCTAssertEqual(recipientCount, 2)

        guard case let .list(recipients)? = response["recipients"] else {
            XCTFail("Expected recipient descriptor list")
            return
        }
        XCTAssertEqual(recipients.count, 2)

        guard case let .object(header)? = response["header"] else {
            XCTFail("Expected header object")
            return
        }
        XCTAssertEqual(header["suiteID"], .string("haven.chat.message.v1"))
        XCTAssertEqual(header["envelopeGeneration"], .integer(1))
        guard case let .list(recipientKeys)? = header["recipientKeys"] else {
            XCTFail("Expected wrapped recipient keys")
            return
        }
        XCTAssertEqual(recipientKeys.count, 2)

        guard case let .string(ciphertextB64)? = response["combinedCiphertextBase64"],
              let ciphertext = Data(base64Encoded: ciphertextB64) else {
            XCTFail("Expected base64 ciphertext")
            return
        }
        XCTAssertFalse(ciphertext.isEmpty)

        guard case let .string(signatureB64)? = response["senderSignatureBase64"],
              let signature = Data(base64Encoded: signatureB64) else {
            XCTFail("Expected sender signature")
            return
        }
        XCTAssertFalse(signature.isEmpty)
    }

    func testPreparedEnvelopesAdvanceGenerationOnlyAfterRekeyAcknowledgement() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "compose.body", value: .string("Agenda før rekey"), requester: owner)

        let beforeRekey = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(beforeObject)? = beforeRekey,
              case let .object(beforeHeader)? = beforeObject["header"] else {
            XCTFail("Expected prepared envelope before rekey")
            return
        }
        XCTAssertEqual(beforeHeader["envelopeGeneration"], .integer(1))

        _ = try await cell.set(keypath: "crypto.requestRekey", value: .string("contextMemberJoined"), requester: owner)
        _ = try await cell.set(keypath: "compose.body", value: .string("Agenda etter rekey"), requester: owner)

        let afterRekey = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(afterObject)? = afterRekey,
              case let .object(afterHeader)? = afterObject["header"] else {
            XCTFail("Expected prepared envelope after rekey")
            return
        }
        XCTAssertEqual(afterHeader["envelopeGeneration"], .integer(2))
    }

    func testDraftAndSentArchiveModePersistsEncryptedCompanionForComposedMessages() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)

        let defaultArchive = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(defaultArchiveEntries) = defaultArchive else {
            XCTFail("Expected encrypted message archive list")
            return
        }
        XCTAssertEqual(defaultArchiveEntries.count, 0)

        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda"), requester: owner)
        _ = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        _ = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: owner)

        let archiveWhileDefaultMode = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(defaultModeArchiveEntries) = archiveWhileDefaultMode else {
            XCTFail("Expected encrypted message archive list after default-mode send")
            return
        }
        XCTAssertEqual(defaultModeArchiveEntries.count, 0)

        _ = try await cell.set(keypath: "crypto.persistenceMode", value: .string("draftAndSentArchive"), requester: owner)
        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda 2"), requester: owner)
        _ = try await cell.set(keypath: "compose.contentType", value: .string("markdown"), requester: owner)
        _ = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)

        let sendResponse = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: owner)
        guard case let .object(sendObject)? = sendResponse,
              case let .object(sentMessage)? = sendObject["message"] else {
            XCTFail("Expected sent message response object")
            return
        }

        XCTAssertEqual(sentMessage["encryptedCompanionAvailable"], .bool(true))
        guard case let .object(sentMessageCrypto)? = sentMessage["crypto"] else {
            XCTFail("Expected sent message crypto metadata")
            return
        }
        XCTAssertEqual(sentMessageCrypto["state"], .string("encryptedCompanionAvailable"))
        XCTAssertEqual(sentMessageCrypto["openStatus"], .string("notOpened"))

        let archive = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(archiveEntries) = archive,
              archiveEntries.count == 1,
              case let .object(firstArchiveEntry) = archiveEntries[0] else {
            XCTFail("Expected one encrypted archive entry")
            return
        }

        XCTAssertEqual(firstArchiveEntry["messageID"], sentMessage["id"])
        XCTAssertEqual(firstArchiveEntry["source"], .string("sendComposedMessage"))
        XCTAssertEqual(firstArchiveEntry["contentType"], .string("text/markdown"))
        guard case let .integer(recipientCount)? = firstArchiveEntry["recipientCount"] else {
            XCTFail("Expected encrypted archive recipientCount")
            return
        }
        XCTAssertEqual(recipientCount, 2)
    }

    func testOpenEnvelopeDecryptsPayloadAndVerifiesSender() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda"), requester: owner)
        _ = try await cell.set(keypath: "compose.contentType", value: .string("markdown"), requester: owner)

        let prepared = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(preparedObject)? = prepared else {
            XCTFail("Expected prepared envelope object")
            return
        }

        var openPayload = preparedObject
        openPayload["senderIdentityUUID"] = .string(owner.uuid)
        openPayload["recipientIdentityUUID"] = .string(guest.uuid)

        let opened = try await cell.set(keypath: "crypto.openEnvelope", value: .object(openPayload), requester: guest)
        guard case let .object(openedObject)? = opened else {
            XCTFail("Expected opened envelope object")
            return
        }

        XCTAssertEqual(openedObject["status"], .string("opened"))
        XCTAssertEqual(openedObject["senderIdentityUUID"], .string(owner.uuid))
        XCTAssertEqual(openedObject["recipientIdentityUUID"], .string(guest.uuid))
        XCTAssertEqual(openedObject["senderVerified"], .bool(true))
        XCTAssertEqual(openedObject["envelopeGeneration"], .integer(1))
        XCTAssertEqual(openedObject["contentType"], .string("text/markdown"))
        XCTAssertEqual(openedObject["topic"], .string("chat"))
        XCTAssertEqual(openedObject["plaintext"], .string("Fortrolig agenda"))

        guard case let .string(plaintextBase64)? = openedObject["plaintextBase64"],
              let plaintextData = Data(base64Encoded: plaintextBase64),
              let plaintextString = String(data: plaintextData, encoding: .utf8) else {
            XCTFail("Expected base64 plaintext in openEnvelope response")
            return
        }
        XCTAssertEqual(plaintextString, "Fortrolig agenda")
    }

    func testOpeningArchivedEncryptedCompanionUpdatesMessageCryptoMetadata() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "crypto.persistenceMode", value: .string("draftAndSentArchive"), requester: owner)
        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda"), requester: owner)
        _ = try await cell.set(keypath: "compose.contentType", value: .string("markdown"), requester: owner)
        _ = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)

        let sendResponse = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: owner)
        guard case let .object(sendObject)? = sendResponse,
              case let .object(sentMessage)? = sendObject["message"],
              case let .string(messageID)? = sentMessage["id"] else {
            XCTFail("Expected sent message response with message id")
            return
        }

        let archive = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(archiveEntries) = archive,
              archiveEntries.count == 1,
              case let .object(firstArchiveEntry) = archiveEntries[0] else {
            XCTFail("Expected one encrypted archive entry")
            return
        }

        var openPayload = firstArchiveEntry
        openPayload["messageID"] = .string(messageID)
        openPayload["senderIdentityUUID"] = .string(owner.uuid)
        openPayload["recipientIdentityUUID"] = .string(guest.uuid)

        let opened = try await cell.set(keypath: "crypto.openEnvelope", value: .object(openPayload), requester: guest)
        guard case let .object(openedObject)? = opened else {
            XCTFail("Expected opened envelope object")
            return
        }
        XCTAssertEqual(openedObject["status"], .string("opened"))
        XCTAssertEqual(openedObject["senderVerified"], .bool(true))

        let messages = try await cell.get(keypath: "messages", requester: owner)
        guard case let .list(messageList) = messages,
              messageList.count == 1,
              case let .object(messageObject) = messageList[0],
              case let .object(messageCrypto)? = messageObject["crypto"] else {
            XCTFail("Expected one message with crypto metadata")
            return
        }

        XCTAssertEqual(messageObject["encryptedCompanionAvailable"], .bool(true))
        XCTAssertEqual(messageCrypto["openStatus"], .string("opened"))
        XCTAssertEqual(messageCrypto["senderVerified"], .bool(true))
        XCTAssertEqual(messageCrypto["lastOpenRecipientUUID"], .string(guest.uuid))

        let updatedArchive = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(updatedArchiveEntries) = updatedArchive,
              updatedArchiveEntries.count == 1,
              case let .object(updatedArchiveObject) = updatedArchiveEntries[0] else {
            XCTFail("Expected updated encrypted archive entry")
            return
        }

        XCTAssertEqual(updatedArchiveObject["openStatus"], .string("opened"))
        XCTAssertEqual(updatedArchiveObject["senderVerified"], .bool(true))
        XCTAssertEqual(updatedArchiveObject["lastOpenRecipientUUID"], .string(guest.uuid))
        XCTAssertEqual(updatedArchiveObject["envelopeGeneration"], .integer(1))
    }

    func testArchivedEncryptedCompanionsRetainHistoricalEnvelopeGenerationsAcrossRekey() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(keypath: "crypto.persistenceMode", value: .string("draftAndSentArchive"), requester: owner)
        _ = try await cell.set(keypath: "compose.body", value: .string("Melding før rekey"), requester: owner)
        _ = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)

        let firstSend = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: owner)
        guard case let .object(firstSendObject)? = firstSend,
              case let .object(firstMessage)? = firstSendObject["message"],
              case let .string(firstMessageID)? = firstMessage["id"] else {
            XCTFail("Expected first sent message")
            return
        }

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "crypto.requestRekey", value: .string("contextMemberJoined"), requester: owner)
        _ = try await cell.set(keypath: "compose.body", value: .string("Melding etter rekey"), requester: owner)
        _ = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)

        let secondSend = try await cell.set(keypath: "sendComposedMessage", value: .bool(true), requester: owner)
        guard case let .object(secondSendObject)? = secondSend,
              case let .object(secondMessage)? = secondSendObject["message"],
              case let .string(secondMessageID)? = secondMessage["id"] else {
            XCTFail("Expected second sent message")
            return
        }

        let archive = try await cell.get(keypath: "crypto.encryptedMessages", requester: owner)
        guard case let .list(archiveEntries) = archive else {
            XCTFail("Expected encrypted message archive list")
            return
        }

        let generationByMessageID = archiveEntries.reduce(into: [String: Int]()) { partialResult, value in
            guard case let .object(object) = value,
                  case let .string(messageID)? = object["messageID"],
                  case let .integer(envelopeGeneration)? = object["envelopeGeneration"] else {
                return
            }
            partialResult[messageID] = envelopeGeneration
        }

        XCTAssertEqual(generationByMessageID[firstMessageID], 1)
        XCTAssertEqual(generationByMessageID[secondMessageID], 2)
    }

    func testPreparedDraftEnvelopeIsCachedPerRequesterAndClearedWhenComposerChanges() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(keypath: "compose.body", value: .string("Fortrolig agenda"), requester: owner)

        let initialDraftEnvelope = try await cell.get(keypath: "crypto.draftEnvelope", requester: owner)
        XCTAssertEqual(initialDraftEnvelope, .null)

        let prepared = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(preparedObject)? = prepared else {
            XCTFail("Expected prepared envelope object")
            return
        }

        let cachedDraftEnvelope = try await cell.get(keypath: "crypto.draftEnvelope", requester: owner)
        guard case let .object(cachedObject) = cachedDraftEnvelope else {
            XCTFail("Expected cached draft envelope object")
            return
        }

        XCTAssertEqual(cachedObject["status"], .string("prepared"))
        XCTAssertEqual(cachedObject["senderIdentityUUID"], preparedObject["senderIdentityUUID"])
        XCTAssertEqual(cachedObject["combinedCiphertextBase64"], preparedObject["combinedCiphertextBase64"])
        XCTAssertEqual(cachedObject["recipientCount"], preparedObject["recipientCount"])

        _ = try await cell.set(keypath: "compose.body", value: .string("Oppdatert agenda"), requester: owner)
        let clearedDraftEnvelope = try await cell.get(keypath: "crypto.draftEnvelope", requester: owner)
        XCTAssertEqual(clearedDraftEnvelope, .null)
    }

    func testAudienceModeRequiresAcceptedInvitesBeforeRecipientsResolve() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )
        _ = try await cell.set(keypath: "audience.mode", value: .string("invitedIdentities"), requester: owner)

        let pendingAudience = try await cell.get(keypath: "audience", requester: owner)
        guard case let .object(pendingAudienceObject) = pendingAudience else {
            XCTFail("Expected audience object")
            return
        }
        XCTAssertEqual(pendingAudienceObject["mode"], .string("invitedIdentities"))
        guard case let .integer(pendingInviteCount)? = pendingAudienceObject["pendingInviteCount"] else {
            XCTFail("Expected pendingInviteCount")
            return
        }
        XCTAssertEqual(pendingInviteCount, 1)
        guard case let .integer(invitedCountBeforeAccept)? = pendingAudienceObject["invitedCount"] else {
            XCTFail("Expected invitedCount")
            return
        }
        XCTAssertEqual(invitedCountBeforeAccept, 0)

        guard case let .list(invitationObjects)? = pendingAudienceObject["invitations"],
              invitationObjects.count == 1,
              case let .object(invitationObject) = invitationObjects[0] else {
            XCTFail("Expected exactly one invitation record")
            return
        }
        XCTAssertEqual(invitationObject["identityUUID"], .string(invitee.uuid))
        XCTAssertEqual(invitationObject["status"], .string("pending"))

        let pendingRecipients = try await cell.get(keypath: "crypto.recipients", requester: owner)
        guard case let .list(pendingRecipientObjects) = pendingRecipients else {
            XCTFail("Expected crypto recipient list")
            return
        }

        let pendingRecipientIDs = pendingRecipientObjects.compactMap { value -> String? in
            guard case let .object(object) = value,
                  case let .string(identityUUID)? = object["identityUUID"] else {
                return nil
            }
            return identityUUID
        }

        XCTAssertTrue(pendingRecipientIDs.contains(owner.uuid))
        XCTAssertFalse(pendingRecipientIDs.contains(invitee.uuid))
        XCTAssertFalse(pendingRecipientIDs.contains(guest.uuid))

        _ = try await cell.set(
            keypath: "audience.acceptInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let acceptedAudience = try await cell.get(keypath: "audience", requester: owner)
        guard case let .object(acceptedAudienceObject) = acceptedAudience else {
            XCTFail("Expected accepted audience object")
            return
        }
        guard case let .integer(acceptedInviteCount)? = acceptedAudienceObject["acceptedInviteCount"] else {
            XCTFail("Expected acceptedInviteCount")
            return
        }
        XCTAssertEqual(acceptedInviteCount, 1)
        guard case let .integer(invitedCountAfterAccept)? = acceptedAudienceObject["invitedCount"] else {
            XCTFail("Expected invitedCount")
            return
        }
        XCTAssertEqual(invitedCountAfterAccept, 1)

        let recipients = try await cell.get(keypath: "crypto.recipients", requester: owner)
        guard case let .list(recipientObjects) = recipients else {
            XCTFail("Expected crypto recipient list")
            return
        }

        let recipientIDs = recipientObjects.compactMap { value -> String? in
            guard case let .object(object) = value,
                  case let .string(identityUUID)? = object["identityUUID"] else {
                return nil
            }
            return identityUUID
        }

        XCTAssertTrue(recipientIDs.contains(owner.uuid))
        XCTAssertTrue(recipientIDs.contains(invitee.uuid))
        XCTAssertFalse(recipientIDs.contains(guest.uuid))
    }

    func testRemoveContextMembersForcesFreshRekeyAndExcludesRemovedRecipients() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let observer = await vault.identity(for: "observer", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.flow(requester: guest)
        _ = try await cell.flow(requester: observer)
        _ = try await cell.set(keypath: "crypto.requestRekey", value: .string("initialAudience"), requester: owner)

        let removalResponse = try await cell.set(
            keypath: "audience.removeContextMembers",
            value: .list([.identity(guest)]),
            requester: owner
        )
        guard case let .object(removalObject)? = removalResponse,
              case let .list(resolvedRecipients)? = removalObject["resolvedRecipients"] else {
            XCTFail("Expected audience state after removing a context member")
            return
        }

        let resolvedIDs = resolvedRecipients.compactMap { value -> String? in
            guard case let .object(object) = value,
                  case let .string(identityUUID)? = object["identityUUID"] else {
                return nil
            }
            return identityUUID
        }
        XCTAssertFalse(resolvedIDs.contains(guest.uuid))
        XCTAssertTrue(resolvedIDs.contains(observer.uuid))
        XCTAssertTrue(resolvedIDs.contains(owner.uuid))

        let rekeyStatus = try await cell.get(keypath: "crypto.rekeyStatus", requester: owner)
        guard case let .object(rekeyObject) = rekeyStatus,
              case let .object(currentMembership)? = rekeyObject["currentMembership"] else {
            XCTFail("Expected crypto.rekeyStatus after removing a context member")
            return
        }
        XCTAssertEqual(rekeyObject["rekeyRequired"], .bool(true))
        XCTAssertEqual(rekeyObject["currentEnvelopeGeneration"], .integer(2))
        XCTAssertEqual(currentMembership["recipientCount"], .integer(2))
        XCTAssertEqual(currentMembership["lastMembershipChangeReason"], .string("contextMembersRemoved"))
        XCTAssertEqual(currentMembership["envelopeGeneration"], .integer(2))

        _ = try await cell.set(keypath: "compose.body", value: .string("Kun gjeldende medlemmer"), requester: owner)
        _ = try await cell.set(keypath: "crypto.requestRekey", value: .string("contextMembersRemoved"), requester: owner)
        let prepared = try await cell.set(keypath: "crypto.prepareDraftEnvelope", value: .bool(true), requester: owner)
        guard case let .object(preparedObject)? = prepared,
              case let .object(header)? = preparedObject["header"],
              case let .list(recipientDescriptors)? = preparedObject["recipients"] else {
            XCTFail("Expected prepared envelope after removing a context member")
            return
        }

        let recipientDescriptorIDs = recipientDescriptors.compactMap { value -> String? in
            guard case let .object(object) = value,
                  case let .string(identityUUID)? = object["identityUUID"] else {
                return nil
            }
            return identityUUID
        }
        XCTAssertEqual(header["envelopeGeneration"], .integer(3))
        XCTAssertFalse(recipientDescriptorIDs.contains(guest.uuid))
        XCTAssertTrue(recipientDescriptorIDs.contains(observer.uuid))
        XCTAssertTrue(recipientDescriptorIDs.contains(owner.uuid))
    }

    func testInvitationArtifactAcceptanceFlowMarksInvitationAccepted() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected a single invitation artifact")
            return
        }

        let artifactList = try await cell.get(keypath: "audience.invitationArtifacts", requester: owner)
        guard case let .list(artifactEntries) = artifactList else {
            XCTFail("Expected invitationArtifacts list")
            return
        }
        XCTAssertEqual(artifactEntries.count, 1)

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(acceptanceObject)? = acceptanceResponse else {
            XCTFail("Expected invitation acceptance object")
            return
        }

        let acceptResponse = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(acceptanceObject)
            ]),
            requester: owner
        )
        guard case let .object(acceptedObject)? = acceptResponse else {
            XCTFail("Expected acceptInvitationArtifact response")
            return
        }

        XCTAssertEqual(acceptedObject["status"], .string("accepted"))
        XCTAssertEqual(acceptedObject["invitationID"], artifactObject["invitationID"])
        XCTAssertEqual(acceptedObject["acceptanceID"], acceptanceObject["acceptanceID"])

        let audience = try await cell.get(keypath: "audience", requester: owner)
        guard case let .object(audienceObject) = audience,
              case let .integer(acceptedInviteCount)? = audienceObject["acceptedInviteCount"],
              case let .list(invitationObjects)? = audienceObject["invitations"],
              invitationObjects.count == 1,
              case let .object(invitationObject) = invitationObjects[0] else {
            XCTFail("Expected accepted audience payload")
            return
        }

        XCTAssertEqual(acceptedInviteCount, 1)
        XCTAssertEqual(invitationObject["status"], .string("accepted"))
        XCTAssertEqual(invitationObject["artifactAvailable"], .bool(true))
        XCTAssertEqual(invitationObject["acceptanceAvailable"], .bool(true))

        let recipients = try await cell.get(keypath: "crypto.recipients", requester: owner)
        guard case let .list(recipientObjects) = recipients else {
            XCTFail("Expected recipient list after accepted invitation")
            return
        }
        let recipientIDs = recipientObjects.compactMap { value -> String? in
            guard case let .object(object) = value,
                  case let .string(identityUUID)? = object["identityUUID"] else {
                return nil
            }
            return identityUUID
        }
        XCTAssertTrue(recipientIDs.contains(invitee.uuid))
    }

    func testInvitationAcceptanceRejectsWrongRequester() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: outsider
        )
        XCTAssertEqual(acceptanceResponse, .string("error: requester does not match invited identity"))

        let audience = try await cell.get(keypath: "audience", requester: owner)
        guard case let .object(audienceObject) = audience,
              case let .integer(acceptedInviteCount)? = audienceObject["acceptedInviteCount"],
              case let .integer(pendingInviteCount)? = audienceObject["pendingInviteCount"] else {
            XCTFail("Expected audience object")
            return
        }
        XCTAssertEqual(acceptedInviteCount, 0)
        XCTAssertEqual(pendingInviteCount, 1)
    }

    func testInvitationArtifactAcceptanceRetryIsIdempotent() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(acceptanceObject)? = acceptanceResponse else {
            XCTFail("Expected invitation acceptance object")
            return
        }

        let payload: ValueType = .object([
            "artifact": .object(artifactObject),
            "acceptance": .object(acceptanceObject)
        ])

        let firstAccept = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: payload,
            requester: owner
        )
        guard case let .object(firstObject)? = firstAccept else {
            XCTFail("Expected first accept response")
            return
        }
        XCTAssertEqual(firstObject["status"], .string("accepted"))
        XCTAssertEqual(firstObject["idempotent"], .bool(false))

        let secondAccept = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: payload,
            requester: owner
        )
        guard case let .object(secondObject)? = secondAccept else {
            XCTFail("Expected second accept response")
            return
        }
        XCTAssertEqual(secondObject["status"], .string("accepted"))
        XCTAssertEqual(secondObject["idempotent"], .bool(true))
        XCTAssertEqual(secondObject["acceptanceID"], acceptanceObject["acceptanceID"])

        let audience = try await cell.get(keypath: "audience", requester: owner)
        guard case let .object(audienceObject) = audience,
              case let .integer(acceptedInviteCount)? = audienceObject["acceptedInviteCount"],
              case let .list(invitationObjects)? = audienceObject["invitations"],
              invitationObjects.count == 1,
              case let .object(invitationObject) = invitationObjects[0] else {
            XCTFail("Expected invitation audience state")
            return
        }

        XCTAssertEqual(acceptedInviteCount, 1)
        XCTAssertEqual(invitationObject["artifactState"], .string("consumed"))
        XCTAssertEqual(invitationObject["proofBackedAcceptance"], .bool(true))
    }

    func testInvitationArtifactRejectsSecondAcceptanceAfterConsumption() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        let firstAcceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(firstAcceptanceObject)? = firstAcceptanceResponse else {
            XCTFail("Expected first acceptance object")
            return
        }

        let firstAccept = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(firstAcceptanceObject)
            ]),
            requester: owner
        )
        guard case let .object(firstAcceptObject)? = firstAccept else {
            XCTFail("Expected first accept response")
            return
        }
        XCTAssertEqual(firstAcceptObject["idempotent"], .bool(false))

        let secondAcceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(secondAcceptanceObject)? = secondAcceptanceResponse else {
            XCTFail("Expected second acceptance object")
            return
        }

        let replayResponse = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(secondAcceptanceObject)
            ]),
            requester: owner
        )
        XCTAssertEqual(replayResponse, .string("error: invitation artifact already consumed"))
    }

    func testGenerateInvitationArtifactsReusesIssuedArtifact() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let firstResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(firstArtifacts)? = firstResponse,
              firstArtifacts.count == 1,
              case let .object(firstArtifact) = firstArtifacts[0] else {
            XCTFail("Expected first invitation artifact")
            return
        }

        let secondResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(secondArtifacts)? = secondResponse,
              secondArtifacts.count == 1,
              case let .object(secondArtifact) = secondArtifacts[0] else {
            XCTFail("Expected reused invitation artifact")
            return
        }

        XCTAssertEqual(secondArtifact["invitationID"], firstArtifact["invitationID"])
        XCTAssertEqual(secondArtifact["createdAt"], firstArtifact["createdAt"])

        let artifactList = try await cell.get(keypath: "audience.invitationArtifacts", requester: owner)
        guard case let .list(artifactEntries) = artifactList else {
            XCTFail("Expected issued invitationArtifacts list")
            return
        }
        XCTAssertEqual(artifactEntries.count, 1)

        let invitations = try await cell.get(keypath: "audience.invitations", requester: owner)
        guard case let .list(invitationEntries) = invitations,
              invitationEntries.count == 1,
              case let .object(invitationObject) = invitationEntries[0] else {
            XCTFail("Expected invitation list")
            return
        }
        XCTAssertEqual(invitationObject["artifactState"], .string("issued"))
        XCTAssertEqual(invitationObject["artifactAcceptanceAllowed"], .bool(true))
    }

    func testInspectInvitationArtifactReportsSupersededAfterReissue() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let firstResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(firstArtifacts)? = firstResponse,
              firstArtifacts.count == 1,
              case let .object(firstArtifact) = firstArtifacts[0] else {
            XCTFail("Expected first invitation artifact")
            return
        }

        _ = try await cell.set(
            keypath: "audience.declineInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let secondResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(secondArtifacts)? = secondResponse,
              secondArtifacts.count == 1,
              case let .object(secondArtifact) = secondArtifacts[0] else {
            XCTFail("Expected second invitation artifact")
            return
        }

        XCTAssertNotEqual(secondArtifact["invitationID"], firstArtifact["invitationID"])

        let staleInspection = try await cell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(firstArtifact),
            requester: owner
        )
        guard case let .object(staleInspectionObject)? = staleInspection else {
            XCTFail("Expected stale inspection object")
            return
        }
        XCTAssertEqual(staleInspectionObject["state"], .string("superseded"))
        XCTAssertEqual(staleInspectionObject["acceptanceAllowed"], .bool(false))

        let currentInspection = try await cell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(secondArtifact),
            requester: owner
        )
        guard case let .object(currentInspectionObject)? = currentInspection else {
            XCTFail("Expected current inspection object")
            return
        }
        XCTAssertEqual(currentInspectionObject["state"], .string("issued"))
        XCTAssertEqual(currentInspectionObject["acceptanceAllowed"], .bool(true))
    }

    func testAcceptInvitationArtifactRejectsDeclinedArtifact() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        _ = try await cell.set(
            keypath: "audience.declineInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(acceptanceObject)? = acceptanceResponse else {
            XCTFail("Expected invitation acceptance object")
            return
        }

        let acceptResponse = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(acceptanceObject)
            ]),
            requester: owner
        )
        XCTAssertEqual(acceptResponse, .string("error: invitation artifact has been declined"))
    }

    func testInvitationArtifactsListOnlyShowsIssuedArtifacts() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(acceptanceObject)? = acceptanceResponse else {
            XCTFail("Expected invitation acceptance object")
            return
        }

        _ = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(acceptanceObject)
            ]),
            requester: owner
        )

        let artifactList = try await cell.get(keypath: "audience.invitationArtifacts", requester: owner)
        guard case let .list(artifactEntries) = artifactList else {
            XCTFail("Expected invitationArtifacts list")
            return
        }
        XCTAssertEqual(artifactEntries.count, 0)
    }

    func testInvitationArtifactInspectionSurvivesRoundTripAfterConsumption() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected invitation artifact")
            return
        }

        let acceptanceResponse = try await cell.set(
            keypath: "audience.generateInvitationAcceptance",
            value: .object(artifactObject),
            requester: invitee
        )
        guard case let .object(acceptanceObject)? = acceptanceResponse else {
            XCTFail("Expected acceptance object")
            return
        }

        _ = try await cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object([
                "artifact": .object(artifactObject),
                "acceptance": .object(acceptanceObject)
            ]),
            requester: owner
        )

        let restoredCell = try await roundTrip(cell)

        let inspection = try await restoredCell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(artifactObject),
            requester: owner
        )
        guard case let .object(inspectionObject)? = inspection else {
            XCTFail("Expected inspection object after roundtrip")
            return
        }
        XCTAssertEqual(inspectionObject["state"], .string("consumed"))
        XCTAssertEqual(inspectionObject["acceptanceAllowed"], .bool(false))

        let ledger = try await restoredCell.get(keypath: "audience.invitationLedger", requester: owner)
        guard case let .list(ledgerEntries) = ledger,
              ledgerEntries.count == 1,
              case let .object(ledgerObject) = ledgerEntries[0] else {
            XCTFail("Expected durable invitation ledger")
            return
        }
        XCTAssertEqual(ledgerObject["state"], .string("consumed"))
        XCTAssertEqual(ledgerObject["acceptanceAllowed"], .bool(false))
    }

    func testSupersededInvitationArtifactInspectionSurvivesRoundTrip() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let firstResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(firstArtifacts)? = firstResponse,
              firstArtifacts.count == 1,
              case let .object(firstArtifact) = firstArtifacts[0] else {
            XCTFail("Expected first artifact")
            return
        }

        _ = try await cell.set(
            keypath: "audience.declineInvites",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let secondResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(secondArtifacts)? = secondResponse,
              secondArtifacts.count == 1,
              case let .object(secondArtifact) = secondArtifacts[0] else {
            XCTFail("Expected second artifact")
            return
        }

        let restoredCell = try await roundTrip(cell)

        let staleInspection = try await restoredCell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(firstArtifact),
            requester: owner
        )
        guard case let .object(staleObject)? = staleInspection else {
            XCTFail("Expected stale inspection object")
            return
        }
        XCTAssertEqual(staleObject["state"], .string("superseded"))

        let currentInspection = try await restoredCell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(secondArtifact),
            requester: owner
        )
        guard case let .object(currentObject)? = currentInspection else {
            XCTFail("Expected current inspection object")
            return
        }
        XCTAssertEqual(currentObject["state"], .string("issued"))

        let ledger = try await restoredCell.get(keypath: "audience.invitationLedger", requester: owner)
        guard case let .list(ledgerEntries) = ledger else {
            XCTFail("Expected invitation ledger list")
            return
        }
        XCTAssertEqual(ledgerEntries.count, 2)
    }

    func testClearInvitesRetainsRevokedArtifactInspectionLedger() async throws {
        let previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = true
        defer { CellBase.debugValidateAccessForEverything = previousDebugFlag }

        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let invitee = await vault.identity(for: "invitee", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        _ = try await cell.set(
            keypath: "audience.inviteIdentities",
            value: .list([.identity(invitee)]),
            requester: owner
        )

        let artifactResponse = try await cell.set(
            keypath: "audience.generateInvitationArtifacts",
            value: .bool(true),
            requester: owner
        )
        guard case let .list(artifacts)? = artifactResponse,
              artifacts.count == 1,
              case let .object(artifactObject) = artifacts[0] else {
            XCTFail("Expected artifact")
            return
        }

        _ = try await cell.set(
            keypath: "audience.clearInvites",
            value: .bool(true),
            requester: owner
        )

        let restoredCell = try await roundTrip(cell)

        let inspection = try await restoredCell.set(
            keypath: "audience.inspectInvitationArtifact",
            value: .object(artifactObject),
            requester: owner
        )
        guard case let .object(inspectionObject)? = inspection else {
            XCTFail("Expected inspection object")
            return
        }
        XCTAssertEqual(inspectionObject["state"], .string("revoked"))
        XCTAssertEqual(inspectionObject["recordFound"], .bool(false))

        let issuedArtifacts = try await restoredCell.get(keypath: "audience.invitationArtifacts", requester: owner)
        guard case let .list(issuedArtifactEntries) = issuedArtifacts else {
            XCTFail("Expected issued artifacts list")
            return
        }
        XCTAssertEqual(issuedArtifactEntries.count, 0)

        let ledger = try await restoredCell.get(keypath: "audience.invitationLedger", requester: owner)
        guard case let .list(ledgerEntries) = ledger,
              ledgerEntries.count == 1,
              case let .object(ledgerObject) = ledgerEntries[0] else {
            XCTFail("Expected revoked ledger entry")
            return
        }
        XCTAssertEqual(ledgerObject["state"], .string("revoked"))
        XCTAssertEqual(ledgerObject["acceptanceAllowed"], .bool(false))
    }

    private func roundTrip(_ cell: ChatCell) async throws -> ChatCell {
        let data = try JSONEncoder().encode(cell)
        let restored = try JSONDecoder().decode(ChatCell.self, from: data)
        try await Task.sleep(nanoseconds: 20_000_000)
        return restored
    }
}

private actor ChatCellTestIdentityVault: IdentityVaultProtocol, IdentityKeyRoleProviderProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private var signingKeysByIdentityUUID: [String: Curve25519.Signing.PrivateKey] = [:]
    private var keyAgreementKeysByIdentityUUID: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var idCounter = 1

    func initialize() async -> IdentityVaultProtocol {
        self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        identitiesByContext[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else { return nil }

        let suffix = String(format: "%012d", idCounter)
        idCounter += 1
        let uuidString = "00000000-0000-0000-0000-\(suffix)"
        let identity = Identity(uuidString, displayName: identityContext, identityVault: self)
        let signingKey = Curve25519.Signing.PrivateKey()
        let keyAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        signingKeysByIdentityUUID[uuidString] = signingKey
        keyAgreementKeysByIdentityUUID[uuidString] = keyAgreementKey
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
        return identity
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        messageData + identity.uuid.data(using: .utf8, allowLossyConversion: false)!
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        let expected = messageData + identity.uuid.data(using: .utf8, allowLossyConversion: false)!
        return signature == expected
    }

    func randomBytes64() async -> Data? {
        Data(repeating: 0xCD, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("chat-test-key-\(tag)", "chat-test-iv-\(tag)")
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
            return signingKeysByIdentityUUID[identity.uuid]?.rawRepresentation
        case .keyAgreement:
            return keyAgreementKeysByIdentityUUID[identity.uuid]?.rawRepresentation
        }
    }
}
