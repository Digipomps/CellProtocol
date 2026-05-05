// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 13/12/2023.
//

import Foundation
import CellBase

enum OrchestratorError: Error {
    case noConfiguration
}


// Test of Cell that holds and loads a cell configuration that is persisted as a json file
class OrchestratorCell: GeneralCell {
    private var cellConfiguration: CellConfiguration?
    
//    private var app: Application?
    let cellConfigurationFilename = "CellConfiguration.json"
    let namedEmittersFilename = "NamedEmitters.json"
    let identityNamedEmittersFilename = "IdentityNamedEmitters.json"
    
    var cellConfigurationHistory = [CellConfiguration]()
    
    var connectionStatuses = [ConnectionStatus]()
    
    var connectionStatusValues: ValueType {
        get {
            var statusesList = ValueTypeList()
            for currentStatus in self.connectionStatuses {
                var statusObject: Object = [:]
                statusObject["name"] = .string(currentStatus.name)
                statusObject["active"] = .bool(currentStatus.active)
                statusesList.append(.object(statusObject))
            }
            return .list(statusesList)
        }
    }
    
    var outwardMenuCellConfigurations = Object()
    
    
    required init(owner: Identity) async {
        await super.init(owner: owner)
        
        print("Orchestrator (Porthole vapor) cell init")
        
        self.name = "Porthole"
        
        self.agreementTemplate.addGrant("r---", for: "skeleton")
        self.agreementTemplate.addGrant("r---", for: "connectedCellEmitters")
        self.agreementTemplate.addGrant("r---", for: "flow")
        
        
        do {
            try await loadNamedEmitters(requester: owner)
        } catch {
            print("Initial loading of namedEmitters failed with error: \(error) uuid: ")
        }
        do {
            try await loadIdentityNamedEmitters(requester: owner)
                } catch {
                    print("Initial loading of identityNamedEmitters failed with error: \(error) uuid: ")
                }
        do {
            try await loadCellConfiguration(requester: owner)
        } catch {
            print("Initial loading of cellConfiguration failed with error: \(error) uuid: ")
        }
        
        buildOutwardMenuCellConfigurations()
        
        
        
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, requester in
            print("Incoming flowElement to orchestrator cell: \(flowElement.title) label: \(flowElement.topic)")
            guard let self = self else { return nil }
            if flowElement.properties?.type == .event || flowElement.properties?.type == .alert {
                print("Scaffold orchestrator got event feed item. Title: \(flowElement.title), label: \(flowElement.topic)")
                if flowElement.topic == "register" {
                    if case .string(let string) = flowElement.content {
                        if string == "registered_named_cell" {
                            do {
                                try await self.saveNamedEmitters(requester: requester)
                            } catch {
                                print("Saving named emitters failed with error: \(error)")
                            }
                        } else if string == "registered_identity_named_cell" {
                            do {
                                try await self.saveIdentityNamedEmitters(requester: requester)
                            } catch {
                                print("Saving named emitters failed with error: \(error)")
                            }
                        }
                    }
                }
                    
                
                return nil
            }
            do {
//                let widgetData = try await self.wrapChatJsonInHtmlFragment(jsonObject: contentObject)
                if flowElement.title == "Message" {
                    guard case let .object(contentObject) = flowElement.content else {
                        print("flow element content not object")
                        return nil
                    }
                    let widgetString = "not implemented"
                    var messageFlowElement = FlowElement(title: "Message", content: .string(widgetString), properties: FlowElement.Properties(mimetype: "application/xhtml+xml", type: .content, contentType: .base64))
                    messageFlowElement.topic = flowElement.topic
                    return messageFlowElement
                } else {
                    return flowElement
                }
                
            } catch {
                print("Embedding data in widget failed with error: \(error)")
            }
            return nil
        })

        
        await setInterceptValueForKey(requester: owner, key: "skeleton", setValueForKeyIntercept:  { [weak self] requester in
            guard let self = self else { return .string("failure") }
            var resultString = "denied"
            if await self.validateAccess("r---", at: "skeleton", for: requester) {
                do {
                    resultString =  try await self.skeleton(requester: requester)
                } catch {
                    resultString = "error: \(error)"
                }
                

                
            }
            return .string(resultString)
        })
        

        
        await addInterceptForSet(requester: owner, key: "addReference", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "addReference", for: requester) {
                print("orchestrator set. Keypath: \(keypath) value: \(try value.jsonString())")
                
                guard case let  .object(paramObject) = value else {
                    throw SetValueError.paramErr
                }
                
                guard let referenceValue = paramObject["reference"] else {
                    throw SetValueError.noParamValue("queryPath")
                }
                
                guard case let .cellReference(cellReference) = referenceValue else {
                    throw SetValueError.paramErr
                }
                try await self.addCellReference(cellReference, requester: requester)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: requester)
                
                return .string("ok")
                
            }
            return nil
        })
        
        await addInterceptForSet(requester: owner, key: "addConfiguration", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "addConfiguration", for: requester) {
                print("orchestrator set. Keypath: \(keypath) value: \(try value.jsonString())")
                
   
//                guard case let .cellConfiguration(cellConfig) = value else {
//                    throw SetValueError.paramErr
//                }
//                
                let cellConfig = try JSONDecoder().decode(CellConfiguration.self, fromString: value.jsonString())
                
                try await self.addCellConfiguration(cellConfig, requester: requester)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: requester)
                
                return .string("ok")
                
            }
            return nil
        })
        
        await addInterceptForSet(requester: owner, key: "setConfiguration", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "setConfiguration", for: requester) {
                print("orchestrator set. Keypath: \(keypath) value: \(try value.jsonString())")
                
   
//                guard case let .cellConfiguration(cellConfig) = value else {
//                    throw SetValueError.paramErr
//                }
//
                let cellConfig = try JSONDecoder().decode(CellConfiguration.self, fromString: value.jsonString())
                
                try await self.setCellConfiguration(cellConfig: cellConfig)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: requester)
                
                return .string("ok")
                
            }
            return nil
        })
        
        await addInterceptForGet(requester: owner, key: "outwardMenu", getValueIntercept:  {
            [weak self] keypath, requester  in
            guard let self = self else { return .string("failure")}
            var resultString = "denied"
            if await self.validateAccess("r---", at: "outwardMenu", for: requester) {
                do {
                    let configurationValue = try await self.buildOutwardMenu()
                    return configurationValue
                } catch {
                    print("Building outward menu failed with error: \(error)")
                }
            }
            return .string(resultString)
        })
        
        await addInterceptForGet(requester: owner, key: "historyMenu", getValueIntercept:  {
            [weak self] keypath, requester  in
            guard let self = self else { return .string("failure")}
            var resultString = "denied"
            if await self.validateAccess("r---", at: "historyMenu", for: requester) {
                do {
                    let configurationValue = try await self.buildCellHistoryMenu()
                    return configurationValue
                } catch {
                    print("Building history menu failed with error: \(error)")
                }
            }
            return .string(resultString)
        })
    }
    
    /*
     Load some template to setup the layout
     
     
     */
    
    enum CodingKeys: CodingKey {
        case cellConfig
        case generalCell
    }
    
    deinit {
        print("############# deiniting orchestrator (\(self.uuid) ################")
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cellConfiguration = try container.decode(CellConfiguration.self, forKey: .cellConfig)
        let superDecoder = try container.superDecoder()
        try super.init(from: superDecoder)
    }
    
    override func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
