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
public class OrchestratorCell: GeneralCell {
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
    
    
    public required init(owner: Identity) async {
        await super.init(owner: owner)
        print("Orchestrator (Porthole apple) cell init")
        
//        self.name = "Porthole"
        
        
        
        do {
            try await loadNamedEmitters()
        } catch {
            print("Initial loading of namedEmitters failed with error: \(error) uuid: ")
            try? await self.saveNamedEmitters()
        }
        do {
            try await loadIdentityNamedEmitters()
                } catch {
                    print("Initial loading of identityNamedEmitters failed with error: \(error) uuid: ")
                    try? await self.saveIdentityNamedEmitters()
                }
        do {
            try await loadStoredCellConfiguration()
        } catch {
            print("Initial loading of cellConfiguration failed with error(1): \(error) uuid: ")
            
        }
        
        buildOutwardMenuCellConfigurations()
        
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }
    
    private func setupPermissions(owner: Identity) async  {
        self.agreementTemplate.addGrant("r---", for: "skeleton")
        self.agreementTemplate.addGrant("r---", for: "connectedCellEmitters")
        self.agreementTemplate.addGrant("r---", for: "flow")
        
    }
    
    private func setupKeys(owner: Identity) async  {
        
        await addIntercept(requester: owner, intercept: { [weak self] flowElement, requester in
            
            guard let self = self else { return nil }
            print("Incoming flowElement to orchestrator cell: \(flowElement.title) label: \(flowElement.topic)")
            if let type = flowElement.properties?.type {
                
                switch type {
                case .event:
                    print("Orchestrator Got event")
                    switch flowElement.topic {
                    case "register":
                        if case .string(let string) = flowElement.content {
                            if string == "registered_named_cell" {
                                do {
                                    try await self.saveNamedEmitters()
                                } catch {
                                    print("Saving named emitters failed with error: \(error)")
                                }
                            } else if string == "registered_identity_named_cell" {
                                do {
                                    try await self.saveIdentityNamedEmitters()
                                } catch {
                                    print("Saving named emitters failed with error: \(error)")
                                }
                            }
                        }
                        return flowElement // Should we stop all or forward? hmmmm...
                        
                    case "clean":
                        print("Orchestrator got event with topic clean")
                    default:
                        return flowElement
                    }
                
                default: // just forward the flow element
                    return flowElement
                
                }
            }
            return nil
        })
        
        
        await addInterceptForGet(requester: owner, key: "skeleton", getValueIntercept:  {
            [weak self] keypath, requester  in
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
                try await self.addCellReference(cellReference)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: owner)
                
                return .string("ok")
                
            }
            return nil
        })
        
        await addInterceptForSet(requester: owner, key: "addConfiguration", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            if await self.validateAccess("r---", at: "addConfiguration", for: requester) {
                print("orchestrator set. Keypath: \(keypath) value: \(try value.jsonString())")
                
                
                let cellConfig = try JSONDecoder().decode(CellConfiguration.self, fromString: value.jsonString())
                
                try await self.addCellConfiguration(cellConfig)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: owner)
                
                return .string("ok")
                
            }
            return nil
        })
        
        await addInterceptForSet(requester: owner, key: "setConfiguration", setValueIntercept:  {
            [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
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
                
                self.pushFlowElement(flowElement, requester: owner)
                
                return .string("ok")
                
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
        try super.init(from: decoder)
        
        Task {
            if let vault = CellBase.defaultIdentityVault,
               let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
                await setupPermissions(owner: requester)
                await setupKeys(owner: requester)
            }
            
            do {
                try await loadNamedEmitters()
            } catch {
                print("Initial loading of namedEmitters failed with error: \(error) uuid: ")
                try? await self.saveNamedEmitters()
            }
            do {
                try await loadIdentityNamedEmitters()
                    } catch {
                        print("Initial loading of identityNamedEmitters failed with error: \(error) uuid: ")
                        try? await self.saveIdentityNamedEmitters()
                    }
            do {
                try await loadStoredCellConfiguration()
            } catch {
                print("Initial loading of cellConfiguration failed with error (2): \(error) uuid: ")
                
            }
        }
        print("Orchestrator")
    }
    
    public override func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
//      try container.encode(label, forKey: .label)
      
//      let baseEncoder = container.superEncoder(forKey: .generalCell) // TODO: Look into where this should reside
//      try super.encode(to: baseEncoder)
        try super.encode(to: encoder)
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

    func executeCellConfiguration() async throws {
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            try await executeCellConfiguration(requester: requester)
        }
    }
    
    func addCellReference(_ reference: CellReference) async throws {
        self.cellConfiguration?.addReference(reference)
        
        try await self.executeCellConfiguration() // Should work fine to load the whole config
        
        try await self.saveCellConfiguration()
    }

    public func loadCellConfiguration(_ configuration: CellConfiguration, requester: Identity) async throws {
        let previousConfiguration = self.cellConfiguration
        self.detachAll(requester: requester)

        do {
            guard let resolver = CellBase.defaultCellResolver else {
                throw CellBaseError.noResolver
            }
            _ = try await resolver.loadCell(from: configuration, into: self, requester: requester)
            self.cellConfiguration = configuration
            try await self.saveCellConfiguration()
        } catch {
            self.detachAll(requester: requester)
            if let previousConfiguration {
                self.cellConfiguration = previousConfiguration
                try? await self.executeCellConfiguration(requester: requester)
            } else {
                self.cellConfiguration = nil
            }
            throw error
        }
    }
    
    func addCellConfiguration(_ config: CellConfiguration) async throws {
        if let references = config.cellReferences {
            for reference in references {
                self.cellConfiguration?.addReference(reference)
            }
            try await self.executeCellConfiguration() // Should work fine to load the whole config
            
            try await self.saveCellConfiguration()
        }
    }
    
    func removeCellReference(_ reference: CellReference) async throws {
        self.cellConfiguration?.removeReference(reference)
        
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            self.detach(label: reference.label, requester: requester)
        }
        
        
        try await self.executeCellConfiguration() // Should work fine to load the whole config
        try await self.saveCellConfiguration()
    }
    
    private func saveCellConfiguration() async throws {
        if let cellConfiguration = self.cellConfiguration {
            let encoder = JSONEncoder()
            let cellConfigurationData = try encoder.encode(cellConfiguration)
            
            try await self.writeFileDataInCellDirectory(fileData: cellConfigurationData, filename: cellConfigurationFilename)
        }
    }
    
    private func loadStoredCellConfiguration() async throws {
        print("++++++++++ Load cell configuration ++++++++++++++")
        var cellConfigurationData = Data()
        do {
            cellConfigurationData = try await self.getFileDataInCellDirectory(filename: cellConfigurationFilename)
//            print("Cell configuration:\n\(String(describing: String(data:cellConfigurationData, encoding: .utf8 )))")
        } catch {
            print("Getting cell configuration file data failed with error: \(error)")
            let encoder = JSONEncoder()
//            var eventEmitterReference = CellReference(endpoint: "cell:///EventEmitter", label: "eventTest") //
//            eventEmitterReference.addKeyAndValue(KeyValue(key: "start", value: nil))
//            
//            self.cellConfiguration = CellConfiguration(name: "Preview", cellReferences:   [eventEmitterReference])
//
            self.cellConfiguration = try await loadSkeletonExamples().first
            let cellConfigurationData = try encoder.encode(self.cellConfiguration)
            
            try await self.writeFileDataInCellDirectory(fileData: cellConfigurationData, filename: cellConfigurationFilename)
            
            try await self.executeCellConfiguration()
        }
        print("about to decode cellConfigurationData: \(String(describing: String(data: cellConfigurationData, encoding: .utf8)))")
        let decoder = JSONDecoder()
        var decodedConfiguration = try decoder.decode(CellConfiguration.self, from: cellConfigurationData)
        if migrateLegacyTextToSpeechReferenceIfNeeded(in: &decodedConfiguration) {
            self.cellConfiguration = decodedConfiguration
            try await self.saveCellConfiguration()
        } else {
            self.cellConfiguration = decodedConfiguration
        }
        print("Got configuration: \(String(describing: String(data: cellConfigurationData, encoding: .utf8)))")
    }

    private func migrateLegacyTextToSpeechReferenceIfNeeded(in configuration: inout CellConfiguration) -> Bool {
        guard configuration.name == "Hello World",
              var references = configuration.cellReferences,
              references.contains(where: { $0.endpoint == "cell:///TextToSpeech" && $0.label == "tts" })
        else {
            return false
        }

        references.removeAll { $0.endpoint == "cell:///TextToSpeech" && $0.label == "tts" }
        configuration.cellReferences = references.isEmpty ? nil : references
        return true
    }
    
    
    private func loadSkeletonExamples() async throws -> [CellConfiguration] {
        let filename = "SkeletonExamples.json"
        do {
            // Try reading existing file
            let data = try await self.getFileDataInCellDirectory(filename: filename)
            let decoder = JSONDecoder()
            return try decoder.decode([CellConfiguration].self, from: data)
        } catch {
            // Seed with default examples if file is missing or unreadable
            var defaults = [CellConfiguration]()
            // Example 1: Simple Text
            var conf1 = CellConfiguration(name: "Hello World")
            conf1.skeleton = .Text(SkeletonText(text: "Hello World"))
            defaults.append(conf1)
            // Example 2: VStack with Image and Text
            var conf2 = CellConfiguration(name: "Logo + Text")
            var img = SkeletonImage(name: "Haven_logo_cropped")
            img.resizable = true
            img.scaledToFit = true
            let vstack = SkeletonVStack(elements: [
                .Image(img),
                .Text(SkeletonText(text: "Welcome to Skeleton Examples"))
            ])
            conf2.skeleton = .VStack(vstack)
            defaults.append(conf2)
            // Example 3: Reference + Buttons (scanner)
            var conf3 = CellConfiguration(name: "Scanner Demo")
            var scannerRef = CellReference(endpoint: "cell:///EntityScanner", label: "scanner")
            scannerRef.addKeyAndValue(KeyValue(key: "start"))
            conf3.addReference(scannerRef)
            var refSkel = SkeletonCellReference(keypath: "scanner", topic: "scanner")
            var flowEls = SkeletonElementList()
            flowEls.append(.Text(SkeletonText(text: "Scanner")))
            flowEls.append(.Text(SkeletonText(keypath: ".")))
            let refStack = SkeletonVStack(elements: flowEls)
            refSkel.flowElementSkeleton = refStack
            conf3.skeleton = .Reference(refSkel)
            defaults.append(conf3)
            // Write defaults to file
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(defaults)
            try await self.writeFileDataInCellDirectory(fileData: data, filename: filename)
            print("Seeded \(filename) with \(defaults.count) configurations")
            return defaults
        }
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
        
        self.connectionStatuses = try await self.attachedStatuses(requester: requester)
        
        
        print("Connection Statuses (OrchestratorCell): \(self.connectionStatuses)")
    }
    
    func saveNamedEmitters() async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
