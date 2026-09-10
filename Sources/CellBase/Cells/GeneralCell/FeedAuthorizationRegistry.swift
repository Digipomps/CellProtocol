// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

private struct AuthorizedFeedElement {
    let element: FlowElement
    let ticket: FlowDeliveryFlight.Ticket?
}

private struct AuthorizedFeedDeliveryPublisher: Publisher {
    typealias Output = FlowElement
    typealias Failure = Error
    let upstream: AnyPublisher<AuthorizedFeedElement, Error>

    func receive<S: Subscriber>(subscriber: S) where S.Input == FlowElement, S.Failure == Error {
        upstream.receive(subscriber: Forwarder(downstream: subscriber))
    }

    private struct Forwarder<Downstream: Subscriber>: Subscriber where Downstream.Input == FlowElement, Downstream.Failure == Error {
        typealias Input = AuthorizedFeedElement
        typealias Failure = Error
        let combineIdentifier = CombineIdentifier()
        let downstream: Downstream
        func receive(subscription: Subscription) { downstream.receive(subscription: subscription) }
        func receive(_ input: Input) -> Subscribers.Demand {
            defer { input.ticket?.finish() }
            guard input.ticket?.shouldDeliver() ?? true else { return .max(1) }
            return downstream.receive(input.element)
        }
        func receive(completion: Subscribers.Completion<Error>) { downstream.receive(completion: completion) }
    }
}

/// Each subscription owns its revocation signal and an ordered, bounded queue.
/// A publisher obtained earlier is not a durable access grant.
final class FeedAuthorizationRegistry {
    private final class Lease {
        let id = UUID()
        let subjectUUID: String
        let authorize: () async -> Bool
        let failure = CurrentValueSubject<Error?, Never>(nil)

        init(subjectUUID: String, authorize: @escaping () async -> Bool) {
            self.subjectUUID = subjectUUID
            self.authorize = authorize
        }
    }

    private final class CheckTask {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func install(_ task: Task<Void, Never>) {
            let cancel = lock.withLock { () -> Bool in
                if cancelled { return true }
                self.task = task
                return false
            }
            if cancel { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock { () -> Task<Void, Never>? in
                cancelled = true
                defer { self.task = nil }
                return self.task
            }
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var leases: [UUID: Lease] = [:]

    func publisher(
        upstream: AnyPublisher<FlowElement, Error>,
        subjectUUID: String,
        authorize: @escaping () async -> Bool
    ) -> AnyPublisher<FlowElement, Error> {
        Deferred { [weak self] () -> AnyPublisher<FlowElement, Error> in
            guard let self else { return Fail(error: StreamState.denied).eraseToAnyPublisher() }
            let lease = Lease(subjectUUID: subjectUUID, authorize: authorize)
            self.lock.withLock { self.leases[lease.id] = lease }
            let denied = lease.failure.tryCompactMap { error -> AuthorizedFeedElement? in
                if let error { throw error }
                return nil
            }
            let checked = upstream
                .map { AuthorizedFeedElement(element: $0, ticket: FlowDeliveryFlight.current?.reserve()) }
                // byRequest requests unlimited upstream in Combine/OpenCombine,
                // so bursts hit this explicit bound instead of dropping at source.
                .buffer(size: 256, prefetch: .byRequest, whenFull: .customError {
                    // Buffer may defer its failure until demand resumes. Signal
                    // independently, outside Buffer's lock, to cancel a stalled check.
                    Task { lease.failure.send(GeneralCellErrors.flowBufferOverflow) }
                    return GeneralCellErrors.flowBufferOverflow
                })
                .flatMap(maxPublishers: .max(1)) { element -> AnyPublisher<AuthorizedFeedElement, Error> in
                    Deferred {
                        let check = CheckTask()
                        return Future<AuthorizedFeedElement, Error> { promise in
                            FlowDeliveryFlight.$current.withValue(nil) {
                                check.install(Task {
                                    let allowed = await lease.authorize()
                                    guard !Task.isCancelled else { return }
                                    if allowed && lease.failure.value == nil { promise(.success(element)) }
                                    else { promise(.failure(StreamState.denied)) }
                                })
                            }
                        }
                        .handleEvents(receiveCancel: { check.cancel() })
                    }.eraseToAnyPublisher()
                }
                .handleEvents(receiveCompletion: { _ in lease.failure.send(completion: .finished) })
                .eraseToAnyPublisher()
            // OpenCombine 0.14 has no Merge publisher. Two bounded inner
            // subscriptions provide the same value/failure fan-in on both hosts.
            let authorized = [checked, denied.eraseToAnyPublisher()].publisher
                .setFailureType(to: Error.self)
                .flatMap(maxPublishers: .max(2)) { $0 }
                .handleEvents(
                    receiveCompletion: { [weak self] _ in self?.remove(lease.id) },
                    receiveCancel: { [weak self] in self?.remove(lease.id) }
                )
                .eraseToAnyPublisher()
            return AuthorizedFeedDeliveryPublisher(upstream: authorized).eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }

    /// Complete before removeMember returns. Public/owner access that remains
    /// valid is preserved; only subscriptions that lost authority are denied.
    func revalidate(subjectUUID: String) async {
        let matching = lock.withLock { leases.values.filter { $0.subjectUUID == subjectUUID } }
        for lease in matching where !(await lease.authorize()) {
            lease.failure.send(StreamState.denied)
        }
    }

    private func remove(_ id: UUID) { lock.withLock { _ = leases.removeValue(forKey: id) } }
}
