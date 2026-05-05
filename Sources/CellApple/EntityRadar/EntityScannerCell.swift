// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  EntityScannerCell.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 27/09/2024.
//

import CellBase
import Foundation
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/*
 The scope of EntityScannerCell is that it is one instance per app and one identity. For the advetised data there may be several identities
 */

private enum EntityScannerContactError: Error {
    case scannerNotStarted
    case missingRemoteUUID
    case notConnected(String)
    case invalidPayload(String)
    case signingFailed
    case storageUnavailable
}

private enum EntityScannerTopics {
    static let capabilities = "scanner.capabilities"
    static let found = "scanner.found"
    static let lost = "scanner.lost"
    static let status = "scanner.status"
    static let connected = "scanner.connected"
    static let proximity = "scanner.proximity"
    static let pendingContact = "scanner.contact.pending"
    static let outgoingContact = "scanner.contact.outgoing"
    static let incomingContact = "scanner.contact.received"
    static let establishedContact = "scanner.contact.established"
    static let savedEncounter = "scanner.encounter.saved"
    static let exportedEncounter = "scanner.encounter.exported"
    static let exportedEncounterJSON = "scanner.encounter.jsonExported"
    static let transportRequest = "scanner.transport.contact.request"
    static let transportAcceptance = "scanner.transport.contact.accept"
}

private enum EntityScannerContactProtocol {
    static let version = "entity-contact-v1"
    static let endpoint = "cell:///EntityScanner"
}

class EntityScannerCell: GeneralCell, ConnectServiceDelegate {
    var connectService: ScannerService?
    var requester: Identity?

    private var pendingOutgoingRequests = [String: Object]()
    private var pendingIncomingRequests = [String: Object]()

    required init(owner: Identity) async {
        await super.init(owner: owner)

        print("Entity Scanner Cell init. Owner: \(owner.uuid)")

        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    required init(from decoder: any Decoder) throws {
        fatalError("Entity Scanner Cell init(from:) has not been implemented")
    }

    private func setupPermissions(owner: Identity) async {
        self.agreementTemplate.addGrant("rw--", for: "start")
        self.agreementTemplate.addGrant("rw--", for: "stop")
        self.agreementTemplate.addGrant("rw--", for: "invite")
        self.agreementTemplate.addGrant("rw--", for: "requestContact")
        self.agreementTemplate.addGrant("rw--", for: "acceptContact")
        self.agreementTemplate.addGrant("rw--", for: "exportEncounter")
        self.agreementTemplate.addGrant("rw--", for: "exportEncounterJSON")
        self.agreementTemplate.addGrant("rw--", for: "sharedToken")
        self.agreementTemplate.addGrant("r---", for: "verificationMethods")
        self.agreementTemplate.addGrant("r---", for: "capabilities")
        self.agreementTemplate.addGrant("r---", for: "encounters")
    }

    private func setupKeys(owner: Identity) async {
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, requester in
            print("Incoming feedItem to Entity Scanner cell: \(flowElement.title) label: \(flowElement.topic) payload: \(String(describing: try? flowElement.content.valueType().jsonString()))")

            if flowElement.properties?.type == .event && flowElement.topic == "radar.service" {
                do {
                    try self?.gotSharedDicoveryToken(payload: flowElement.content)
                } catch {
                    print("Handling shared discovery token failed with error: \(error)")
                }
            }

            return flowElement
        })

