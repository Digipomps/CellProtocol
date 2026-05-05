// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import HavenCoreSchemas
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class AdmissionAndCatalogContractModelsTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }

    func testAdmissionChallengePayloadDecodesCurrentConnectChallengeEvent() async throws {
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
        let challengeExpectation = expectation(description: "connect.challenge decoded")

        var decodedPayload: AdmissionChallengePayload?
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge" else { return }
            let encodedValue = try? flowElement.content.valueType()
            if let encodedValue, let payload: AdmissionChallengePayload = try? self.decode(encodedValue) {
                decodedPayload = payload
                challengeExpectation.fulfill()
            }
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "challenge-decode", requester: requester)
        XCTAssertEqual(state, .signContract)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()

        let payload = try XCTUnwrap(decodedPayload)
        XCTAssertEqual(payload.state, .unmet)
        XCTAssertEqual(payload.connectState, .signContract)
        XCTAssertEqual(payload.issueCount, 1)
        XCTAssertEqual(payload.primaryIssue?.requiredAction, "review_agreement")
        XCTAssertEqual(payload.session?.requesterUUID, requester.uuid)
        XCTAssertEqual(payload.helperCellConfiguration?.discovery?.sourceCellEndpoint, "cell:///AgreementWorkbench")
    }

    func testDeniedAdmissionChallengePayloadDecodesCurrentConnectChallengeEvent() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let requester = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let emitterOwner = await vault.identity(for: "other", makeNewIfNotFound: true)!

        let absorbCell = await GeneralCell(owner: requester)
        let emitCell = TestEmitCell(owner: emitterOwner, admittedState: .denied)

        let feed = try await absorbCell.flow(requester: requester)
        let challengeExpectation = expectation(description: "connect.challenge denied decoded")

        var decodedPayload: AdmissionChallengePayload?
        let cancellable = feed.sink(receiveCompletion: { _ in }, receiveValue: { flowElement in
            guard flowElement.topic == "connect.challenge" else { return }
            let encodedValue = try? flowElement.content.valueType()
            if let encodedValue, let payload: AdmissionChallengePayload = try? self.decode(encodedValue) {
                decodedPayload = payload
                challengeExpectation.fulfill()
            }
        })

        let state = try await absorbCell.attach(emitter: emitCell, label: "challenge-denied-decode", requester: requester)
        XCTAssertEqual(state, .denied)

        await fulfillment(of: [challengeExpectation], timeout: 1.0)
        cancellable.cancel()

        let payload = try XCTUnwrap(decodedPayload)
        XCTAssertEqual(payload.state, .denied)
        XCTAssertEqual(payload.connectState, .denied)
        XCTAssertEqual(payload.issueCount, 1)
        XCTAssertEqual(payload.reasonCode, "connect_denied")
        XCTAssertEqual(payload.requiredAction, "request_access")
        XCTAssertEqual(payload.primaryIssue?.reasonCode, "connect_denied")
    }

    func testConfigurationCatalogEntryContractNormalizesMetadata() {
        let entry = ConfigurationCatalogEntryContract(
            id: "entry-1",
            sourceCellEndpoint: "cell:///Catalog",
            sourceCellName: "Catalog",
            purpose: "Discover",
            interests: [" chat ", "catalog", "chat"],
            menuSlots: ["upperMid", "upperMid", " lowerLeft "],
            tags: ["beta", "beta", " discovery "],
            purposeRefs: ["purpose.discovery", "purpose.discovery", "purpose.chat"],
            supportedInsertionModes: [.both, .component, .both],
            supportedTargetKinds: ["page", "page", "panel"],
            policyHints: ["local-first", " local-first ", "portable"],
            recommendedContexts: ["desktop", "desktop", "mobile"]
        )

        XCTAssertEqual(entry.interests, ["catalog", "chat"])
        XCTAssertEqual(entry.menuSlots, ["lowerLeft", "upperMid"])
        XCTAssertEqual(entry.tags, ["beta", "discovery"])
        XCTAssertEqual(entry.purposeRefs, ["purpose.chat", "purpose.discovery"])
        XCTAssertEqual(entry.supportedInsertionModes, [.both, .component])
        XCTAssertEqual(entry.supportedTargetKinds, ["page", "panel"])
        XCTAssertEqual(entry.policyHints, ["local-first", "portable"])
        XCTAssertEqual(entry.recommendedContexts, ["desktop", "mobile"])
    }

    func testConfigurationCatalogQueryRequestNormalizesInputs() {
        let request = ConfigurationCatalogQueryRequest(
            text: "  conference  ",
            locale: " nb-NO ",
            includeLocalizedLabels: true,
            purposeRefs: ["purpose.discovery", "purpose.discovery"],
            sourceCellNames: [" Catalog ", "Catalog"],
            supportedInsertionModes: [.root, .root, .both],
            limit: 0,
            offset: -10
        )

        XCTAssertEqual(request.text, "conference")
        XCTAssertEqual(request.locale, "nb-NO")
        XCTAssertTrue(request.includeLocalizedLabels)
        XCTAssertEqual(request.purposeRefs, ["purpose.discovery"])
        XCTAssertEqual(request.sourceCellNames, ["Catalog"])
        XCTAssertEqual(request.supportedInsertionModes, [.both, .root])
        XCTAssertEqual(request.limit, 1)
        XCTAssertEqual(request.offset, 0)
    }

    func testConfigurationCatalogQueryRequestDecodesLocalizationDefaults() throws {
        let decoded = try JSONDecoder().decode(ConfigurationCatalogQueryRequest.self, from: Data("{}".utf8))

        XCTAssertNil(decoded.locale)
        XCTAssertFalse(decoded.includeLocalizedLabels)
        XCTAssertEqual(decoded.limit, 20)
        XCTAssertEqual(decoded.offset, 0)
        XCTAssertTrue(decoded.purposeRefs.isEmpty)
    }

    func testConfigurationCatalogContractsRoundTripThroughValueType() throws {
        let entry = ConfigurationCatalogEntryContract(
            id: "entry-2",
            sourceCellEndpoint: "cell:///Example",
            sourceCellName: "ExampleCell",
            purpose: "Example",
            interests: ["catalog"],
            ioSignature: ConfigurationCatalogIOSignature(
                getKeys: ["state"],
                setKeys: ["refresh"],
                topics: ["catalog.updated"],
                filterTypes: ["purpose"]
            ),
            authRequired: true,
            flowDriven: true,
            editable: true,
            localizedDisplay: ConfigurationCatalogLocalizedDisplay(
                locale: "nb-NO",
                displayName: "Eksempel",
                summary: "Lokalisert eksempel",
                purposeLabels: [
                    ResolvedLocalizedTerm(
                        termID: "purpose.learn",
                        namespace: "haven.core",
                        kind: .purpose,
                        label: "Laere",
                        requestedLocale: "nb-NO",
                        resolvedLocale: "nb-NO"
                    )
                ],
                interestLabels: [
                    ResolvedLocalizedTerm(
                        termID: "interest.ai",
                        namespace: "haven.core",
                        kind: .interest,
                        label: "Kunstig intelligens",
                        requestedLocale: "nb-NO",
                        resolvedLocale: "nb-NO"
                    )
                ]
            )
        )
        let match = ConfigurationCatalogQueryMatch(
            entryID: entry.id,
            score: 0.91,
            reasons: ["purpose_match", "interest_match"],
            scoreBreakdown: ["purpose": 0.6, "interest": 0.31],
            entry: entry
        )
        let response = ConfigurationCatalogQueryResponse(items: [match], total: 1, offset: 0, limit: 20)

        let encoded = try encode(response)
        let decoded: ConfigurationCatalogQueryResponse = try decode(encoded)
        XCTAssertEqual(decoded.total, 1)
        XCTAssertEqual(decoded.items.first?.entryID, "entry-2")
        XCTAssertEqual(decoded.items.first?.entry.ioSignature?.getKeys, ["state"])
        XCTAssertEqual(decoded.items.first?.entry.localizedDisplay?.locale, "nb-NO")
        XCTAssertEqual(decoded.items.first?.entry.localizedDisplay?.interestLabels.first?.termID, "interest.ai")
    }

    func testAdmissionRetryRequestRoundTripsThroughValueType() throws {
        let request = AdmissionRetryRequest(
            sessionId: "session-123",
            requesterUUID: "requester-456",
            note: "retry after helper completion"
        )

        let encoded = try encode(request)
        let decoded: AdmissionRetryRequest = try decode(encoded)
        XCTAssertEqual(decoded.sessionId, "session-123")
        XCTAssertEqual(decoded.requesterUUID, "requester-456")
        XCTAssertEqual(decoded.note, "retry after helper completion")
    }

    private func decode<T: Decodable>(_ value: ValueType, as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> ValueType {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }
}