//      try container.encode(label, forKey: .label)
      
      let baseEncoder = container.superEncoder(forKey: .generalCell) // TODO: Look into where this should reside
      try super.encode(to: baseEncoder)
    }
    
    
    // This is unsafe - we must check permissions TODO: check permissions
    func setCellConfiguration(cellConfig: CellConfiguration) async throws {
        if let cellConfiguration = self.cellConfiguration {
            self.cellConfigurationHistory.append(cellConfiguration)
        }
        self.cellConfiguration = cellConfig
        try await self.saveCellConfiguration()
    }
    
    // Also unsafe
    func getCellConfiguration() -> CellConfiguration? {
        return self.cellConfiguration
    }
    

    func executeCellConfiguration(requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        guard let cellConfiguration = cellConfiguration else {
            throw OrchestratorError.noConfiguration
        }
        _ = try await resolver.loadCell(from: cellConfiguration, into: self, requester: requester)
    }
    
    func addCellReference(_ reference: CellReference, requester: Identity) async throws {
        self.cellConfiguration?.addReference(reference)
        
        try await self.executeCellConfiguration(requester: requester) // Should work fine to load the whole config
        
        try await self.saveCellConfiguration()
    }
    
    func addCellConfiguration(_ config: CellConfiguration, requester: Identity) async throws {
        if let references = config.cellReferences {
            for reference in references {
                self.cellConfiguration?.addReference(reference)
            }
            try await self.executeCellConfiguration(requester: requester) // Should work fine to load the whole config
            
            try await self.saveCellConfiguration()
        }
    }
    
    func removeCellReference(_ reference: CellReference, requester: Identity) async throws {
        self.cellConfiguration?.removeReference(reference)
        self.detach(label: reference.label, requester: requester)
        
        try await self.executeCellConfiguration(requester: requester) // Should work fine to load the whole config
        try await self.saveCellConfiguration()
    }
    
    private func saveCellConfiguration() async throws {
        if let cellConfiguration = self.cellConfiguration {
            let encoder = JSONEncoder()
            let cellConfigurationData = try encoder.encode(cellConfiguration)
            
            try await self.writeFileDataInCellDirectory(fileData: cellConfigurationData, filename: cellConfigurationFilename)
        }
    }
    
    private func loadCellConfiguration(requester: Identity) async throws {
        print("++++++++++ Load cell configuration ++++++++++++++")
        var cellConfigurationData = Data()
        do {
            cellConfigurationData = try await self.getFileDataInCellDirectory(filename: cellConfigurationFilename)
//            print("Cell configuration:\n\(String(describing: String(data:cellConfigurationData, encoding: .utf8 )))")
        } catch {
            print("Getting cell configuration file data failed with error: \(error)")
            let encoder = JSONEncoder()
            var eventEmitterReference = CellReference(endpoint: "cell:///EventEmitter", label: "eventTest") //
            eventEmitterReference.addKeyAndValue(KeyValue(key: "start", value: nil))
            
            self.cellConfiguration = CellConfiguration(name: "Preview", cellReferences:   [eventEmitterReference])
            
            let cellConfigurationData = try encoder.encode(self.cellConfiguration)
            
            try await self.writeFileDataInCellDirectory(fileData: cellConfigurationData, filename: cellConfigurationFilename)
            
            try await self.executeCellConfiguration(requester: requester)
        }
        let decoder = JSONDecoder()
        self.cellConfiguration = try decoder.decode(CellConfiguration.self, from: cellConfigurationData)
    }
    
    
    
    private func skeleton(requester: Identity) async throws -> String {
//        var pageObject: Object = [:]
//        try await self.updateConnectionStatuses(requester: requester)
//        pageObject["connections"] = self.connectionStatusValues
//        print("skeleton connections: \(self.connectionStatusValues)")
//        
//        pageObject["outwardMenu"] = await .list( try self.buildOutwardMenu(requester: requester) )
//        
//        let pageSkeleton =  try await self.wrapWithLeafTemplate(jsonObject: pageObject, leafName: "feedplayerwidgettest2")
//        
        return "pageSkeleton"
    }
    

    
    private func buildOutwardMenuCellConfigurations() {
        var menuItems = Object()
        
        var cellReference1 = CellReference(endpoint: "cell:///TimesWrapper", label: "times")
//        cellReference1.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration1 = CellConfiguration(name: "Times", cellReferences: [cellReference1])
        
        
        var cellReference2 = CellReference(endpoint: "cell:///EntitiesWrapper", label: "entities")
//        cellReference2.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration2 = CellConfiguration(name: "Entities", cellReferences: [cellReference2])
        
        var cellReference3 = CellReference(endpoint: "cell:///LocationsWrapper", label: "locations")
//        cellReference3.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration3 = CellConfiguration(name: "Locations", cellReferences: [cellReference3])
        
        menuItems[cellConfiguration1.uuid] = .cellConfiguration(cellConfiguration1)
        menuItems[cellConfiguration2.uuid] = .cellConfiguration(cellConfiguration2)
        menuItems[cellConfiguration3.uuid] = .cellConfiguration(cellConfiguration3)
     
        self.outwardMenuCellConfigurations = menuItems
    }
    
    func updateConnectionStatuses(requester: Identity) async throws {
        
         let connectedLabels = await self.connectedLabels(requester: requester)
        print("Connected labels: \(connectedLabels)")
        self.connectionStatuses.removeAll()
        for currentLabel in connectedLabels {
            let currentConnectionStatus = try await self.attachedStatus(for: currentLabel, requester: requester)
            self.connectionStatuses.append(currentConnectionStatus)
        }
        
        print("Connection Statuses: \(self.connectionStatuses)")
    }
    
    func saveNamedEmitters(requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
//        resolver.
        
        let encoder = JSONEncoder()
        let namedCells = await resolver.namedCells(requester: requester)
        let namedCellsData = try encoder.encode(namedCells)
        print("Saving named cells: \(String(describing: String(data: namedCellsData, encoding: .utf8)))")
        
        try await self.writeFileDataInCellDirectory(fileData: namedCellsData, filename: namedEmittersFilename)
    }
    
    func loadNamedEmitters(requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        let namedEmittersData = try await self.getFileDataInCellDirectory(filename: namedEmittersFilename)
        let decoder = JSONDecoder()
        let namedEmitters = try decoder.decode([String : String].self, from: namedEmittersData)
        
        guard let documentRootPath = CellBase.documentRootPath else {
           throw  CellBaseError.noTargetMeddleCell // Change to noDocumentRoot - when its in the lib
        }
        let docDirURL = URL(fileURLWithPath: CellBase.documentRootPath!)
//        print("@@@@@@@@ CellBase.documentDirectory: \(String(describing: CellBase.documentRootPath)) @@@@@@@@")
        var validatedNamedCells = [String : String]()
        var reversedNamedCells = [String : String]()
        for (name, uuid) in namedEmitters {
           print("(\(name),\(uuid))")
            let cellDirURL = docDirURL.appending(path: uuid)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: cellDirURL.path()) {
                validatedNamedCells[name] = uuid
                reversedNamedCells[uuid] = name
            }
//            if CFileUtils.directoryExists(cellDirURL.path()) {
//                validatedNamedCells[name] = uuid
//                reversedNamedCells[uuid] = name
//            }
            // 1. check if uuid exists on disk (or other storage)
        }
        await resolver.setNamedCells(validatedNamedCells, requester: requester)
    }
    
    
    func buildOutwardMenu() async throws -> ValueType {
//        let cellConfigurations = try await SkeletonDescriptions.menuConfigurations()
//        var cellConfigurationValueList = ValueTypeList()
//        for currentConfiguration in cellConfigurations {
//            let confValue = ValueType.cellConfiguration(currentConfiguration)
//            cellConfigurationValueList.append(confValue)
//        }
//        return .list(cellConfigurationValueList)
        return .string("Not implemented")
    }
    
    func buildCellHistoryMenu() async throws -> ValueType {
        var cellConfigurationValueList = ValueTypeList()
        for currentConfiguration in self.cellConfigurationHistory {
            let confValue = ValueType.cellConfiguration(currentConfiguration)
            cellConfigurationValueList.append(confValue)
        }
        return .list(cellConfigurationValueList)
    }
    
    func loadIdentityNamedEmitters(requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        let identityamedEmittersData = try await self.getFileDataInCellDirectory(filename: identityNamedEmittersFilename)
        let decoder = JSONDecoder()
        
        let identityNamedEmitters = try decoder.decode([String : [String : String]].self, from: identityamedEmittersData)
        
//        let docDirURL = CellVapor.getCellsDocumentsDirectory()
//

        print("Identity Named emitters: \(identityNamedEmitters)")

        
        await resolver.setIdentityNamedCells(identityNamedEmitters, requester: requester)
        
    }
    
    func saveIdentityNamedEmitters(requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
//        resolver.
        
        let encoder = JSONEncoder()
        let identityNamedCells = await resolver.identityNamedCells(requester: requester)
        let identityNamedCellsData = try encoder.encode(identityNamedCells)
        print("Saving identity named cells: \(String(describing: String(data: identityNamedCellsData, encoding: .utf8)))")
        
        try await self.writeFileDataInCellDirectory(fileData: identityNamedCellsData, filename: identityNamedEmittersFilename)
    }
}

