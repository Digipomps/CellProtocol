// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CorrespondenceAgreementTemplates {
    public static let externalGrantSpecifications: [(keypath: String, permission: String)] = [
        ("inbox", "r---"),
        ("readMessage", "-w--"),
        ("sendMessage", "-w--"),
        ("ackMessage", "-w--")
    ]

    public static let attachmentGrantSpecifications: [(keypath: String, permission: String)] = [
        ("attachments.probe", "-w--"), ("attachments.prepare", "-w--"),
        ("attachments.upload", "-w--"), ("attachments.metadata", "-w--"),
        ("attachments.fetch", "-w--"), ("attachments.receipt", "-w--"),
        ("attachments.revoke", "-w--"), ("attachments.transfer", "-w--"),
        ("attachments.acceptTransfer", "-w--"), ("attachments.status", "-w--")
    ]

    /// Explicitly opt in by signing this Agreement; existing v0 contracts gain no rights.
    public static func withAttachments(owner: Identity) -> Agreement {
        make(name: "Correspondence with attachments v1", owner: owner,
             grants: externalGrantSpecifications + attachmentGrantSpecifications)
    }

    public static let ownerGrantSpecifications: [(keypath: String, permission: String)] = [
        ("audience.inviteIdentities", "-w--"),
        ("audience.generateInvitationArtifacts", "-w--"),
        ("audience.acceptInvitationArtifact", "-w--"),
        ("audience.revokeInvites", "-w--"),
        ("crypto.requestRekey", "-w--"),
        ("lifecycle.retentionPolicy", "-w--"),
        ("lifecycle.close", "-w--")
    ]

    public static let neverGrantedKeypaths: [String] = [
        "chat",
        "audience.*",
        "members",
        "participants",
        "crypto.policy",
        "crypto.persistenceMode",
        "crypto.requestRekey",
        "audience.inviteIdentities",
        "audience.generateInvitationArtifacts",
        "audience.acceptInvitationArtifact",
        "start",
        "stop",
        "lifecycle.*"
    ]

    public static func external(owner: Identity) -> Agreement {
        make(
            name: "Correspondence external surface v0",
            owner: owner,
            grants: externalGrantSpecifications
        )
    }

    public static func owner(owner: Identity) -> Agreement {
        make(
            name: "Correspondence owner v0",
            owner: owner,
            grants: ownerGrantSpecifications
        )
    }

    private static func make(
        name: String,
        owner: Identity,
        grants: [(keypath: String, permission: String)]
    ) -> Agreement {
        let agreement = Agreement(owner: owner)
        agreement.name = name
        agreement.grants = []
        agreement.conditions = []
        agreement.signatories = [owner]
        agreement.duration = 60 * 60 * 24 * 365
        for grant in grants {
            agreement.addGrant(grant.permission, for: grant.keypath)
        }
        return agreement
    }
}