        await addInterceptForGet(requester: owner, key: "verificationMethods", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "verificationMethods", for: requester) {
                return .string("notImplemented")
            }
            return .string("denied")
        })

        await addInterceptForGet(requester: owner, key: "capabilities", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "capabilities", for: requester) {
                return .object(self.currentCapabilityPayload())
            }
            return .string("denied")
        })

        await addInterceptForGet(requester: owner, key: "encounters", getValueIntercept: { [weak self] _, requester in
            guard let self = self else { return .list([]) }
            if await self.validateAccess("r---", at: "encounters", for: requester) {
                return await self.loadEncounterSummaries(requester: requester)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "start", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "start", for: requester) {
                self.requester = requester
                print("Connect Radar start. Keypath: \(keypath) value: \(try value.jsonString())")
                try await self.startConnectService(requester: requester)
            }
            return nil
        })

        await addInterceptForSet(requester: owner, key: "stop", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "stop", for: requester) {
                self.requester = requester
                print("Connect stop start. Keypath: \(keypath) value: \(try value.jsonString())")
                self.stopConnectService(requester: requester)
            }
            return nil
        })

        await addInterceptForGet(requester: owner, key: "start", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "start", for: requester) {
                self.requester = requester
                print("Connect Radar start. Keypath: \(keypath)")
                try await self.startConnectService(requester: requester)
            }
            return .string("ok")
        })

        await addInterceptForGet(requester: owner, key: "stop", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "stop", for: requester) {
                print("Connect Radar stop. Keypath: \(keypath)")
                self.stopConnectService(requester: requester)
            }
            return .string("ok")
        })

        await addInterceptForGet(requester: owner, key: "invite", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "invite", for: requester) {
                self.requester = requester
                print("Connect Radar invite. Keypath: \(keypath)")
            }
            return .string("ok")
        })

        await addInterceptForSet(requester: owner, key: "invite", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "invite", for: requester) {
                self.requester = requester
                print("Connect Radar invite. Keypath: \(keypath) value: \(try value.jsonString())")
                self.invitePeer(peerDeviceDesciptionValue: value)
            }
            return nil
        })

        await addInterceptForSet(requester: owner, key: "requestContact", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "requestContact", for: requester) {
                self.requester = requester
                print("Request contact. Keypath: \(keypath) value: \(try value.jsonString())")
                return await self.requestContact(payload: value, requester: requester)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "acceptContact", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "acceptContact", for: requester) {
                self.requester = requester
                print("Accept contact. Keypath: \(keypath) value: \(try value.jsonString())")
                return await self.acceptContact(payload: value, requester: requester)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "exportEncounter", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "exportEncounter", for: requester) {
                self.requester = requester
                print("Export encounter. Keypath: \(keypath) value: \(try value.jsonString())")
                return await self.exportEncounter(payload: value, requester: requester)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "exportEncounterJSON", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "exportEncounterJSON", for: requester) {
                self.requester = requester
                print("Export encounter JSON. Keypath: \(keypath) value: \(try value.jsonString())")
                return await self.exportEncounterJSON(payload: value, requester: requester)
            }
            return .string("denied")
        })

        await addInterceptForSet(requester: owner, key: "sharedToken", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("-w--", at: "sharedToken", for: requester) {
                self.requester = requester
                print("Set shared token Keypath: \(keypath) value: \(try value.jsonString())")
                try await self.startConnectService(requester: requester)
            }
            return nil
        })

        await addInterceptForGet(requester: owner, key: "sharedToken", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "sharedToken", for: requester) {
                self.requester = requester
                print("Set shared token. Keypath: \(keypath)")
            }
            return .string("ok")
        })

        await registerContracts(requester: owner)
    }

    func startConnectService(requester: Identity) async throws {
        let previousService = connectService
        connectService = nil
        previousService?.stop()

        let service: ScannerService
        if let lobbyCell = try await CellBase.defaultCellResolver?.cellAtEndpoint(endpoint: "cell:///Lobby", requester: requester) as? LobbyCell {
            let infoDict = lobbyCell.getPublicPurposes()
            service = ScannerService(owner: requester, serviceDicoveryInfoDict: infoDict)
        } else {
            service = ScannerService(owner: requester)
        }

        service.radarDelegate = self
        service.start()
        connectService = service

        var flowElement = FlowElement(title: "Starting", content: .string("start"), properties: FlowElement.Properties(type: .content, contentType: .string))
        flowElement.topic = "scanner"
        flowElement.origin = self.uuid

        pushFlowElement(flowElement, requester: requester)
        pushCapabilitiesEvent(service: service)
    }

    func stopConnectService(requester: Identity) {
        let service = connectService
        connectService = nil
        service?.stop()
        pendingOutgoingRequests.removeAll()
        pendingIncomingRequests.removeAll()

        var flowElement = FlowElement(title: "Stopping", content: .string("stop"), properties: FlowElement.Properties(type: .content, contentType: .string))
        flowElement.topic = "scanner"
        flowElement.origin = self.uuid

        pushFlowElement(flowElement, requester: requester)
    }

    func invitePeer(peerDeviceDesciptionValue: ValueType) {
        guard let connectService = connectService else {
            print("Invite ignored because scanner is not started")
            return
        }
        guard let remoteUUID = remoteUUID(from: peerDeviceDesciptionValue) else {
            print("Invite ignored because remote UUID was missing")
            return
        }
        connectService.invitePeer(remoteUUID)
    }

    func sendData() {
    }

    private func activeLocalIdentity(service: ScannerService? = nil) -> Identity? {
        requester ?? service?.owner ?? connectService?.owner
    }

    private func requestContact(payload: ValueType, requester: Identity) async -> ValueType? {
        do {
            guard let connectService = connectService else {
                throw EntityScannerContactError.scannerNotStarted
            }
            guard let remoteUUID = remoteUUID(from: payload) else {
                throw EntityScannerContactError.missingRemoteUUID
            }

            if connectService.connectedRemoteUUID != remoteUUID {
                connectService.invitePeer(remoteUUID)
                var pendingPayload = makeScannerEventObject(
                    event: "contactPending",
                    remoteUUID: remoteUUID,
                    displayName: connectService.foundPeersDict[remoteUUID]?.displayName,
                    status: "inviteSent"
                )
                pendingPayload["message"] = .string("Connect to the peer before exchanging signed contact proofs")
                addPeerActions(to: &pendingPayload, remoteUUID: remoteUUID)
                pushScannerEvent(topic: EntityScannerTopics.pendingContact, title: "Contact Request Pending", payload: pendingPayload)
                return .object([
                    "status": .string("pendingConnection"),
                    "remoteUUID": .string(remoteUUID)
                ])
            }

            let requestObject = try await buildSignedContactRequest(remoteUUID: remoteUUID, requester: requester)
            guard let requestId = string(from: requestObject["requestId"]) else {
                throw EntityScannerContactError.invalidPayload("requestId")
            }
            pendingOutgoingRequests[requestId] = requestObject

            var flowElement = FlowElement(
                title: "Contact Request",
                content: .object(requestObject),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = EntityScannerTopics.transportRequest
            flowElement.origin = self.uuid
            try await connectService.sendScannerFlowElement(flowElement, remoteUUID: remoteUUID)

            var eventPayload = makeOutgoingContactEventPayload(requestObject: requestObject, remoteUUID: remoteUUID)
            eventPayload["status"] = .string("sent")
            pushScannerEvent(topic: EntityScannerTopics.outgoingContact, title: "Contact Request Sent", payload: eventPayload)

            return .object([
                "status": .string("sent"),
                "requestId": .string(requestId),
                "remoteUUID": .string(remoteUUID)
            ])
        } catch {
            let errorPayload = makeErrorPayload(error: error, payload: payload)
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Contact Request Failed", payload: errorPayload)
            return .object(errorPayload)
        }
    }

    private func acceptContact(payload: ValueType, requester: Identity) async -> ValueType? {
        do {
            guard let connectService = connectService else {
                throw EntityScannerContactError.scannerNotStarted
            }
            guard let requestObject = object(from: payload) else {
                throw EntityScannerContactError.invalidPayload("contact request object")
            }
            guard let requestId = string(from: requestObject["requestId"]) else {
                throw EntityScannerContactError.invalidPayload("requestId")
            }
            let remoteUUID = string(from: requestObject["requesterSessionUUID"])
                ?? string(from: requestObject["remoteUUID"])
                ?? remoteUUID(from: payload)
            guard let remoteUUID else {
                throw EntityScannerContactError.missingRemoteUUID
            }
            guard connectService.connectedRemoteUUID == remoteUUID else {
                throw EntityScannerContactError.notConnected(remoteUUID)
            }

            let requestVerification = await verifySignedPayload(
                requestObject,
                identityKey: "requesterIdentity",
                signatureKey: "requestSignature"
            )
            guard bool(from: requestVerification["verified"]) == true else {
                var verificationPayload = makeIncomingContactEventPayload(
                    requestObject: requestObject,
                    remoteUUID: remoteUUID,
                    verification: requestVerification,
                    includeAcceptAction: false
                )
                verificationPayload["status"] = .string("rejected")
                verificationPayload["message"] = .string("Signature verification failed for incoming contact request")
                pushScannerEvent(topic: EntityScannerTopics.incomingContact, title: "Contact Request Rejected", payload: verificationPayload)
                return .object(verificationPayload)
            }

            pendingIncomingRequests[requestId] = requestObject
            let acceptanceObject = try await buildSignedContactAcceptance(for: requestObject, remoteUUID: remoteUUID, requester: requester)

            var flowElement = FlowElement(
                title: "Contact Acceptance",
                content: .object(acceptanceObject),
                properties: FlowElement.Properties(type: .event, contentType: .object)
            )
            flowElement.topic = EntityScannerTopics.transportAcceptance
            flowElement.origin = self.uuid
            try await connectService.sendScannerFlowElement(flowElement, remoteUUID: remoteUUID)

            let acceptanceVerification = localSignatureVerificationPayload(identity: requester)
            let encounter = try await buildEncounterRecord(
                requestObject: requestObject,
                requestVerification: requestVerification,
                acceptanceObject: acceptanceObject,
                acceptanceVerification: acceptanceVerification,
                requester: requester,
                remoteUUID: remoteUUID
            )
            try await persistEncounterRecord(encounter, requester: requester)
            pendingIncomingRequests.removeValue(forKey: requestId)

            return .object([
                "status": .string("accepted"),
                "requestId": .string(requestId),
                "remoteUUID": .string(remoteUUID)
            ])
        } catch {
            let errorPayload = makeErrorPayload(error: error, payload: payload)
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Accept Contact Failed", payload: errorPayload)
            return .object(errorPayload)
        }
    }

    private func buildSignedContactRequest(remoteUUID: String, requester: Identity) async throws -> Object {
        let requestId = UUID().uuidString
        let perspective = await perspectiveSnapshot(requester: requester)
        var payload: Object = [
            "protocolVersion": .string(EntityScannerContactProtocol.version),
            "messageType": .string("request"),
            "requestId": .string(requestId),
            "encounterId": .string(requestId),
            "createdAt": .float(Date().timeIntervalSince1970),
            "transportMode": .string(connectService?.transportMode ?? "multipeerconnectivity"),
            "precisionMode": .string(connectService?.precisionMode ?? "multipeer-only"),
            "requesterSessionUUID": .string(connectService?.mySessionUUID ?? requester.uuid),
            "remoteUUID": .string(remoteUUID),
            "requesterIdentity": .identity(requester),
            "requesterIdentityUUID": .string(requester.uuid),
            "requesterDisplayName": .string(requester.displayName),
            "requesterPerspective": perspective,
            "capabilities": .object(currentCapabilityPayload())
        ]
        payload["requestHash"] = .string(try hash(of: payload))
        return try await signPayload(payload, signatureKey: "requestSignature", signer: requester)
    }

    private func buildSignedContactAcceptance(for requestObject: Object, remoteUUID: String, requester: Identity) async throws -> Object {
        let perspective = await perspectiveSnapshot(requester: requester)
        var payload: Object = [
            "protocolVersion": .string(EntityScannerContactProtocol.version),
            "messageType": .string("accept"),
            "requestId": requestObject["requestId"] ?? .string(UUID().uuidString),
            "encounterId": requestObject["encounterId"] ?? .string(UUID().uuidString),
            "createdAt": .float(Date().timeIntervalSince1970),
            "transportMode": .string(connectService?.transportMode ?? "multipeerconnectivity"),
            "precisionMode": .string(connectService?.precisionMode ?? "multipeer-only"),
            "requestHash": .string(try hash(of: requestObject)),
            "requesterSessionUUID": requestObject["requesterSessionUUID"] ?? .string(remoteUUID),
            "responderSessionUUID": .string(connectService?.mySessionUUID ?? requester.uuid),
            "remoteUUID": .string(remoteUUID),
            "responderIdentity": .identity(requester),
            "responderIdentityUUID": .string(requester.uuid),
            "responderDisplayName": .string(requester.displayName),
            "responderPerspective": perspective,
            "capabilities": .object(currentCapabilityPayload())
        ]
        payload["acceptanceHash"] = .string(try hash(of: payload))
        return try await signPayload(payload, signatureKey: "acceptanceSignature", signer: requester)
    }

    private func signPayload(_ payload: Object, signatureKey: String, signer: Identity) async throws -> Object {
        let signatureData = try canonicalData(for: payload)
        guard let signature = try await signer.sign(data: signatureData) else {
            throw EntityScannerContactError.signingFailed
        }
        var signedPayload = payload
        signedPayload[signatureKey] = .data(signature)
        return signedPayload
    }

    private func verifySignedPayload(_ payload: Object, identityKey: String, signatureKey: String) async -> Object {
        var verification: Object = [
            "verified": .bool(false),
            "status": .string("invalid")
        ]

        guard let identityValue = payload[identityKey], case let .identity(identity) = identityValue else {
            verification["status"] = .string("missingIdentity")
            return verification
        }
        guard let signatureValue = payload[signatureKey], case let .data(signatureData) = signatureValue else {
            verification["status"] = .string("missingSignature")
            verification["signerIdentityUUID"] = .string(identity.uuid)
            return verification
        }

        do {
            let signaturePayload = removing(keys: [signatureKey], from: payload)
            let messageData = try canonicalData(for: signaturePayload)
            let verified = await identity.verify(signature: signatureData, for: messageData)
            verification["verified"] = .bool(verified)
            verification["status"] = .string(verified ? "verified" : "invalidSignature")
            verification["signerIdentityUUID"] = .string(identity.uuid)
            verification["signerDisplayName"] = .string(identity.displayName)
        } catch {
            verification["status"] = .string("error")
            verification["message"] = .string("\(error)")
            verification["signerIdentityUUID"] = .string(identity.uuid)
        }

        return verification
    }

    private func buildEncounterRecord(
        requestObject: Object,
        requestVerification: Object,
        acceptanceObject: Object,
        acceptanceVerification: Object,
        requester: Identity,
        remoteUUID: String
    ) async throws -> Object {
        let localIsRequester = string(from: requestObject["requesterIdentityUUID"]) == requester.uuid
        let remoteIdentity: Identity?
        let remotePerspective: ValueType
        let localPerspective: ValueType
        let fallbackPerspective = await perspectiveSnapshot(requester: requester)

        if localIsRequester {
            remoteIdentity = identity(from: acceptanceObject["responderIdentity"])
            remotePerspective = acceptanceObject["responderPerspective"] ?? .null
            localPerspective = requestObject["requesterPerspective"] ?? fallbackPerspective
        } else {
            remoteIdentity = identity(from: requestObject["requesterIdentity"])
            remotePerspective = requestObject["requesterPerspective"] ?? .null
            localPerspective = acceptanceObject["responderPerspective"] ?? fallbackPerspective
        }

        let match = await perspectiveMatchSummary(remotePerspective: remotePerspective, requester: requester)
        let matchCount = int(from: object(from: match)?["count"]) ?? 0
        let encounterId = string(from: requestObject["encounterId"]) ?? string(from: acceptanceObject["encounterId"]) ?? UUID().uuidString

        var encounter: Object = [
            "protocolVersion": .string(EntityScannerContactProtocol.version),
            "encounterId": .string(encounterId),
            "requestId": requestObject["requestId"] ?? .string(encounterId),
            "savedAt": .float(Date().timeIntervalSince1970),
            "requestedAt": requestObject["createdAt"] ?? .null,
            "acceptedAt": acceptanceObject["createdAt"] ?? .null,
            "transportMode": acceptanceObject["transportMode"] ?? requestObject["transportMode"] ?? .string("multipeerconnectivity"),
            "precisionMode": acceptanceObject["precisionMode"] ?? requestObject["precisionMode"] ?? .string("multipeer-only"),
            "localRole": .string(localIsRequester ? "requester" : "responder"),
            "localIdentityUUID": .string(requester.uuid),
            "localDisplayName": .string(requester.displayName),
            "localSessionUUID": .string(connectService?.mySessionUUID ?? requester.uuid),
            "remoteSessionUUID": .string(remoteUUID),
            "remoteUUID": .string(remoteUUID),
            "localPerspective": localPerspective,
            "remotePerspective": remotePerspective,
            "match": match,
            "matchCount": .integer(matchCount),
            "requestVerification": .object(requestVerification),
            "acceptanceVerification": .object(acceptanceVerification),
            "requestProof": .object(requestObject),
            "acceptanceProof": .object(acceptanceObject),
            "scannerCapabilities": .object(currentCapabilityPayload())
        ]

        if let remoteIdentity {
            encounter["remoteIdentity"] = .identity(remoteIdentity)
            encounter["remoteIdentityUUID"] = .string(remoteIdentity.uuid)
            encounter["remoteDisplayName"] = .string(remoteIdentity.displayName)
        }

        return encounter
    }

    private func persistEncounterRecord(_ encounter: Object, requester: Identity) async throws {
        guard let entityAnchor = try await entityAnchorCell(requester: requester) else {
            throw EntityScannerContactError.storageUnavailable
        }
        let encounterId = string(from: encounter["encounterId"]) ?? UUID().uuidString
        _ = try await entityAnchor.set(keypath: "proofs.encounters.\(encounterId)", value: .object(encounter), requester: requester)

        if let remoteIdentity = identity(from: encounter["remoteIdentity"]) {
            _ = try? await entityAnchor.set(keypath: "relations.identities.\(remoteIdentity.uuid)", value: .identity(remoteIdentity), requester: requester)
        }

        let summary = encounterSummary(from: encounter)
        pushScannerEvent(topic: EntityScannerTopics.establishedContact, title: "Contact Established", payload: summary)
        pushScannerEvent(topic: EntityScannerTopics.savedEncounter, title: "Encounter Saved", payload: summary)
    }

    private func exportEncounter(payload: ValueType, requester: Identity) async -> ValueType? {
        do {
            let exportObject = try await loadEncounterExportObject(payload: payload, requester: requester)
            pushScannerEvent(topic: EntityScannerTopics.exportedEncounter, title: "Encounter Exported", payload: exportObject)
            return .object(exportObject)
        } catch {
            let errorPayload = makeErrorPayload(error: error, payload: payload)
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Export Encounter Failed", payload: errorPayload)
            return .object(errorPayload)
        }
    }

    private func exportEncounterJSON(payload: ValueType, requester: Identity) async -> ValueType? {
        do {
            var exportObject = try await loadEncounterExportObject(payload: payload, requester: requester)
            let jsonString = try ValueType.object(exportObject).jsonString()
            let copiedToClipboard = await copyTextToPasteboard(jsonString)
            exportObject["status"] = .string("exportedJson")
            exportObject["format"] = .string("application/json")
            exportObject["fileName"] = .string("encounter-\(encounterId(from: payload) ?? UUID().uuidString).json")
            exportObject["copiedToClipboard"] = .bool(copiedToClipboard)
            exportObject["characterCount"] = .integer(jsonString.count)
            exportObject["lineCount"] = .integer(jsonString.components(separatedBy: .newlines).count)
            exportObject["json"] = .string(jsonString)
            pushScannerEvent(topic: EntityScannerTopics.exportedEncounterJSON, title: "Encounter JSON Exported", payload: exportObject)
            return .object(exportObject)
        } catch {
            let errorPayload = makeErrorPayload(error: error, payload: payload)
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Export Encounter JSON Failed", payload: errorPayload)
            return .object(errorPayload)
        }
    }

    private func loadEncounterSummaries(requester: Identity) async -> ValueType {
        guard let entityAnchor = try? await entityAnchorCell(requester: requester) else {
            return .list([])
        }
        guard let storedEncounters = try? await entityAnchor.get(keypath: "proofs.encounters", requester: requester) else {
            return .list([])
        }
        guard case let .object(encounterObject) = storedEncounters else {
            return .list([])
        }

        let summaries = encounterObject.values.compactMap { value -> Object? in
            guard case let .object(encounter) = value else {
                return nil
            }
            return encounterSummary(from: encounter)
        }
        .sorted { lhs, rhs in
            encounterSortTimestamp(from: lhs) > encounterSortTimestamp(from: rhs)
        }

        return .list(summaries.map { .object($0) })
    }

    private func encounterSummary(from encounter: Object) -> Object {
        var summary: Object = [
            "encounterId": encounter["encounterId"] ?? .null,
            "requestId": encounter["requestId"] ?? .null,
            "remoteDisplayName": encounter["remoteDisplayName"] ?? .string("Unknown peer"),
            "remoteIdentityUUID": encounter["remoteIdentityUUID"] ?? .null,
            "remoteUUID": encounter["remoteSessionUUID"] ?? encounter["remoteUUID"] ?? .null,
            "acceptedAt": encounter["acceptedAt"] ?? encounter["savedAt"] ?? .null,
            "savedAt": encounter["savedAt"] ?? .null,
            "transportMode": encounter["transportMode"] ?? .string("multipeerconnectivity"),
            "precisionMode": encounter["precisionMode"] ?? .string("multipeer-only"),
            "matchCount": encounter["matchCount"] ?? .integer(0),
            "requestVerification": encounter["requestVerification"] ?? .null,
            "acceptanceVerification": encounter["acceptanceVerification"] ?? .null,
            "match": encounter["match"] ?? .null,
            "status": .string("saved")
        ]
        if let encounterId = string(from: summary["encounterId"]) {
            summary["actions"] = .object([
                "exportEncounter": .object(makeActionObject(
                    keypath: "exportEncounter",
                    label: "export",
                    payload: .string(encounterId)
                )),
                "exportEncounterJSON": .object(makeActionObject(
                    keypath: "exportEncounterJSON",
                    label: "copy json",
                    payload: .string(encounterId)
                ))
            ])
        }
        mergeCapabilityPayload(into: &summary)
        return summary
    }

    private func makeOutgoingContactEventPayload(requestObject: Object, remoteUUID: String) -> Object {
        let localDisplayName = activeLocalIdentity()?.displayName ?? "Unknown"
        var payload = makeScannerEventObject(
            event: "contactRequested",
            remoteUUID: remoteUUID,
            displayName: connectService?.foundPeersDict[remoteUUID]?.displayName,
            status: "sent"
        )
        payload["requestId"] = requestObject["requestId"] ?? .null
        payload["encounterId"] = requestObject["encounterId"] ?? .null
        payload["requesterDisplayName"] = requestObject["requesterDisplayName"] ?? .string(localDisplayName)
        payload["requesterPerspective"] = requestObject["requesterPerspective"] ?? .null
        return payload
    }

    private func makeIncomingContactEventPayload(
        requestObject: Object,
        remoteUUID: String,
        verification: Object,
        includeAcceptAction: Bool
    ) -> Object {
        var payload = makeScannerEventObject(
            event: "contactReceived",
            remoteUUID: remoteUUID,
            displayName: string(from: requestObject["requesterDisplayName"]),
            status: bool(from: verification["verified"]) == true ? "received" : "invalid"
        )
        payload["requestId"] = requestObject["requestId"] ?? .null
        payload["encounterId"] = requestObject["encounterId"] ?? .null
        payload["requesterDisplayName"] = requestObject["requesterDisplayName"] ?? .string("Unknown")
        payload["requesterIdentityUUID"] = requestObject["requesterIdentityUUID"] ?? .null
        payload["requesterPerspective"] = requestObject["requesterPerspective"] ?? .null
        payload["verification"] = .object(verification)

        if includeAcceptAction {
            payload["actions"] = .object([
                "acceptContact": .object(makeActionObject(keypath: "acceptContact", label: "accept", payload: .object(requestObject)))
            ])
        }

        return payload
    }

    private func pushCapabilitiesEvent(service: ScannerService? = nil) {
        var payload = currentCapabilityPayload(service: service)
        payload["event"] = .string("capabilities")
        payload["timestamp"] = .float(Date().timeIntervalSince1970)
        pushScannerEvent(topic: EntityScannerTopics.capabilities, title: "Scanner Capabilities", payload: payload)
    }

    private func currentCapabilityPayload(service: ScannerService? = nil) -> Object {
        let supportsNearbyPrecision = ScannerService.platformSupportsNearbyPrecision
        let payload = service?.capabilitySnapshot() ?? connectService?.capabilitySnapshot() ?? [
            "transportMode": .string("multipeerconnectivity"),
            "precisionMode": .string(supportsNearbyPrecision ? "uwb" : "multipeer-only"),
            "supportsMultipeerConnectivity": .bool(true),
            "supportsNearbyPrecision": .bool(supportsNearbyPrecision),
            "description": .string(
                supportsNearbyPrecision
                    ? "NearbyInteraction precision is available on this device. Start the scanner to connect to a peer and exchange discovery tokens."
                    : "Start the scanner to evaluate proximity capabilities for this device"
            ),
            "status": .string("scannerNotStarted")
        ]
        return payload
    }

    private func makeActionObject(keypath: String, label: String, payload: ValueType) -> Object {
        [
            "url": .string(EntityScannerContactProtocol.endpoint),
            "keypath": .string(keypath),
            "label": .string(label),
            "payload": payload
        ]
    }

    private func addPeerActions(to payload: inout Object, remoteUUID: String) {
        payload["url"] = .string(EntityScannerContactProtocol.endpoint)
        payload["keypath"] = .string("invite")
        payload["label"] = .string("invite")
        payload["payload"] = .string(remoteUUID)
        payload["actions"] = .object([
            "invite": .object(makeActionObject(keypath: "invite", label: "invite", payload: .string(remoteUUID))),
            "requestContact": .object(makeActionObject(keypath: "requestContact", label: "request contact", payload: .string(remoteUUID)))
        ])
    }

    private func makeScannerEventObject(
        event: String,
        remoteUUID: String? = nil,
        displayName: String? = nil,
        status: String? = nil,
        connected: Bool? = nil,
        connectedDevices: [String]? = nil,
        distanceMeters: Float? = nil,
        directionX: Float? = nil,
        directionY: Float? = nil,
        directionZ: Float? = nil,
        service: ScannerService? = nil
    ) -> Object {
        var deviceObject = Object()
        deviceObject["event"] = .string(event)
        deviceObject["timestamp"] = .float(Date().timeIntervalSince1970)

        if let remoteUUID {
            deviceObject["remoteUUID"] = .string(remoteUUID)
            deviceObject["payload"] = .string(remoteUUID)
        }
        if let displayName {
            deviceObject["displayname"] = .string(displayName)
            deviceObject["displayName"] = .string(displayName)
        }
        if let status {
            deviceObject["status"] = .string(status)
        }
        if let connected {
            deviceObject["connected"] = .bool(connected)
        }
        if let connectedDevices {
            deviceObject["connectedDevices"] = .list(connectedDevices.map { .string($0) })
            deviceObject["connectedCount"] = .integer(connectedDevices.count)
        }
        if let distanceMeters {
            deviceObject["distanceMeters"] = .float(Double(distanceMeters))
        }
        if directionX != nil || directionY != nil || directionZ != nil {
            var directionObject = Object()
            if let directionX {
                directionObject["x"] = .float(Double(directionX))
            }
            if let directionY {
                directionObject["y"] = .float(Double(directionY))
            }
            if let directionZ {
                directionObject["z"] = .float(Double(directionZ))
            }
            deviceObject["direction"] = .object(directionObject)
        }
        mergeCapabilityPayload(into: &deviceObject, service: service)
        return deviceObject
    }

    private func mergeCapabilityPayload(into payload: inout Object, service: ScannerService? = nil) {
        let capabilityPayload = service?.capabilitySnapshot() ?? currentCapabilityPayload(service: service)
        for (key, value) in capabilityPayload where payload[key] == nil {
            payload[key] = value
        }
    }

    private func pushScannerEvent(topic: String, title: String, payload: Object, requesterOverride: Identity? = nil) {
        var flowElement = FlowElement(
            title: title,
            content: .object(payload),
            properties: FlowElement.Properties(type: .content, contentType: .object)
        )
        flowElement.topic = topic
        flowElement.origin = self.uuid
        guard let requester = requesterOverride ?? activeLocalIdentity() else {
            return
        }
        pushFlowElement(flowElement, requester: requester)
    }

    func connectedDevicesChanged(manager: ScannerService, connectedDevices: [String]) {
        print("Connected devices: \(connectedDevices)")
        let requester = activeLocalIdentity(service: manager)
        let payload = makeScannerEventObject(
            event: "connected",
            connected: !connectedDevices.isEmpty,
            connectedDevices: connectedDevices,
            service: manager
        )
        pushScannerEvent(topic: EntityScannerTopics.connected, title: "Connected Devices Changed", payload: payload, requesterOverride: requester)
    }

    func foundDevicesChanged(manager: ScannerService, foundDevice: MCPeerID, remoteUUID: String) {
        let requester = activeLocalIdentity(service: manager)
        var payload = makeScannerEventObject(
            event: "found",
            remoteUUID: remoteUUID,
            displayName: manager.foundPeersDict[remoteUUID]?.displayName ?? foundDevice.displayName,
            connected: false,
            service: manager
        )
        addPeerActions(to: &payload, remoteUUID: remoteUUID)
        pushScannerEvent(topic: EntityScannerTopics.found, title: "Found Device", payload: payload, requesterOverride: requester)
    }

    func lostDeviceChanged(manager: ScannerService, lostDevice: MCPeerID, remoteUUID: String) {
        let requester = activeLocalIdentity(service: manager)
        let payload = makeScannerEventObject(
            event: "lost",
            remoteUUID: remoteUUID,
            displayName: lostDevice.displayName,
            connected: false,
            service: manager
        )
        pushScannerEvent(topic: EntityScannerTopics.lost, title: "Lost Device", payload: payload, requesterOverride: requester)
    }

    func scannerStatusChanged(manager: ScannerService, status: String, remoteUUID: String?) {
        let requester = activeLocalIdentity(service: manager)
        var payload = makeScannerEventObject(
            event: "status",
            remoteUUID: remoteUUID,
            status: status,
            service: manager
        )
        mergeCapabilityPayload(into: &payload, service: manager)
        pushScannerEvent(topic: EntityScannerTopics.status, title: "Scanner Status", payload: payload, requesterOverride: requester)
    }

    func proximityChanged(
        manager: ScannerService,
        remoteUUID: String,
        distanceMeters: Float?,
        directionX: Float?,
        directionY: Float?,
        directionZ: Float?
    ) {
        let requester = activeLocalIdentity(service: manager)
        var payload = makeScannerEventObject(
            event: "proximity",
            remoteUUID: remoteUUID,
            distanceMeters: distanceMeters,
            directionX: directionX,
            directionY: directionY,
            directionZ: directionZ,
            service: manager
        )
        mergeCapabilityPayload(into: &payload, service: manager)
        pushScannerEvent(topic: EntityScannerTopics.proximity, title: "Proximity Updated", payload: payload, requesterOverride: requester)
    }

    func scannerFlowReceived(manager: ScannerService, flowElement: FlowElement, remoteUUID: String?) {
        Task { [weak self] in
            guard let self = self else { return }
            switch flowElement.topic {
            case EntityScannerTopics.transportRequest:
                await self.handleIncomingContactRequest(flowElement: flowElement, remoteUUID: remoteUUID)
            case EntityScannerTopics.transportAcceptance:
                await self.handleIncomingContactAcceptance(flowElement: flowElement, remoteUUID: remoteUUID)
            default:
                break
            }
        }
    }

    private func handleIncomingContactRequest(flowElement: FlowElement, remoteUUID: String?) async {
        guard case let .object(requestObject) = flowElement.content else {
            return
        }
        guard let remoteUUID = remoteUUID ?? string(from: requestObject["requesterSessionUUID"]) else {
            return
        }

        let verification = await verifySignedPayload(
            requestObject,
            identityKey: "requesterIdentity",
            signatureKey: "requestSignature"
        )
        if let requestId = string(from: requestObject["requestId"]) {
            pendingIncomingRequests[requestId] = requestObject
        }

        let payload = makeIncomingContactEventPayload(
            requestObject: requestObject,
            remoteUUID: remoteUUID,
            verification: verification,
            includeAcceptAction: bool(from: verification["verified"]) == true
        )
        pushScannerEvent(topic: EntityScannerTopics.incomingContact, title: "Contact Request Received", payload: payload)
    }

    private func handleIncomingContactAcceptance(flowElement: FlowElement, remoteUUID: String?) async {
        guard case let .object(acceptanceObject) = flowElement.content else {
            return
        }
        guard let requestId = string(from: acceptanceObject["requestId"]),
              let requestObject = pendingOutgoingRequests[requestId] else {
            let payload = makeErrorPayload(error: EntityScannerContactError.invalidPayload("requestId"), payload: .object(acceptanceObject))
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Contact Acceptance Failed", payload: payload)
            return
        }

        let verification = await verifySignedPayload(
            acceptanceObject,
            identityKey: "responderIdentity",
            signatureKey: "acceptanceSignature"
        )
        guard bool(from: verification["verified"]) == true else {
            var payload = makeErrorPayload(error: EntityScannerContactError.invalidPayload("acceptanceSignature"), payload: .object(acceptanceObject))
            payload["verification"] = .object(verification)
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Contact Acceptance Failed", payload: payload)
            return
        }

        do {
            guard let localIdentity = activeLocalIdentity() else {
                throw EntityScannerContactError.invalidPayload("localIdentity")
            }
            let localVerification = localSignatureVerificationPayload(identity: localIdentity)
            let remoteUUID = remoteUUID
                ?? string(from: acceptanceObject["responderSessionUUID"])
                ?? string(from: requestObject["remoteUUID"])
                ?? "unknown"
            let encounter = try await buildEncounterRecord(
                requestObject: requestObject,
                requestVerification: localVerification,
                acceptanceObject: acceptanceObject,
                acceptanceVerification: verification,
                requester: localIdentity,
                remoteUUID: remoteUUID
            )
            try await persistEncounterRecord(encounter, requester: localIdentity)
            pendingOutgoingRequests.removeValue(forKey: requestId)
        } catch {
            let payload = makeErrorPayload(error: error, payload: .object(acceptanceObject))
            pushScannerEvent(topic: EntityScannerTopics.status, title: "Encounter Persistence Failed", payload: payload)
        }
    }

    func foundDevicesChanged(manager: ScannerService, foundDevices: [String], requester: Identity) {
        print("Found devices: \(foundDevices)")
        guard let displayName = foundDevices.first else {
            return
        }
        let payload = makeScannerEventObject(
            event: "found",
            remoteUUID: displayName,
            displayName: displayName,
            connected: false
        )
        var flowElement = FlowElement(
            title: "Found Device",
            content: .object(payload),
            properties: FlowElement.Properties(type: .content, contentType: .object)
        )
        flowElement.topic = EntityScannerTopics.found
        flowElement.origin = self.uuid
        pushFlowElement(flowElement, requester: requester)
    }

    func colorChanged(manager: ScannerService, colorString: String) {
    }

    func setSharedToken() {
    }

    func getSharedToken() {
    }

    func gotSharedDicoveryToken(payload: FlowElementValueType) throws {
        guard case let .object(paramObject) = payload else {
            throw SetValueError.paramErr
        }
        guard let uuidValue = paramObject["userUuid"] else {
            throw SetValueError.noParamValue("userUuid")
        }
        guard case let .string(userUuid) = uuidValue else {
            throw SetValueError.paramErr
        }
        guard let tokenValue = paramObject["token"] else {
            throw SetValueError.noParamValue("token")
        }
        guard case let .data(tokenData) = tokenValue else {
            throw SetValueError.paramErr
        }

        self.gotSharedDicoveryToken(tokenData, userUuid: userUuid)
    }

    func gotSharedDicoveryToken(_ tokenData: Data, userUuid: String) {
#if os(iOS)
        connectService?.peerDidShareDiscoveryToken(tokenData: tokenData, userUuid: userUuid)
#endif
    }

    private func perspectiveSnapshot(requester: Identity) async -> ValueType {
        guard let resolver = CellBase.defaultCellResolver,
              let perspective = try? await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester) as? Meddle else {
            return .object([
                "status": .string("unavailable"),
                "activePurposes": .list([])
            ])
        }

        guard var state = object(from: try? await perspective.get(keypath: "perspective.state", requester: requester)) else {
            return .object([
                "status": .string("unavailable"),
                "activePurposes": .list([])
            ])
        }
        if let advertisedPurpose = try? await perspective.get(keypath: "advertisedPurpose", requester: requester) {
            state["advertisedPurpose"] = advertisedPurpose
        }
        return .object(state)
    }

    private func perspectiveMatchSummary(remotePerspective: ValueType, requester: Identity) async -> ValueType {
        guard let resolver = CellBase.defaultCellResolver,
              let perspective = try? await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester) as? Meddle else {
            return .object([
                "count": .integer(0),
                "allHits": .list([])
            ])
        }
        return (try? await perspective.set(keypath: "perspective.query.match", value: remotePerspective, requester: requester)) ?? .object([
            "count": .integer(0),
            "allHits": .list([])
        ])
    }

    private func entityAnchorCell(requester: Identity) async throws -> Meddle? {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        return try await resolver.cellAtEndpoint(endpoint: "cell:///EntityAnchor", requester: requester) as? Meddle
    }

    private func canonicalData(for payload: Object) throws -> Data {
        try FlowCanonicalEncoder.canonicalData(for: .object(payload))
    }

    private func loadEncounterExportObject(payload: ValueType, requester: Identity) async throws -> Object {
        guard let entityAnchor = try await entityAnchorCell(requester: requester) else {
            throw EntityScannerContactError.storageUnavailable
        }
        guard let encounterId = encounterId(from: payload) else {
            throw EntityScannerContactError.invalidPayload("encounterId")
        }
        guard let encounterValue = try? await entityAnchor.get(keypath: "proofs.encounters.\(encounterId)", requester: requester),
              case let .object(encounterObject) = encounterValue else {
            throw KeypathStorageErrors.notFound
        }

        var exportObject = encounterObject
        exportObject["exportedAt"] = .float(Date().timeIntervalSince1970)
        exportObject["status"] = .string("exported")
        exportObject["exportedEncounterId"] = .string(encounterId)
        mergeCapabilityPayload(into: &exportObject)
        return exportObject
    }

    private func hash(of payload: Object) throws -> String {
        try FlowHasher.sha256Hex(canonicalData(for: payload))
    }

    private func localSignatureVerificationPayload(identity: Identity) -> Object {
        [
            "verified": .bool(true),
            "status": .string("localSignature"),
            "signerIdentityUUID": .string(identity.uuid),
            "signerDisplayName": .string(identity.displayName)
        ]
    }

    private func makeErrorPayload(error: Error, payload: ValueType?) -> Object {
        var result: Object = [
            "status": .string("error"),
            "message": .string("\(error)"),
            "timestamp": .float(Date().timeIntervalSince1970)
        ]
        if let remoteUUID = payload.flatMap(remoteUUID(from:)) {
            result["remoteUUID"] = .string(remoteUUID)
        }
        mergeCapabilityPayload(into: &result)
        return result
    }

    private func copyTextToPasteboard(_ text: String) async -> Bool {
        await MainActor.run {
#if canImport(UIKit)
            UIPasteboard.general.string = text
            return UIPasteboard.general.string == text
#elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
#else
            return false
#endif
        }
    }

    private func encounterSortTimestamp(from summary: Object) -> Double {
        double(from: summary["acceptedAt"]) ?? double(from: summary["savedAt"]) ?? 0
    }

    private func remoteUUID(from value: ValueType) -> String? {
        switch value {
        case .string(let remoteUUID):
            return normalized(remoteUUID)
        case .object(let object):
            if let remoteUUID = string(from: object["remoteUUID"]) {
                return normalized(remoteUUID)
            }
            if let payload = object["payload"] {
                return remoteUUID(from: payload)
            }
            if let selected = object["selected"] {
                return remoteUUID(from: selected)
            }
            return nil
        default:
            return nil
        }
    }

    private func encounterId(from value: ValueType) -> String? {
        switch value {
        case .string(let encounterId):
            return normalized(encounterId)
        case .object(let object):
            if let encounterId = string(from: object["encounterId"]) {
                return normalized(encounterId)
            }
            if let payload = object["payload"] {
                return encounterId(from: payload)
            }
            if let selected = object["selected"] {
                return encounterId(from: selected)
            }
            return nil
        default:
            return nil
        }
    }

    private func object(from value: ValueType?) -> Object? {
        guard let value else {
            return nil
        }
        if case let .object(object) = value {
            return object
        }
        return nil
    }

    private func identity(from value: ValueType?) -> Identity? {
        guard let value else {
            return nil
        }
        if case let .identity(identity) = value {
            return identity
        }
        return nil
    }

    private func string(from value: ValueType?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .string(let string):
            return string
        default:
            return nil
        }
    }

    private func bool(from value: ValueType?) -> Bool? {
        guard let value else {
            return nil
        }
        switch value {
        case .bool(let bool):
            return bool
        default:
            return nil
        }
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "verificationMethods",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(
                type: "string",
                description: "Returns a scanner verification status string. Current implementation reports placeholder values."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Reports verification method availability for scanner contact exchange.")
        )

        await registerExploreContract(
            requester: requester,
            key: "capabilities",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [Self.capabilitySchema(), ExploreContract.schema(type: "string")],
                description: "Returns scanner capability details or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            flowEffects: [Self.flowEffect(trigger: .get, topic: EntityScannerTopics.capabilities)],
            description: .string("Reports current scanner transport and proximity capabilities.")
        )

        await registerExploreContract(
            requester: requester,
            key: "encounters",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.listSchema(item: Self.encounterSummarySchema()),
                    ExploreContract.schema(type: "string")
                ],
                description: "Returns saved encounter summaries or a denial/failure string."
            ),
            permissions: ["r---"],
            required: false,
            flowEffects: [Self.flowEffect(trigger: .get, topic: EntityScannerTopics.savedEncounter)],
            description: .string("Lists persisted encounter summaries captured through scanner contact exchange.")
        )

        for key in ["start", "stop", "invite", "sharedToken"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .get,
                input: .null,
                returns: ExploreContract.schema(type: "string", description: "Acknowledgement string."),
                permissions: ["r---"],
                required: false,
                flowEffects: Self.getFlowEffects(for: key),
                description: .string(Self.getSummary(for: key))
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "start",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.objectSchema(description: "Optional scanner startup options.")],
                description: "Starts the scanner, optionally with future startup options."
            ),
            returns: .null,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                Self.flowEffect(topic: "scanner", contentType: "string"),
                Self.flowEffect(topic: EntityScannerTopics.capabilities)
            ],
            description: .string("Starts scanning and emits scanner/capability events.")
        )

        await registerExploreContract(
            requester: requester,
            key: "stop",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [.null, ExploreContract.objectSchema(description: "Optional scanner shutdown options.")],
                description: "Stops the scanner."
            ),
            returns: .null,
            permissions: ["-w--"],
            required: false,
            flowEffects: [Self.flowEffect(topic: "scanner", contentType: "string")],
            description: .string("Stops scanning and clears pending contact exchange state.")
        )

        await registerExploreContract(
            requester: requester,
            key: "invite",
            method: .set,
            input: Self.remoteSelectionSchema(description: "Remote peer selection payload."),
            returns: .null,
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                Self.flowEffect(topic: EntityScannerTopics.pendingContact),
                Self.flowEffect(topic: EntityScannerTopics.connected)
            ],
            description: .string("Invites a remote peer by UUID or selected peer payload.")
        )

        await registerExploreContract(
            requester: requester,
            key: "requestContact",
            method: .set,
            input: Self.remoteSelectionSchema(description: "Remote peer selection payload for a signed contact request."),
            returns: ExploreContract.oneOfSchema(
                options: [Self.contactMutationResultSchema(), Self.errorSchema(), ExploreContract.schema(type: "string")],
                description: "Returns contact request result metadata or an error string/object."
            ),
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                Self.flowEffect(topic: EntityScannerTopics.pendingContact),
                Self.flowEffect(topic: EntityScannerTopics.outgoingContact),
                Self.flowEffect(topic: EntityScannerTopics.status)
            ],
            description: .string("Starts signed contact exchange with a connected or connectable remote peer.")
        )

        await registerExploreContract(
            requester: requester,
            key: "acceptContact",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "object", description: "Signed contact request object."),
                    ExploreContract.objectSchema(
                        properties: [
                            "requestId": ExploreContract.schema(type: "string"),
                            "payload": ExploreContract.schema(type: "object")
                        ],
                        description: "Selected action payload containing a signed contact request."
                    )
                ],
                description: "Accepts an incoming signed contact request."
            ),
            returns: ExploreContract.oneOfSchema(
                options: [Self.contactMutationResultSchema(), Self.errorSchema(), ExploreContract.schema(type: "string")],
                description: "Returns acceptance result metadata or an error string/object."
            ),
            permissions: ["-w--"],
            required: true,
            flowEffects: [
                Self.flowEffect(topic: EntityScannerTopics.establishedContact),
                Self.flowEffect(topic: EntityScannerTopics.savedEncounter),
                Self.flowEffect(topic: EntityScannerTopics.status)
            ],
            description: .string("Accepts an incoming signed contact request and persists an encounter record.")
        )

        for key in ["exportEncounter", "exportEncounterJSON"] {
            await registerExploreContract(
                requester: requester,
                key: key,
                method: .set,
                input: Self.encounterSelectionSchema(
                    description: key == "exportEncounter"
                        ? "Encounter identifier or selected encounter payload."
                        : "Encounter identifier or selected encounter payload for JSON export."
                ),
                returns: ExploreContract.oneOfSchema(
                    options: [Self.encounterExportSchema(), Self.errorSchema(), ExploreContract.schema(type: "string")],
                    description: "Returns exported encounter payload or an error string/object."
                ),
                permissions: ["-w--"],
                required: true,
                flowEffects: [
                    Self.flowEffect(topic: key == "exportEncounter" ? EntityScannerTopics.exportedEncounter : EntityScannerTopics.exportedEncounterJSON),
                    Self.flowEffect(topic: EntityScannerTopics.status)
                ],
                description: .string(
                    key == "exportEncounter"
                        ? "Loads and returns a persisted encounter export payload."
                        : "Loads, serializes, and returns a persisted encounter export payload plus JSON text."
                )
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "sharedToken",
            method: .set,
            input: ExploreContract.oneOfSchema(
                options: [
                    ExploreContract.schema(type: "string"),
                    ExploreContract.objectSchema(description: "Future shared token payload.")
                ],
                description: "Sets shared token context and restarts scanner discovery."
            ),
            returns: .null,
            permissions: ["-w--"],
            required: false,
            flowEffects: [
                Self.flowEffect(topic: "scanner", contentType: "string"),
                Self.flowEffect(topic: EntityScannerTopics.capabilities)
            ],
            description: .string("Applies shared discovery token context and restarts scanner service.")
        )
    }

    private static func getSummary(for key: String) -> String {
        switch key {
        case "start":
            return "Starts the scanner via a read-style trigger and returns an acknowledgement string."
        case "stop":
            return "Stops the scanner via a read-style trigger and returns an acknowledgement string."
        case "invite":
            return "Returns an acknowledgement string for invite-oriented UI actions."
        case "sharedToken":
            return "Returns an acknowledgement string for shared token UI actions."
        default:
            return "Returns scanner action acknowledgement."
        }
    }

    private static func getFlowEffects(for key: String) -> [ValueType] {
        switch key {
        case "start":
            return [
                flowEffect(trigger: .get, topic: "scanner", contentType: "string"),
                flowEffect(trigger: .get, topic: EntityScannerTopics.capabilities)
            ]
        case "stop":
            return [flowEffect(trigger: .get, topic: "scanner", contentType: "string")]
        default:
            return []
        }
    }

    private static func flowEffect(
        trigger: ExploreContractMethod = .set,
        topic: String,
        contentType: String = "object"
    ) -> ValueType {
        ExploreContract.flowEffect(trigger: trigger, topic: topic, contentType: contentType)
    }

    private static func remoteSelectionSchema(description: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Remote UUID."),
                ExploreContract.objectSchema(
                    properties: [
                        "remoteUUID": ExploreContract.schema(type: "string"),
                        "payload": ExploreContract.schema(type: "string"),
                        "selected": ExploreContract.schema(type: "object")
                    ],
                    description: description
                )
            ],
            description: description
        )
    }

    private static func encounterSelectionSchema(description: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Encounter identifier."),
                ExploreContract.objectSchema(
                    properties: [
                        "encounterId": ExploreContract.schema(type: "string"),
                        "payload": ExploreContract.schema(type: "string"),
                        "selected": ExploreContract.schema(type: "object")
                    ],
                    description: description
                )
            ],
            description: description
        )
    }

    private static func capabilitySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "transportMode": ExploreContract.schema(type: "string"),
                "precisionMode": ExploreContract.schema(type: "string"),
                "supportsMultipeerConnectivity": ExploreContract.schema(type: "bool"),
                "supportsNearbyPrecision": ExploreContract.schema(type: "bool"),
                "description": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["transportMode", "precisionMode", "status"],
            description: "Current scanner transport and proximity capability snapshot."
        )
    }

    private static func actionSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "url": ExploreContract.schema(type: "string"),
                "keypath": ExploreContract.schema(type: "string"),
                "label": ExploreContract.schema(type: "string"),
                "payload": ExploreContract.unknownSchema(description: "Action payload to submit back to the scanner cell.")
            ],
            requiredKeys: ["url", "keypath", "label"],
            description: "Action object for scanner follow-up operations."
        )
    }

    private static func verificationSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "verified": ExploreContract.schema(type: "bool"),
                "status": ExploreContract.schema(type: "string"),
                "signerIdentityUUID": ExploreContract.schema(type: "string"),
                "signerDisplayName": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["verified", "status"],
            description: "Signature verification result for scanner contact payloads."
        )
    }

    private static func encounterSummarySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "encounterId": ExploreContract.schema(type: "string"),
                "requestId": ExploreContract.schema(type: "string"),
                "remoteDisplayName": ExploreContract.schema(type: "string"),
                "remoteIdentityUUID": ExploreContract.schema(type: "string"),
                "remoteUUID": ExploreContract.schema(type: "string"),
                "acceptedAt": ExploreContract.schema(type: "float"),
                "savedAt": ExploreContract.schema(type: "float"),
                "transportMode": ExploreContract.schema(type: "string"),
                "precisionMode": ExploreContract.schema(type: "string"),
                "matchCount": ExploreContract.schema(type: "integer"),
                "requestVerification": verificationSchema(),
                "acceptanceVerification": verificationSchema(),
                "match": ExploreContract.schema(type: "object"),
                "status": ExploreContract.schema(type: "string"),
                "actions": ExploreContract.objectSchema(
                    properties: [
                        "exportEncounter": actionSchema(),
                        "exportEncounterJSON": actionSchema()
                    ],
                    description: "Available follow-up actions for the encounter."
                )
            ],
            requiredKeys: ["encounterId", "remoteDisplayName", "transportMode", "precisionMode", "matchCount", "status"],
            description: "Persisted encounter summary suitable for UI listing and export actions."
        )
    }

    private static func contactMutationResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "remoteUUID": ExploreContract.schema(type: "string"),
                "requestId": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status"],
            description: "Result metadata for contact request or acceptance mutations."
        )
    }

    private static func encounterExportSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "encounterId": ExploreContract.schema(type: "string"),
                "requestId": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "exportedAt": ExploreContract.schema(type: "float"),
                "exportedEncounterId": ExploreContract.schema(type: "string"),
                "json": ExploreContract.schema(type: "string"),
                "format": ExploreContract.schema(type: "string"),
                "fileName": ExploreContract.schema(type: "string"),
                "copiedToClipboard": ExploreContract.schema(type: "bool"),
                "characterCount": ExploreContract.schema(type: "integer"),
                "lineCount": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["status"],
            description: "Encounter export payload, optionally with JSON serialization metadata."
        )
    }

    private static func errorSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "timestamp": ExploreContract.schema(type: "float"),
                "remoteUUID": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "message"],
            description: "Structured scanner error payload."
        )
    }

    private func int(from value: ValueType?) -> Int? {
        guard let value else {
            return nil
        }
        switch value {
        case .integer(let int):
            return int
        case .number(let int):
            return int
        default:
            return nil
        }
    }

    private func double(from value: ValueType?) -> Double? {
        guard let value else {
            return nil
        }
        switch value {
        case .float(let double):
            return double
        case .integer(let int):
            return Double(int)
        case .number(let int):
            return Double(int)
        default:
            return nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private func removing(keys: [String], from payload: Object) -> Object {
        var filtered = payload
        for key in keys {
            filtered.removeValue(forKey: key)
        }
        return filtered
    }
}
