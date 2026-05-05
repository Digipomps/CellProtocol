// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@testable import CellBase

final class TestEmitCell: Emit, Meddle {
    let uuid: String
    let owner: Identity
    var agreementTemplate: Agreement
    var identityDomain: String
    var cellScope: CellUsageScope
    var persistancy: Persistancy
    var admittedState: ConnectState
    var addAgreementState: AgreementState

    private let feedSubject = PassthroughSubject<FlowElement, Error>()
    private var store: [String: ValueType] = [:]

    init(
        owner: Identity,
        uuid: String = TestFixtures.fixedUUID1.uuidString,
        identityDomain: String = "private",
        admittedState: ConnectState = .connected,
        addAgreementState: AgreementState = .signed
    ) {
        self.uuid = uuid
        self.owner = owner
        self.identityDomain = identityDomain
        self.agreementTemplate = Agreement(owner: owner)
        self.cellScope = .template
        self.persistancy = .ephemeral
        self.admittedState = admittedState
        self.addAgreementState = addAgreementState
    }

    func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        return feedSubject.eraseToAnyPublisher()
    }

    func admit(context: ConnectContext) async -> ConnectState {
        return admittedState
    }

    func close(requester: Identity) {
        // no-op
    }

    func addAgreement(_ contract: Agreement, for identity: Identity) async throws -> AgreementState {
        return addAgreementState
    }

    func advertise(for requester: Identity) async -> AnyCell {
        return AnyCell(
            uuid: uuid,
            name: "TestEmitCell",
            contractTemplate: agreementTemplate,
            owner: owner,
            identityDomain: identityDomain
        )
    }

    func state(requester: Identity) async throws -> ValueType {
        return store["state"] ?? .null
    }

    func getOwner(requester: Identity) async throws -> Identity {
        return owner
    }

    func getEmitterWithUUID(_ uuid: String, requester: Identity) async -> Emit? {
        return uuid == self.uuid ? self : nil
    }

    func get(keypath: String, requester: Identity) async throws -> ValueType {
        return store[keypath] ?? .null
    }

    func set(keypath: String, value: ValueType, requester: Identity) async throws -> ValueType? {
        store[keypath] = value
        return value
    }
}
