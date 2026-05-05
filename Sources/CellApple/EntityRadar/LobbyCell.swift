// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  LobbyCell.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 27/11/2024.
//
import CellBase
import CellApple
import Foundation

/*
 The lobby is where other entities are first let in.
 First create a dictionary with some (public) info about whhat you're pursuing
 */

class LobbyCell: GeneralCell {
    var running: Bool = false
    
    
    var context: Perspective
    var perspectiveCell: PerspectiveCell?
    private var publicPurposeDict = ["Test": "Test"]
    
    required init(owner: Identity) async {
        
        self.context = Perspective()
        
        await super.init(owner: owner)
        
        print("LobbyCell init. Owner: \(owner.uuid)")
        self.perspectiveCell = try? await getPerspectiveCell(requester: owner)
        
            await setupPermissions(owner: owner)
            await setupKeys(owner: owner)
    }
    
    required init(from decoder: any Decoder) throws {
        fatalError("LobbyCell init(from:) has not been implemented")
    }
    
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("rw--", for: "start")
        self.agreementTemplate.addGrant("rw--", for: "stop")
    }
    
    private func setupKeys(owner: Identity) async  {
        await addInterceptForGet(requester: owner, key: "start", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let resultString = "denied"
            if await self.validateAccess("r---", at: "start", for: requester) {
                try await self.startChatSimulation(requester: owner)
                return .string("ok")
            }
            return .string(resultString)
        })
        
        await addInterceptForGet(requester: owner, key: "stop", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let resultString = "denied"
            if await self.validateAccess("r---", at: "stop", for: requester) {
                try await self.stopChatSimulation()
            }
            return .string(resultString)
        })
        
        await addInterceptForSet(requester: owner, key: "addMessage", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "addMessage", for: requester) {
                print("Lobby cell addMessage. Keypath: \(keypath) value: \(try value.jsonString())")
//                startConnectService()
            }
            
            return nil
        })
        
//        Public Purposes
        await addInterceptForGet(requester: owner, key: "purposes", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let resultString = "denied"
            if await self.validateAccess("r---", at: "purposes", for: requester) {
                try await self.stopChatSimulation()
            }
            return .string(resultString)
        })
        
        await addInterceptForSet(requester: owner, key: "purposes", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "purposes", for: requester) {
                print("Lobby cell purposes. Keypath: \(keypath) value: \(try value.jsonString())")
//                startConnectService()
            }
            
            return nil
        })
        
        // Administer scanning and advertising
        await addInterceptForGet(requester: owner, key: "advertise", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let resultString = "denied"
            if await self.validateAccess("r---", at: "advertise", for: requester) {
                try await self.stopChatSimulation()
            }
            return .string(resultString)
        })
        
        await addInterceptForGet(requester: owner, key: "withhold", getValueIntercept:  { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            let resultString = "denied"
            if await self.validateAccess("r---", at: "withhold", for: requester) {
                try await self.stopChatSimulation()
            }
            return .string(resultString)
        })
        
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
