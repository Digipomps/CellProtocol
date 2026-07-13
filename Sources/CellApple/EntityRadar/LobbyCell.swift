// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  LobbyCell.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 27/11/2024.
//
@_spi(HAVENRuntime) import CellBase
import Foundation

/*
 The lobby is where other entities are first let in.
 First create a dictionary with some (public) info about whhat you're pursuing
 */

class LobbyCell: GeneralCell {
    var running: Bool = false
    
    
    var context: Perspective
    var perspectiveCell: PerspectiveCell?
    private var publicPurposeDict = [String: String]()
    
    required init(owner: Identity) async {
        
        self.context = Perspective()
        
        await super.init(owner: owner)
        
        print("LobbyCell init. Owner: \(owner.uuid)")
        try? await ensureRuntimeReady()
    }
    
    required init(from decoder: any Decoder) throws {
        context = Perspective()
        perspectiveCell = nil
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicPurposeDict = try container.decodeIfPresent([String: String].self, forKey: .publicPurposeDict) ?? [:]
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        try super.init(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case publicPurposeDict
        case running
    }

    override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicPurposeDict, forKey: .publicPurposeDict)
        try container.encode(running, forKey: .running)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        let bindingOwner = storedOwnerIdentity
        await setupPermissions(owner: bindingOwner)
        await setupKeys(owner: bindingOwner)
    }
    
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.ensureGrant("rw--", for: "start")
        self.agreementTemplate.ensureGrant("rw--", for: "stop")
        self.agreementTemplate.ensureGrant("rw--", for: "purposes")
    }
    
    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "start") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "start", for: requester) else {
                return .string("denied")
            }
            try await self.startChatSimulation(requester: requester)
            return .string("ok")
        }

        await addInterceptForGet(requester: owner, key: "stop") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "stop", for: requester) else {
                return .string("denied")
            }
            try await self.stopChatSimulation()
            return .string("ok")
        }

        await addInterceptForGet(requester: owner, key: "purposes") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "purposes", for: requester) else {
                return .string("denied")
            }
            return .object(self.getPublicPurposesValue())
        }

        await addInterceptForSet(requester: owner, key: "purposes") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "purposes", for: requester) else {
                return .string("denied")
            }
            try await self.setPublicPurposes(purposesValue: value)
            return .string("ok")
        }
    }
    
    func getPerspectiveCell(requester: Identity) async throws -> PerspectiveCell {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        guard let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester ) as? PerspectiveCell else {
            throw CellBaseError.noTargetCell
        }
        
        let admitState = try await self.attach(emitter: cell, label: "perspective", requester: requester)
        if admitState == ConnectState.connected {
            try await self.absorbFlow(label: "perspective", requester: requester)
        }
        return cell
    }
    
    func startChatSimulation(requester: Identity) async throws {
        print("Starting emitter")
        running = true
        runEmitter(requester: requester)
    }
    
    func stopChatSimulation() async throws {
        self.running = false
    }
    
    func addMessage(messageValue: ValueType, requester: Identity) {
        
    }
    
    // This is just for testing while developing
    func runEmitter(requester: Identity) {
        var feedItem = FlowElement(id: UUID().uuidString, title: "TestMessage", content: .object(["key" : .string("value")]), properties: FlowElement.Properties(type: .content, contentType: .object)) // Remember to change to .event
        
        feedItem.topic = "scanner" // was radar
        
        self.pushFlowElement(feedItem, requester: requester)
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double.random(in: 2..<10)) { [weak self] in
                     self?.runEmitter(requester: requester)
            }
        }
    }
    
    //---------------
    func getPublicPurposes() -> [String: String] {
        
        
        return publicPurposeDict
    }
    
    private func getPublicPurposesValue() -> Object {
        var pruposesObject = Object()
        for (key, value) in publicPurposeDict {
            pruposesObject[key] = .string(value)
        }
        return pruposesObject
    }
    
    private func setPublicPurposes(purposesValue: ValueType) async throws {
        guard case .object(let object) = purposesValue else {
            return
        }
        var purposeDict = [String : String]()
        
        for (key, value) in object {
            if case let .string(string) = value {
                purposeDict[key] = string
            }
        }
        setPublicPurposes(purposesDict: purposeDict)
    }
    
    private func setPublicPurposes(purposesDict: [String : String]) {
        self.publicPurposeDict = purposesDict
    }

}