//        resolver.
        
        let encoder = JSONEncoder()
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            let namedCells = await resolver.namedCells(requester: requester)
            let namedCellsData = try encoder.encode(namedCells)
            print("Saving named cells: \(String(describing: String(data: namedCellsData, encoding: .utf8)))")
            
            try await self.writeFileDataInCellDirectory(fileData: namedCellsData, filename: namedEmittersFilename)
        }
        
        
    }
    
    func loadNamedEmitters() async throws {
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
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            await resolver.setNamedCells(validatedNamedCells, requester: requester)
        }
    }
    
    
    func buildOutwardMenu() async throws -> ValueType {
        var configurations: [CellConfiguration] = []
        do {
            // Prefer configurations from the cell's directory
            configurations = try await loadSkeletonExamples()
            print("Loaded SkeletonExamples.json with \(configurations.count) configurations")
        } catch {
            // Fallback to existing hardcoded menu configurations
            print("Loading SkeletonExamples.json failed with error: \(error). Falling back to SkeletonDescriptions.menuConfigurations().")
            configurations = try await SkeletonDescriptions.menuConfigurations()
        }
        var cellConfigurationValueList = ValueTypeList()
        for currentConfiguration in configurations {
            let confValue = ValueType.cellConfiguration(currentConfiguration)
            cellConfigurationValueList.append(confValue)
        }
        return .list(cellConfigurationValueList)
    }
    
    func buildCellHistoryMenu() async throws -> ValueType {
        var cellConfigurationValueList = ValueTypeList()
        for currentConfiguration in self.cellConfigurationHistory {
            let confValue = ValueType.cellConfiguration(currentConfiguration)
            cellConfigurationValueList.append(confValue)
        }
        return .list(cellConfigurationValueList)
    }
    
    func loadIdentityNamedEmitters() async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        let identityamedEmittersData = try await self.getFileDataInCellDirectory(filename: identityNamedEmittersFilename)
        let decoder = JSONDecoder()
        
        let identityNamedEmitters = try decoder.decode([String : [String : String]].self, from: identityamedEmittersData)
        
//        let docDirURL = CellVapor.getCellsDocumentsDirectory()
//

        print("Identity Named emitters: \(identityNamedEmitters)")

        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            await resolver.setIdentityNamedCells(identityNamedEmitters, requester: requester)
        }
    }
    
    func saveIdentityNamedEmitters() async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw CellBaseError.noResolver
        }
        
//        resolver.
        if let vault = CellBase.defaultIdentityVault,
           let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
            let encoder = JSONEncoder()
            let identityNamedCells = await resolver.identityNamedCells(requester: requester)
            let identityNamedCellsData = try encoder.encode(identityNamedCells)
            print("Saving identity named cells: \(String(describing: String(data: identityNamedCellsData, encoding: .utf8)))")
            
            try await self.writeFileDataInCellDirectory(fileData: identityNamedCellsData, filename: identityNamedEmittersFilename)
        }
    }
}
