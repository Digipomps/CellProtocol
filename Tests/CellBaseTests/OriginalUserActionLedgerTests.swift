// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import CellBase
@testable import CellApple

final class OriginalUserActionLedgerTests: XCTestCase {
    private func canonical(_ value: ValueType) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func testRetryRetainsFrozenIdentityPayloadAndOccurrenceTime() throws {
        var ledger = OriginalUserActionLedger()
        let first = try XCTUnwrap(ledger.prepare(keypath: "chatHub.prompt.submit", scope: "owner|endpoint", payload: .string("synthetic choice"), newID: "original", occurredAt: 100))
        let retry = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner|endpoint", payload: .string("synthetic choice"), newID: "must-not-replace", occurredAt: 200))
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(try canonical(first.payload), try canonical(retry.payload))
    }
    func testButtonDraftAndTextareaStringShareOnePendingOriginalSubmission() throws {
        var ledger = OriginalUserActionLedger()
        let button = try XCTUnwrap(ledger.prepare(keypath: "chatHub.prompt.submit", scope: "owner|endpoint", payload: .object(["draft":.string("same intent")]), newID: "button"))
        let enter = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner|endpoint", payload: .string("same intent"), newID: "enter"))
        XCTAssertEqual(button.id, enter.id)
        XCTAssertEqual(try canonical(button.payload), try canonical(enter.payload))
    }
    func testSameTextAfterCompletionIsNewLegitimateSubmission() throws {
        var ledger = OriginalUserActionLedger()
        let first = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .string("same"), newID: "one"))
        ledger.complete(first)
        let second = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .string("same"), newID: "two"))
        XCTAssertNotEqual(first.id, second.id)
    }
    func testAnotherDraftDoesNotEraseRetryIdentityOfAnUncertainOlderCommand() throws {
        var ledger = OriginalUserActionLedger()
        let first = try XCTUnwrap(ledger.prepare(keypath:"prompt.submit",scope:"owner",payload:.string("first"),newID:"one"))
        _ = try ledger.prepare(keypath:"prompt.submit",scope:"owner",payload:.string("another"),newID:"two")
        let retry = try XCTUnwrap(ledger.prepare(keypath:"prompt.submit",scope:"owner",payload:.string("first"),newID:"three"))
        XCTAssertEqual(retry.id,first.id)
    }
    func testLateCompletionCannotClearNewerPendingCommand() throws {
        var ledger = OriginalUserActionLedger()
        let first = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .string("first"), newID: "one"))
        let second = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .string("second"), newID: "two"))
        ledger.complete(first)
        let retry = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .string("second"), newID: "three"))
        XCTAssertEqual(retry.id, second.id)
    }
    func testRequesterAndEndpointScopeSeparateIdenticalPayloads() throws {
        var ledger = OriginalUserActionLedger()
        let a = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "ownerA|endpoint1", payload: .string("same"), newID: "a"))
        let b = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "ownerB|endpoint1", payload: .string("same"), newID: "b"))
        let c = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "ownerA|endpoint2", payload: .string("same"), newID: "c"))
        XCTAssertEqual(Set([a.id,b.id,c.id]).count,3)
    }
    func testUnrelatedOperationsAndMissingPayloadAreNotDecorated() throws {
        var ledger = OriginalUserActionLedger()
        for operation in ["setComposer", "field.persist", "addConfiguration", "other.prompt.submit", "perspective.routing.feedback"] {
            XCTAssertNil(try ledger.prepare(keypath: operation, scope: "owner", payload: .string("value")))
        }
        XCTAssertNil(try ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: nil))
    }
    func testClarificationPreservesBindingAndCanonicalPayloadOrder() throws {
        var ledger = OriginalUserActionLedger()
        let value: Object = ["clarificationID":.string("question"),"optionID":.string("option"),"threadID":.string("thread")]
        let first = try XCTUnwrap(ledger.prepare(keypath: "assistant.answerClarification", scope: "owner", payload: .object(value), newID: "answer"))
        let retry = try XCTUnwrap(ledger.prepare(keypath: "cell:///Chat/assistant.answerClarification", scope: "owner", payload: .object(value), newID: "later"))
        XCTAssertEqual(try canonical(first.payload),try canonical(retry.payload))
        guard case let .object(object) = first.payload else { return XCTFail("object required") }
        XCTAssertEqual(object["clarificationID"],.string("question"))
        XCTAssertEqual(object["optionID"],.string("option"))
        XCTAssertEqual(object["threadID"],.string("thread"))
    }
    func testExplicitFrozenIdentityIsPreservedAndInvalidIdentityRejected() throws {
        var ledger = OriginalUserActionLedger()
        let submission = try XCTUnwrap(ledger.prepare(keypath: "prompt.submit", scope: "owner", payload: .object(["text":.string("choice"),"userActionID":.string("frozen"),"userActionOccurredAt":.float(100)]),newID:"wrong",occurredAt:200))
        XCTAssertEqual(submission.id,"frozen")
        XCTAssertThrowsError(try ledger.prepare(keypath:"prompt.submit",scope:"owner",payload:.object(["userActionID":.string("")])))
    }
    @MainActor
    func testNativeSendRetrySharesIdentityThroughRealMountedActionEntry() async throws {
        let previous = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previous }
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let ownerValue = await vault.identity(for: "private", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerValue)
        let model = PortholeViewModel()
        model.rememberRequesterIdentity(owner)
        var sent = [ValueType]()
        enum Transport: Error { case uncertain }
        let handler = SkeletonNativeActionHandler { request in
            sent.append(try XCTUnwrap(request.payload))
            if sent.count == 1 { throw Transport.uncertain }
            return .object(["status":.string("suggested")])
        }
        do {
            _ = try await skeletonNativeSend(keypath:"prompt.submit",payload:.string("native choice"),scope:nil,handler:handler,viewModel:model)
            XCTFail("transport control must fail")
        } catch Transport.uncertain { }
        _ = try await skeletonNativeSend(keypath:"chatHub.prompt.submit",payload:.string("native choice"),scope:nil,handler:handler,viewModel:model)
        XCTAssertEqual(sent.count,2)
        XCTAssertEqual(try canonical(sent[0]),try canonical(sent[1]))
        guard case let .object(object) = sent[0] else { return XCTFail("decorated object required") }
        XCTAssertNotNil(object["userActionID"])
    }
    @MainActor
    func testSuccessfulAnalysisWithUnknownLearningRetainsIdentityUntilKnownReceipt() async throws {
        let previous = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previous }
        let vault = MockIdentityVault(); CellBase.defaultIdentityVault = vault
        let identity = await vault.identity(for: "private", makeNewIfNotFound: true)
        let model = PortholeViewModel(); model.rememberRequesterIdentity(try XCTUnwrap(identity))
        var sent = [ValueType]()
        let handler = SkeletonNativeActionHandler { request in
            sent.append(try XCTUnwrap(request.payload))
            return .object(["result": .object(["status": .string("suggested"), "purposeVisitLearning": .object(
                sent.count == 1 ? ["outcome": .string("unknown"), "retrySameEventID": .bool(true)] : ["status": .string("duplicate")])])])
        }
        for _ in 0..<3 {
            _ = try await skeletonNativeSend(keypath:"prompt.submit", payload:.string("same choice"), scope:nil, handler:handler, viewModel:model)
        }
        XCTAssertEqual(try canonical(sent[0]), try canonical(sent[1]))
        XCTAssertNotEqual(try canonical(sent[1]), try canonical(sent[2]))
    }

}
