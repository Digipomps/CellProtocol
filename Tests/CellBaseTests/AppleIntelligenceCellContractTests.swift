// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase
@testable import CellApple

final class AppleIntelligenceCellContractTests: XCTestCase {
    func testAppleIntelligenceContractsAdvertiseStateAndPromptKeys() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let outsider = await vault.identity(for: "other", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: "ai.state",
                requester: owner,
                expectedMethod: .get,
                expectedInputType: "null",
                expectedReturnType: "object"
            )
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: "ai.sendPrompt",
                requester: owner,
                expectedMethod: .set,
                expectedInputType: "oneOf",
                expectedReturnType: "string"
            )
            try await CellContractHarness.assertPermissions(
                on: cell,
                key: "ai.sendPrompt",
                requester: owner,
                expected: ["-w--"]
            )
            try await CellContractHarness.assertAdvertisedKey(
                on: cell,
                key: "ai.dequeueOutbox",
                requester: owner,
                expectedMethod: .set,
                expectedInputType: "null",
                expectedReturnType: "oneOf"
            )
            try await CellContractHarness.assertSetDenied(
                on: cell,
                key: "ai.sendPrompt",
                input: .string("hello"),
                requester: outsider
            )
        } else {
            throw XCTSkip("AppleIntelligenceCell contracts require macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testSendValidationContentTypesAndGenericDequeueStayConsistent() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            let malformedPayloads: [ValueType] = [
                .object([:]),
                .object(["content": .null]),
                .object(["content": .list([.string("unsupported")])]),
                .object(["content": .bool(true)]),
                .object(["content": .integer(1)]),
                .object(["content": .string("hello"), "topic": .integer(1)]),
                .object(["content": .string("hello"), "type": .string("invalid")]),
                .object(["content": .string("hello"), "endpoint": .string("cell://ignored")])
            ]
            for payload in malformedPayloads {
                let result = try await cell.set(
                    keypath: "ai.send",
                    value: payload,
                    requester: owner
                )
                XCTAssertEqual(result, .string("paramErr"))
            }
            let malformedPrompts: [ValueType] = [
                .null,
                .string(""),
                .object([:]),
                .object(["prompt": .integer(1)]),
                .object(["prompt": .string("hello"), "type": .string("invalid")]),
                .object(["prompt": .string("hello"), "instructions": .bool(true)])
            ]
            for payload in malformedPrompts {
                let result = try await cell.set(
                    keypath: "ai.sendPrompt",
                    value: payload,
                    requester: owner
                )
                XCTAssertEqual(result, .string("paramErr"))
            }
            guard case let .list(afterMalformed) = try await cell.get(
                keypath: "ai.outbox",
                requester: owner
            ) else {
                return XCTFail("Expected owner outbox")
            }
            XCTAssertTrue(afterMalformed.isEmpty)

            let stringResult = try await cell.set(
                keypath: "ai.send",
                value: .object(["content": .string("hello")]),
                requester: owner
            )
            XCTAssertEqual(stringResult, .string("queued"))
            let stringDequeue = try await cell.set(
                keypath: "ai.dequeueOutbox",
                value: .null,
                requester: owner
            )
            let stringMessage = try XCTUnwrap(stringDequeue)
            XCTAssertEqual(contentType(in: stringMessage), FlowElementContentType.string.rawValue)
            let stringFlow = try flowElementWireRoundTrip(stringMessage)
            guard case let .string(stringContent) = stringFlow.content else {
                return XCTFail("Expected wire-compatible string content")
            }
            XCTAssertEqual(stringContent, "hello")

            let dataResult = try await cell.set(
                keypath: "ai.send",
                value: .object(["content": .data(Data([0xCA, 0xFE]))]),
                requester: owner
            )
            XCTAssertEqual(dataResult, .string("queued"))
            let dataDequeue = try await cell.set(
                keypath: "ai.dequeueOutbox",
                value: .null,
                requester: owner
            )
            let dataMessage = try XCTUnwrap(dataDequeue)
            XCTAssertEqual(contentType(in: dataMessage), FlowElementContentType.base64.rawValue)
            let dataFlow = try flowElementWireRoundTrip(dataMessage)
            guard case let .data(dataContent) = dataFlow.content else {
                return XCTFail("Expected wire-compatible data content")
            }
            XCTAssertEqual(dataContent, Data([0xCA, 0xFE]))

            let objectResult = try await cell.set(
                keypath: "ai.send",
                value: .object(["content": .object(["known": .string("value")])]),
                requester: owner
            )
            XCTAssertEqual(objectResult, .string("queued"))
            let objectMessage = try await cell.set(
                keypath: "ai.dequeueOutbox",
                value: .null,
                requester: owner
            )
            let objectFlow = try flowElementWireRoundTrip(try XCTUnwrap(objectMessage))
            guard case let .object(objectContent) = objectFlow.content else {
                return XCTFail("Expected wire-compatible object content")
            }
            XCTAssertEqual(objectContent["known"], .string("value"))
        } else {
            throw XCTSkip("AppleIntelligenceCell send validation requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testSensitiveAssistantStateAndDequeueRemainOwnerOnlyAcrossSignedAgreements() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let firstMember = await vault.identity(for: "first-member", makeNewIfNotFound: true)!
            let secondMember = await vault.identity(for: "second-member", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            for member in [firstMember, secondMember] {
                let agreement = Agreement(owner: owner)
                agreement.addGrant("rw--", for: AIKeys.root)
                agreement.signatories.append(member)
                let agreementState = await cell.addAgreement(
                    agreement,
                    for: member,
                    authorizedBy: owner
                )
                XCTAssertEqual(agreementState, .signed)
                let publicState = try await cell.get(keypath: "ai.state", requester: member)
                XCTAssertNotNil(publicState)
            }

            _ = try await cell.set(
                keypath: "ai.send",
                value: .object(["content": .string("owner-private-message")]),
                requester: owner
            )
            await cell.storeLastToolArguments(
                .object(["query": .string("owner-private-query")]),
                requester: owner
            )

            var memberView: GeneralCell = cell
            await AppleIntelligenceCellBootstrap().seed(
                cell: &memberView,
                requester: firstMember,
                initialPurposeRef: "forged-purpose"
            )
            guard case let .list(outboxAfterUnauthorizedSeed) = try await cell.get(
                keypath: "ai.outbox",
                requester: owner
            ) else {
                return XCTFail("Expected owner outbox after rejected bootstrap seed")
            }
            XCTAssertEqual(outboxAfterUnauthorizedSeed.count, 1)
            let purposeAfterUnauthorizedSeed = try await cell.get(
                keypath: "ai.currentPurposeRef",
                requester: owner
            )
            XCTAssertEqual(purposeAfterUnauthorizedSeed, .null)

            for member in [firstMember, secondMember] {
                do {
                    _ = try await cell.get(keypath: "ai.outbox", requester: member)
                    XCTFail("Signed non-owner read owner outbox")
                } catch {
                    // Expected inner owner-only policy after the root Agreement gate.
                }
                do {
                    _ = try await cell.get(keypath: "ai.lastToolArguments", requester: member)
                    XCTFail("Signed non-owner read owner tool diagnostics")
                } catch {
                    // Expected.
                }
                do {
                    _ = try await cell.set(
                        keypath: "ai.dequeueOutbox",
                        value: .null,
                        requester: member
                    )
                    XCTFail("Signed non-owner dequeued owner outbox")
                } catch {
                    // Expected.
                }
            }

            let ownerDequeue = try await cell.set(
                keypath: "ai.dequeueOutbox",
                value: .null,
                requester: owner
            )
            XCTAssertNotNil(ownerDequeue)
        } else {
            throw XCTSkip("AppleIntelligenceCell owner policy requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testActionOutcomesAndDiscoveryGenerationDoNotReportFalseSuccess() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)
            var generalCell: GeneralCell = cell
            await AppleIntelligenceCellBootstrap().seed(
                cell: &generalCell,
                requester: owner,
                initialPurposeRef: nil
            )

            let buildResult = try await cell.set(
                keypath: "ai.buildCluster",
                value: .null,
                requester: owner
            )
            XCTAssertEqual(buildResult, .string("unavailable"))

            let firstGeneration = try XCTUnwrap(cell.beginDiscoveryGeneration())
            XCTAssertNil(cell.beginDiscoveryGeneration())
            XCTAssertFalse(
                cell.finishDiscoveryGeneration(UUID(), status: .ready),
                "A stale discovery must not overwrite the active generation"
            )
            let discoveringStatus = try await cell.get(
                keypath: "ai.status",
                requester: owner
            )
            XCTAssertEqual(discoveringStatus, .string(AIStatus.discovering.rawValue))
            XCTAssertTrue(cell.finishDiscoveryGeneration(firstGeneration, status: .ready))
            let secondGeneration = try XCTUnwrap(cell.beginDiscoveryGeneration())
            var resetView: GeneralCell = cell
            await AppleIntelligenceCellBootstrap().seed(
                cell: &resetView,
                requester: owner,
                initialPurposeRef: nil
            )
            XCTAssertFalse(
                cell.finishDiscoveryGeneration(secondGeneration, status: .ready),
                "Bootstrap reset must invalidate in-flight discovery generations"
            )
            let resetStatus = try await cell.get(keypath: "ai.status", requester: owner)
            XCTAssertEqual(resetStatus, .string(AIStatus.idle.rawValue))
        } else {
            throw XCTSkip("AppleIntelligenceCell action outcomes require macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testOutboxExactBoundaryDequeueReappendAndRestorePreserveAccounting() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)
            let payload: ValueType = .object(["content": .string("bounded")])

            for _ in 0..<256 {
                let queued = try await cell.set(
                    keypath: "ai.send",
                    value: payload,
                    requester: owner
                )
                XCTAssertEqual(queued, .string("queued"))
            }
            let rejectedAtBoundary = try await cell.set(
                keypath: "ai.send",
                value: payload,
                requester: owner
            )
            XCTAssertEqual(rejectedAtBoundary, .string("outboxFull"))
            let dequeued = try await cell.set(
                keypath: "ai.dequeueOutbox",
                value: .null,
                requester: owner
            )
            XCTAssertNotNil(dequeued)
            let reappended = try await cell.set(
                keypath: "ai.send",
                value: payload,
                requester: owner
            )
            XCTAssertEqual(reappended, .string("queued"))

            let restored = try JSONDecoder().decode(
                AppleIntelligenceCell.self,
                from: JSONEncoder().encode(cell)
            )
            guard case let .list(restoredOutbox) = try await restored.get(
                keypath: "ai.outbox",
                requester: owner
            ) else {
                return XCTFail("Expected restored outbox")
            }
            XCTAssertEqual(restoredOutbox.count, 256)
            let restoredDequeue = await restored.dequeueOutboxMessage(requester: owner)
            XCTAssertNotNil(restoredDequeue)
            let restoredReappend = try await restored.set(
                keypath: "ai.send",
                value: payload,
                requester: owner
            )
            XCTAssertEqual(restoredReappend, .string("queued"))
        } else {
            throw XCTSkip("AppleIntelligenceCell outbox boundary requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testDecodedAppleIntelligencePreservesRuntimeConfigurationForImmediateUse() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            _ = try await cell.set(
                keypath: "ai.promptText",
                value: .string("Persisted prompt"),
                requester: owner
            )
            _ = try await cell.set(
                keypath: "ai.promptInstructions",
                value: .string("Persisted instructions"),
                requester: owner
            )
            _ = try await cell.set(
                keypath: "ai.sendFlowOnIngest",
                value: .bool(false),
                requester: owner
            )
            _ = try await cell.set(
                keypath: "ai.rankEnabled",
                value: .bool(true),
                requester: owner
            )

            let encoded = try JSONEncoder().encode(cell)
            let decoded = try JSONDecoder().decode(AppleIntelligenceCell.self, from: encoded)

            let restoredPrompt = try await decoded.get(keypath: "ai.promptText", requester: owner)
            let restoredInstructions = try await decoded.get(
                keypath: "ai.promptInstructions",
                requester: owner
            )
            let restoredFlowToggle = try await decoded.get(
                keypath: "ai.sendFlowOnIngest",
                requester: owner
            )
            let restoredRankToggle = try await decoded.get(
                keypath: "ai.rankEnabled",
                requester: owner
            )

            XCTAssertEqual(restoredPrompt, .string("Persisted prompt"))
            XCTAssertEqual(restoredInstructions, .string("Persisted instructions"))
            XCTAssertEqual(restoredFlowToggle, .bool(false))
            XCTAssertEqual(restoredRankToggle, .bool(true))

            let updateResult = try await decoded.set(
                keypath: "ai.promptText",
                value: .string("Updated after restore"),
                requester: owner
            )
            let updatedPrompt = try await decoded.get(keypath: "ai.promptText", requester: owner)
            XCTAssertEqual(updateResult, .string("New prompt text: Updated after restore"))
            XCTAssertEqual(updatedPrompt, .string("Updated after restore"))
        } else {
            throw XCTSkip("AppleIntelligenceCell persistence requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testIngestedAssistantStateIsRealReadOnlyBoundedAndDurable() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let outsider = await vault.identity(for: "outsider", makeNewIfNotFound: true)!
            let wrongKeyOwner = await vault.identity(for: "wrong-key", makeNewIfNotFound: true)!
            let sameUUIDWrongKey = Identity(
                owner.uuid,
                displayName: "same UUID, wrong key",
                identityVault: vault
            )
            sameUUIDWrongKey.publicSecureKey = wrongKeyOwner.publicSecureKey

            let cell = await AppleIntelligenceCell(owner: owner)
            let candidate = CellConfiguration(name: "Known runtime candidate")
            let ingestResult = try await cell.set(
                keypath: "ai.ingestConfigurations",
                value: .list([.cellConfiguration(candidate)]),
                requester: owner
            )
            XCTAssertEqual(ingestResult, .string("ok"))
            try await assertStateAndOutboxContainKnownCandidate(on: cell, requester: owner)

            for key in ["ai.status", "ai.candidates", "ai.outbox", "ai.lastToolArguments"] {
                do {
                    _ = try await cell.set(keypath: key, value: .string("forged"), requester: owner)
                    XCTFail("Read-only state accepted SET at \(key)")
                } catch {
                    // Expected: no state SET intercept is published.
                }
            }
            do {
                _ = try await cell.get(keypath: "ai", requester: owner)
                XCTFail("Undeclared root state must not expose private runtime data")
            } catch {
                // Expected: only exact read-only state keys are exposed.
            }

            do {
                _ = try await cell.set(
                    keypath: "ai.promptText",
                    value: .string("wrong-key mutation"),
                    requester: sameUUIDWrongKey
                )
                XCTFail("Same UUID with another signing key must not mutate state")
            } catch {
                // Expected authorization denial.
            }
            let promptAfterWrongKey = try await cell.get(
                keypath: "ai.promptText",
                requester: owner
            )
            XCTAssertEqual(promptAfterWrongKey, .string("Hva vil du hjelpe deg med i dag?"))

            await cell.storeLastToolArguments(
                .object(["query": .string("outsider")]),
                requester: outsider
            )
            let outsiderToolArguments = try await cell.get(
                keypath: "ai.lastToolArguments",
                requester: owner
            )
            guard case let .object(outsiderArgumentsObject) = outsiderToolArguments else {
                XCTFail("Expected tool arguments object")
                return
            }
            XCTAssertTrue(outsiderArgumentsObject.isEmpty)
            await cell.storeLastToolArguments(
                .object(["query": .string("owner")]),
                requester: owner
            )
            let ownerToolArguments = try await cell.get(
                keypath: "ai.lastToolArguments",
                requester: owner
            )
            guard case let .object(ownerArgumentsObject) = ownerToolArguments else {
                XCTFail("Expected owner tool arguments object")
                return
            }
            XCTAssertEqual(ownerArgumentsObject["query"], .string("owner"))

            let decoded = try JSONDecoder().decode(
                AppleIntelligenceCell.self,
                from: JSONEncoder().encode(cell)
            )
            try await assertStateAndOutboxContainKnownCandidate(on: decoded, requester: owner)
            let restoredToolArguments = try await decoded.get(
                keypath: "ai.lastToolArguments",
                requester: owner
            )
            guard case let .object(restoredArgumentsObject) = restoredToolArguments else {
                XCTFail("Expected restored tool arguments object")
                return
            }
            XCTAssertTrue(
                restoredArgumentsObject.isEmpty,
                "Tool diagnostics are deliberately transient"
            )

            let dequeued = await decoded.dequeueOutboxMessage(requester: owner)
            let emptiedOutbox = try await decoded.get(keypath: "ai.outbox", requester: owner)
            XCTAssertNotNil(dequeued)
            guard case let .list(remainingOutbox) = emptiedOutbox else {
                XCTFail("Expected outbox list")
                return
            }
            XCTAssertTrue(remainingOutbox.isEmpty)
        } else {
            throw XCTSkip("AppleIntelligenceCell state requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testPartialPersistedRuntimeStateUsesSafeDefaultsAndClearsInProgressStatus() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            let encoded = try JSONEncoder().encode(cell)
            var persistedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            persistedObject["runtimeState"] = ["status": AIStatus.discovering.rawValue]
            let partialData = try JSONSerialization.data(withJSONObject: persistedObject)
            let restored = try JSONDecoder().decode(
                AppleIntelligenceCell.self,
                from: partialData
            )

            let status = try await restored.get(keypath: "ai.status", requester: owner)
            let prompt = try await restored.get(keypath: "ai.promptText", requester: owner)
            let sendFlowOnIngest = try await restored.get(
                keypath: "ai.sendFlowOnIngest",
                requester: owner
            )
            let candidates = try await restored.get(
                keypath: "ai.candidates",
                requester: owner
            )
            let outbox = try await restored.get(keypath: "ai.outbox", requester: owner)

            XCTAssertEqual(status, .string(AIStatus.idle.rawValue))
            XCTAssertEqual(prompt, .string("Hva vil du hjelpe deg med i dag?"))
            XCTAssertEqual(sendFlowOnIngest, .bool(true))
            guard case let .list(candidateList) = candidates,
                  case let .list(outboxList) = outbox else {
                return XCTFail("Expected empty candidate and outbox lists")
            }
            XCTAssertTrue(candidateList.isEmpty)
            XCTAssertTrue(outboxList.isEmpty)
        } else {
            throw XCTSkip("AppleIntelligenceCell partial restore requires macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testStrictExploreModeInstallsAppleIntelligenceHandlersBeforeImmediateUse() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let previousMode = CellBase.exploreContractEnforcementMode
            CellBase.exploreContractEnforcementMode = .strict
            defer { CellBase.exploreContractEnforcementMode = previousMode }

            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            let keys = try await cell.keys(requester: owner)
            XCTAssertTrue(keys.contains("ai.state"))
            XCTAssertTrue(keys.contains("ai.candidates"))
            XCTAssertTrue(keys.contains("ai.ingestConfigurations"))
            let status = try await cell.get(keypath: "ai.status", requester: owner)
            let promptUpdate = try await cell.set(
                keypath: "ai.promptText",
                value: .string("Strict runtime prompt"),
                requester: owner
            )
            let promptRead = try await cell.get(
                keypath: "ai.promptText",
                requester: owner
            )
            XCTAssertEqual(status, .string(AIStatus.idle.rawValue))
            XCTAssertEqual(promptUpdate, .string("New prompt text: Strict runtime prompt"))
            XCTAssertEqual(promptRead, .string("Strict runtime prompt"))
        } else {
            throw XCTSkip("AppleIntelligenceCell strict contracts require macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    func testStrictExploreModePublishesEveryAppleIntelligenceOperationContract() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let previousMode = CellBase.exploreContractEnforcementMode
            CellBase.exploreContractEnforcementMode = .strict
            defer { CellBase.exploreContractEnforcementMode = previousMode }

            let vault = MockIdentityVault()
            CellBase.defaultIdentityVault = vault
            let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
            let cell = await AppleIntelligenceCell(owner: owner)

            let expectedOperations = Set([
                "get:ai.status",
                "get:ai.currentPurposeRef",
                "get:ai.purposeClusterRefs",
                "get:ai.candidates",
                "get:ai.rankWeights",
                "get:ai.outbox",
                "get:ai.lastToolArguments",
                "get:ai.state",
                "set:ai.dequeueOutbox",
                "set:ai.discover",
                "set:ai.rank",
                "set:ai.ensurePurpose",
                "set:ai.buildCluster",
                "get:ai.promptText",
                "set:ai.promptText",
                "get:ai.promptInstructions",
                "set:ai.promptInstructions",
                "get:ai.sendFlowOnIngest",
                "set:ai.sendFlowOnIngest",
                "get:ai.rankEnabled",
                "set:ai.rankEnabled",
                "set:ai.ingestConfigurations",
                "set:ai.send",
                "set:ai.sendPrompt"
            ])
            let contracts = try await cell.operationContracts(requester: owner)
            let actualOperations = Set(contracts.compactMap { contract -> String? in
                guard let object = ExploreContract.object(from: contract),
                      let key = ExploreContract.string(from: object[ExploreContract.Field.key]),
                      let method = ExploreContract.string(from: object[ExploreContract.Field.method]) else {
                    return nil
                }
                XCTAssertNotNil(object[ExploreContract.Field.input], "Missing input schema for \(method):\(key)")
                XCTAssertNotNil(object[ExploreContract.Field.returns], "Missing return schema for \(method):\(key)")
                XCTAssertNotEqual(
                    ExploreContract.schemaType(from: object[ExploreContract.Field.input]),
                    "unknown",
                    "Unknown input schema for \(method):\(key)"
                )
                XCTAssertNotEqual(
                    ExploreContract.schemaType(from: object[ExploreContract.Field.returns]),
                    "unknown",
                    "Unknown return schema for \(method):\(key)"
                )
                return "\(method):\(key)"
            })

            XCTAssertEqual(contracts.count, expectedOperations.count)
            XCTAssertEqual(actualOperations, expectedOperations)
            let installedKeys = Set(try await cell.keys(requester: owner))
            let expectedKeys = Set(expectedOperations.compactMap { operation in
                operation.split(separator: ":", maxSplits: 1).last.map(String.init)
            })
            XCTAssertTrue(expectedKeys.isSubset(of: installedKeys))
        } else {
            throw XCTSkip("AppleIntelligenceCell operation contracts require macOS 26/iOS 26 runtime availability")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this toolchain")
        #endif
    }

    private func contentType(in message: ValueType) -> String? {
        guard case let .object(object) = message,
              case let .object(properties)? = object["properties"],
              case let .string(contentType)? = properties["contentType"] else {
            return nil
        }
        return contentType
    }

    private func flowElementWireRoundTrip(_ message: ValueType) throws -> FlowElement {
        let firstDecode = try JSONDecoder().decode(
            FlowElement.self,
            from: JSONEncoder().encode(message)
        )
        return try JSONDecoder().decode(
            FlowElement.self,
            from: JSONEncoder().encode(firstDecode)
        )
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func assertStateAndOutboxContainKnownCandidate(
        on cell: AppleIntelligenceCell,
        requester: Identity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stateValue = try await cell.get(keypath: "ai.state", requester: requester)
        guard case let .object(state) = stateValue,
              case let .list(candidates)? = state[AIKeys.candidates] else {
            XCTFail("Missing candidates in ai.state", file: file, line: line)
            return
        }
        let names = candidates.compactMap { value -> String? in
            guard case let .cellConfiguration(configuration) = value else { return nil }
            return configuration.name
        }
        XCTAssertEqual(names, ["Known runtime candidate"], file: file, line: line)

        guard case let .list(outbox) = try await cell.get(
            keypath: "ai.outbox",
            requester: requester
        ) else {
            XCTFail("Missing ai.outbox", file: file, line: line)
            return
        }
        XCTAssertEqual(outbox.count, 1, file: file, line: line)
    }
}
