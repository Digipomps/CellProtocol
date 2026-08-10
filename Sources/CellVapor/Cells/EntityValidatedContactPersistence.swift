// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@preconcurrency import CellBase
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public enum EntityValidatedContactPersistenceError: Error, LocalizedError {
    case timedOut(String)
    case failed(String)
    case invalidAcknowledgement(String)
    case readAfterReloadMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let correlationID):
            return "Validated contact persistence timed out (\(correlationID))."
        case .failed(let detail):
            return "Validated contact persistence failed: \(detail)"
        case .invalidAcknowledgement(let correlationID):
            return "Validated contact persistence returned an invalid acknowledgement (\(correlationID))."
        case .readAfterReloadMismatch(let keypath):
            return "Validated contact persistence did not survive reload at \(keypath)."
        }
    }
}

/// Reusable CellProtocol/Flow operation for one owner-private validated contact.
/// The operation fixes disclosure to false and proves local-authority durability
/// by signed receipt, immediate readback, storage reload and a second readback.
public enum EntityValidatedContactPersistence {
    public static func persist(
        entityAnchor: EntityAnchorCell,
        identity: Identity,
        relationID: String,
        record: ValueType,
        sourceUUID: String
    ) async throws -> EntityAuthorityCommitReceipt {
        let authorityValue = try await entityAnchor.get(
            keypath: "entityAuthority",
            requester: identity
        )
        let authorityState = try EntityAuthorityCommitState(value: authorityValue)
        let keypath = EntityValidatedContactRecordV1.keypath(relationID: relationID)
        var envelope = EntityBatchPersistEnvelope(
            schema: EntityValidatedContactRecordV1.envelopeSchema,
            mutations: [EntityBatchPersistMutation(keypath: keypath, value: record)],
            metadata: [
                "dataAction": .string("entity-storage"),
                "disclosureAuthorized": .bool(false),
                "relationID": .string(relationID)
            ]
        )
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: "validated-contact-\(UUID().uuidString)",
            partitionID: authorityState.partitionID,
            epoch: authorityState.epoch,
            expectedRevision: authorityState.revision,
            expectedPreviousHash: authorityState.headHash,
            requester: identity,
            purposeRef: EntityValidatedContactRecordV1.storagePurposeRef
        )
        try EntityValidatedContactRecordV1.validatePersistenceEnvelope(envelope)

        let acknowledgementPublisher = try await entityAnchor.flow(requester: identity)
        let pusher = FlowElementPusherCell(owner: identity)
        let correlationID = "validated-contact-persist-\(UUID().uuidString)"
        let label = "push-\(correlationID)"
        let connectState = try await entityAnchor.attach(
            emitter: pusher,
            label: label,
            requester: identity
        )
        guard connectState == .connected else {
            throw FlowError.denied
        }
        defer {
            entityAnchor.detach(label: label, requester: identity)
        }

        try await entityAnchor.absorbFlow(label: label, requester: identity)
        let receipt = try await awaitAuthorityCommitAcknowledgement(
            correlationID: correlationID,
            publisher: acknowledgementPublisher
        ) {
            var flowElement = FlowElement(
                title: "Validated contact Entity persistence",
                content: .object([
                    "correlationId": .string(correlationID),
                    "operation": .string(EntityBatchPersistEnvelope.operation),
                    "envelope": .object(envelope.objectValue())
                ]),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = "entity"
            flowElement.origin = sourceUUID
            pusher.pushFlowElement(flowElement, requester: identity)
            pusher.pushCompletion(error: nil, requester: identity)
        }

        for _ in 0..<20 {
            if let persisted = try? await entityAnchor.get(keypath: keypath, requester: identity),
               ExploreContractValidator.deepEqual(persisted, record) {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let persisted = try? await entityAnchor.get(keypath: keypath, requester: identity),
              ExploreContractValidator.deepEqual(persisted, record) else {
            throw EntityValidatedContactPersistenceError.readAfterReloadMismatch(keypath)
        }

        _ = try await entityAnchor.get(keypath: "reloadStorage", requester: identity)
        guard let reloaded = try? await entityAnchor.get(keypath: keypath, requester: identity),
              ExploreContractValidator.deepEqual(reloaded, record) else {
            throw EntityValidatedContactPersistenceError.readAfterReloadMismatch(keypath)
        }
        return receipt
    }

    private static func awaitAuthorityCommitAcknowledgement(
        correlationID: String,
        publisher: AnyPublisher<FlowElement, Error>,
        send: @escaping () -> Void
    ) async throws -> EntityAuthorityCommitReceipt {
        let lock = NSLock()
        var didResume = false
        var cancellable: AnyCancellable?
        defer { cancellable?.cancel() }

        return try await withThrowingTaskGroup(of: EntityAuthorityCommitReceipt.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<EntityAuthorityCommitReceipt, Error>) in
                    func resumeOnce(_ result: Result<EntityAuthorityCommitReceipt, Error>) {
                        lock.lock()
                        defer { lock.unlock() }
                        guard didResume == false else { return }
                        didResume = true
                        continuation.resume(with: result)
                    }

                    cancellable = publisher.sink(
                        receiveCompletion: { completion in
                            if case let .failure(error) = completion {
                                resumeOnce(.failure(error))
                            }
                        },
                        receiveValue: { flowElement in
                            guard case let .object(payload) = flowElement.content,
                                  case let .string(receivedCorrelationID)? = payload["correlationId"],
                                  receivedCorrelationID == correlationID else {
                                return
                            }
                            guard case let .string(status)? = payload["status"] else {
                                resumeOnce(.failure(
                                    EntityValidatedContactPersistenceError.invalidAcknowledgement(
                                        correlationID
                                    )
                                ))
                                return
                            }
                            if status == "authority_committed",
                               let receiptValue = payload["commitReceipt"] {
                                do {
                                    resumeOnce(.success(
                                        try EntityAuthorityCommitReceipt(value: receiptValue)
                                    ))
                                } catch {
                                    resumeOnce(.failure(error))
                                }
                                return
                            }
                            let message: String
                            if case let .string(description)? = payload["error"] {
                                message = description
                            } else {
                                message = "Entity authority commit returned \(status)."
                            }
                            resumeOnce(.failure(
                                EntityValidatedContactPersistenceError.failed(message)
                            ))
                        }
                    )
                    send()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw EntityValidatedContactPersistenceError.timedOut(correlationID)
            }

            guard let receipt = try await group.next() else {
                throw EntityValidatedContactPersistenceError.invalidAcknowledgement(correlationID)
            }
            group.cancelAll()
            return receipt
        }
    }
}
