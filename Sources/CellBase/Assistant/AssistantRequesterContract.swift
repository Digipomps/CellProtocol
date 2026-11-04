// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Builds and admits the Agreement an assistant requester (a Siri tool intent
/// running in the host app, a Foundation Models session, Claude or Codex)
/// needs to reach a cell's exposed keys.
///
/// The requester is never the owner. It gets a signed Contract whose grants are
/// exactly the keys the cell opted in through `AssistantExposure`, nothing
/// wider: no owner-area grant, no feed, no keys the cell did not expose. The
/// cell's own agreement template must already list those grants (cells add
/// them when they opt a key in), so the request stays inside the template and
/// the ordinary admission path signs it.
public enum AssistantRequesterContract {
    public static let agreementName = "haven.assistant.requester.v1"

    /// A template-conformant Agreement request carrying only the surface's grants.
    /// Returns nil when the surface exposes nothing; an empty grant list is never admitted.
    public static func agreementRequest(
        for cell: GeneralCell,
        surface: AssistantSurfaceDescriptor,
        duration: Int? = nil
    ) -> Agreement? {
        guard !surface.grants.isEmpty else { return nil }
        let template = cell.agreementTemplate
        let request = Agreement(owner: cell.owner)
        request.name = agreementName
        request.conditions = template.conditions
        request.grants = surface.grants.map { requirement in
            Grant("assistant:\(requirement.keypath)", keypath: requirement.keypath, permission: requirement.permission)
        }
        request.authorizationPolicyBinding = template.authorizationPolicyBinding
        let requested = duration ?? template.duration
        request.duration = max(1, min(requested, template.duration))
        return request
    }

    /// Admits the assistant identity to the cell with the owner's authority.
    /// `.rejected` when the surface is empty, when the template does not cover
    /// a grant, or when the owner cannot prove authority.
    @discardableResult
    public static func admit(
        assistant: Identity,
        to cell: GeneralCell,
        surface: AssistantSurfaceDescriptor,
        authorizedBy owner: Identity,
        duration: Int? = nil
    ) async -> AgreementState {
        guard let request = agreementRequest(for: cell, surface: surface, duration: duration) else {
            return .rejected
        }
        return await cell.addAgreement(request, for: assistant, authorizedBy: owner)
    }
}

/// What the gateway did with a tool call or an entity read.
public enum AssistantGatewayOutcome: Equatable {
    /// The key is not exposed on this surface. Nothing reached the cell.
    case refused(reason: String)
    /// The payload does not match the tool's input schema. Nothing reached the cell.
    case invalidInput(ExploreValidationReport)
    /// The cell denied the requester.
    case denied
    /// The cell answered.
    case response(ValueType?)

    /// Structural comparison; `ValueType.==` cannot compare objects or lists.
    public static func == (lhs: AssistantGatewayOutcome, rhs: AssistantGatewayOutcome) -> Bool {
        switch (lhs, rhs) {
        case let (.refused(left), .refused(right)):
            return left == right
        case let (.invalidInput(left), .invalidInput(right)):
            return left == right
        case (.denied, .denied):
            return true
        case let (.response(left), .response(right)):
            return ExploreContractValidator.deepEqual(left, right)
        default:
            return false
        }
    }
}

/// The single entry point an assistant adapter calls. It enforces the opt-in
/// list before the cell sees the request (fail closed), validates tool payloads
/// against the contract, and hands the call to the cell with the assistant's
/// own requester identity so the Contract decides.
public struct AssistantGateway {
    public static let reasonNotExposedAsTool = "key_not_exposed_as_tool"
    public static let reasonNotExposedAsEntity = "key_not_exposed_as_entity"

    public let cell: any CellProtocol
    public let surface: AssistantSurfaceDescriptor

    public init(cell: any CellProtocol, surface: AssistantSurfaceDescriptor) {
        self.cell = cell
        self.surface = surface
    }

    public func invokeTool(key: String, payload: ValueType, requester: Identity) async throws -> AssistantGatewayOutcome {
        guard let tool = surface.tools.first(where: { $0.key == key && $0.method == ExploreContractMethod.set.rawValue }) else {
            return .refused(reason: Self.reasonNotExposedAsTool)
        }
        let report = ExploreContractValidator.validate(value: payload, against: tool.inputSchema)
        guard report.ok else {
            return .invalidInput(report)
        }
        do {
            return .response(try await cell.set(keypath: key, value: payload, requester: requester))
        } catch {
            if Self.isDenial(error) { return .denied }
            throw error
        }
    }

    public func readEntities(key: String, requester: Identity) async throws -> AssistantGatewayOutcome {
        guard let entity = surface.entities.first(where: { $0.key == key }) else {
            return .refused(reason: Self.reasonNotExposedAsEntity)
        }
        do {
            if entity.method == ExploreContractMethod.get.rawValue {
                return .response(try await cell.get(keypath: key, requester: requester))
            }
            return .response(try await cell.set(keypath: key, value: .null, requester: requester))
        } catch {
            if Self.isDenial(error) { return .denied }
            throw error
        }
    }

    static func isDenial(_ error: Error) -> Bool {
        if let authorization = error as? CellAuthorizationError, case .denied = authorization {
            return true
        }
        if let keyValue = error as? GeneralCell.KeyValueErrors, case .denied = keyValue {
            return true
        }
        return false
    }
}
