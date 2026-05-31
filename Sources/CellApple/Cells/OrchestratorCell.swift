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
        CellBase.diagnosticLog("Orchestrator (Porthole apple) cell init", domain: .lifecycle)
        
//        self.name = "Porthole"
        
        
        
        do {
            try await loadNamedEmitters()
        } catch {
            CellBase.diagnosticLog("Initial loading of namedEmitters failed with error: \(error)", domain: .resolver)
            try? await self.saveNamedEmitters()
        }
        do {
            try await loadIdentityNamedEmitters()
                } catch {
                    CellBase.diagnosticLog("Initial loading of identityNamedEmitters failed with error: \(error)", domain: .resolver)
                    try? await self.saveIdentityNamedEmitters()
                }
        do {
            try await loadStoredCellConfiguration()
        } catch {
            CellBase.diagnosticLog("Initial loading of cellConfiguration failed with error: \(error)", domain: .skeleton)
            
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
            CellBase.diagnosticLog("Incoming flowElement to orchestrator cell: \(flowElement.title) label: \(flowElement.topic)", domain: .flow)
            if let type = flowElement.properties?.type {
                
                switch type {
                case .event:
                    CellBase.diagnosticLog("Orchestrator got event topic=\(flowElement.topic)", domain: .flow)
                    switch flowElement.topic {
                    case "register":
                        if case .string(let string) = flowElement.content {
                            if string == "registered_named_cell" {
                                do {
                                    try await self.saveNamedEmitters()
                                } catch {
                                    CellBase.diagnosticLog("Saving named emitters failed with error: \(error)", domain: .resolver)
                                }
                            } else if string == "registered_identity_named_cell" {
                                do {
                                    try await self.saveIdentityNamedEmitters()
                                } catch {
                                    CellBase.diagnosticLog("Saving identity named emitters failed with error: \(error)", domain: .resolver)
                                }
                            }
                        }
                        return flowElement // Should we stop all or forward? hmmmm...
                        
                    case "clean":
                        CellBase.diagnosticLog("Orchestrator got event with topic clean", domain: .flow)
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
                CellBase.diagnosticLog("Orchestrator set addReference keypath=\(keypath)", domain: .skeleton)
                
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
            if await self.validateAccess("-w--", at: "addConfiguration", for: requester) {
                CellBase.diagnosticLog("Orchestrator set addConfiguration keypath=\(keypath)", domain: .skeleton)

                guard let cellConfig = await CellConfigurationPayloadSupport.resolveCellConfiguration(
                    from: value,
                    requester: requester,
                    candidates: self.availableCellConfigurationCandidates()
                ) else {
                    return .string("error: invalid payload for addConfiguration")
                }

                try await self.loadCellConfiguration(cellConfig, requester: requester)
                
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
            if await self.validateAccess("-w--", at: "setConfiguration", for: requester) {
                CellBase.diagnosticLog("Orchestrator set setConfiguration keypath=\(keypath)", domain: .skeleton)

                guard let cellConfig = await CellConfigurationPayloadSupport.resolveCellConfiguration(
                    from: value,
                    requester: requester,
                    candidates: self.availableCellConfigurationCandidates()
                ) else {
                    return .string("error: invalid payload for setConfiguration")
                }

                try await self.loadCellConfiguration(cellConfig, requester: requester)
                
                var flowElement = FlowElement(title: "Orchestrator update", content: .string("refresh"), properties: FlowElement.Properties(type: .event, contentType: .string))
                flowElement.topic = "porthole"
                flowElement.origin = self.uuid
                
                self.pushFlowElement(flowElement, requester: owner)
                
                return .string("ok")
            }
            return nil
        })
        
        await addInterceptForGet(requester: owner, key: "outwardMenu", getValueIntercept:  {
            [weak self] keypath, requester  in
            guard let self = self else { return .string("failure")}
            if await self.validateAccess("r---", at: "outwardMenu", for: requester) {
                do {
                    let configurationValue = try await self.buildOutwardMenu()
                    return configurationValue
                } catch {
                    CellBase.diagnosticLog("Building outward menu failed with error: \(error)", domain: .skeleton)
                }
            }
            return .string("denied")
        })
        
        await addInterceptForGet(requester: owner, key: "historyMenu", getValueIntercept:  {
            [weak self] keypath, requester  in
            guard let self = self else { return .string("failure")}
            if await self.validateAccess("r---", at: "historyMenu", for: requester) {
                do {
                    let configurationValue = try await self.buildCellHistoryMenu()
                    return configurationValue
                } catch {
                    CellBase.diagnosticLog("Building history menu failed with error: \(error)", domain: .skeleton)
                }
            }
            return .string("denied")
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
        CellBase.diagnosticLog("Deinitializing orchestrator \(self.uuid)", domain: .lifecycle)
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        Task {
            let decodedOwner = self.storedOwnerIdentity
            await setupPermissions(owner: decodedOwner)
            await setupKeys(owner: decodedOwner)
            
            do {
                try await loadNamedEmitters()
            } catch {
                CellBase.diagnosticLog("Initial loading of namedEmitters failed with error: \(error)", domain: .resolver)
                try? await self.saveNamedEmitters()
            }
            do {
                try await loadIdentityNamedEmitters()
                    } catch {
                        CellBase.diagnosticLog("Initial loading of identityNamedEmitters failed with error: \(error)", domain: .resolver)
                        try? await self.saveIdentityNamedEmitters()
                    }
            do {
                try await loadStoredCellConfiguration()
            } catch {
                CellBase.diagnosticLog("Initial loading of cellConfiguration failed with error: \(error)", domain: .skeleton)
                
            }
        }
        CellBase.diagnosticLog("Decoded Orchestrator", domain: .lifecycle)
    }
    
    public override func encode(to encoder: Encoder) throws {
//      try container.encode(label, forKey: .label)
      
//      let baseEncoder = container.superEncoder(forKey: .generalCell) // TODO: Look into where this should reside
//      try super.encode(to: baseEncoder)
        try super.encode(to: encoder)
    }
    
    
    // Local UI snapshot; external access must go through Resolver/Meddle policy.
    func getCellConfiguration() -> CellConfiguration? {
        return self.cellConfiguration
    }

    private func availableCellConfigurationCandidates() -> [CellConfiguration] {
        var candidates = [CellConfiguration]()
        if let cellConfiguration {
            candidates.append(cellConfiguration)
        }
        candidates.append(contentsOf: cellConfigurationHistory)
        candidates.append(contentsOf: outwardMenuCellConfigurations.values.compactMap {
            CellConfigurationPayloadSupport.decodeCellConfiguration(from: $0)
        })
        return candidates
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
        CellBase.diagnosticLog("Load cell configuration", domain: .skeleton)
        var cellConfigurationData = Data()
        do {
            cellConfigurationData = try await self.getFileDataInCellDirectory(filename: cellConfigurationFilename)
//            print("Cell configuration:\n\(String(describing: String(data:cellConfigurationData, encoding: .utf8 )))")
        } catch {
            CellBase.diagnosticLog("Getting cell configuration file data failed with error: \(error)", domain: .skeleton)
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
        CellBase.diagnosticLog("Decoding stored cell configuration bytes=\(cellConfigurationData.count)", domain: .skeleton)
        let decoder = JSONDecoder()
        var decodedConfiguration = try decoder.decode(CellConfiguration.self, from: cellConfigurationData)
        if migrateLegacyTextToSpeechReferenceIfNeeded(in: &decodedConfiguration) {
            self.cellConfiguration = decodedConfiguration
            try await self.saveCellConfiguration()
        } else {
            self.cellConfiguration = decodedConfiguration
        }
        CellBase.diagnosticLog("Loaded stored cell configuration bytes=\(cellConfigurationData.count)", domain: .skeleton)
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
            CellBase.diagnosticLog("Seeded \(filename) with \(defaults.count) configurations", domain: .skeleton)
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
        
        let cellReference1 = CellReference(endpoint: "cell:///TimesWrapper", label: "times")
//        cellReference1.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration1 = CellConfiguration(name: "Times", cellReferences: [cellReference1])
        
        
        let cellReference2 = CellReference(endpoint: "cell:///EntitiesWrapper", label: "entities")
//        cellReference2.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration2 = CellConfiguration(name: "Entities", cellReferences: [cellReference2])
        
        let cellReference3 = CellReference(endpoint: "cell:///LocationsWrapper", label: "locations")
//        cellReference3.setKeysAndValues = [KeyValue(key: "start", value: nil)]
        let cellConfiguration3 = CellConfiguration(name: "Locations", cellReferences: [cellReference3])
        
        menuItems[cellConfiguration1.uuid] = .cellConfiguration(cellConfiguration1)
        menuItems[cellConfiguration2.uuid] = .cellConfiguration(cellConfiguration2)
        menuItems[cellConfiguration3.uuid] = .cellConfiguration(cellConfiguration3)
     
        self.outwardMenuCellConfigurations = menuItems
    }
    
    func updateConnectionStatuses(requester: Identity) async throws {
        
         let connectedLabels = await self.connectedLabels(requester: requester)
        CellBase.diagnosticLog("Connected labels: \(connectedLabels)", domain: .flow)
        self.connectionStatuses.removeAll()
        
        self.connectionStatuses = try await self.attachedStatuses(requester: requester)
        
        
        CellBase.diagnosticLog("Connection statuses count=\(self.connectionStatuses.count)", domain: .flow)
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
            CellBase.diagnosticLog("Saving named cells count=\(namedCells.count)", domain: .resolver)
            
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
        let docDirURL = URL(fileURLWithPath: documentRootPath)
//        print("@@@@@@@@ CellBase.documentDirectory: \(String(describing: CellBase.documentRootPath)) @@@@@@@@")
        var validatedNamedCells = [String : String]()
        var reversedNamedCells = [String : String]()
        for (name, uuid) in namedEmitters {
            CellBase.diagnosticLog("Validating named cell \(name)=\(uuid)", domain: .resolver)
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
            CellBase.diagnosticLog("Loaded SkeletonExamples.json with \(configurations.count) configurations", domain: .skeleton)
        } catch {
            // Fallback to existing hardcoded menu configurations
            CellBase.diagnosticLog("Loading SkeletonExamples.json failed with error: \(error). Falling back to SkeletonDescriptions.menuConfigurations().", domain: .skeleton)
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
        CellBase.diagnosticLog("Loaded identity named emitters identityCount=\(identityNamedEmitters.count)", domain: .resolver)

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
            CellBase.diagnosticLog("Saving identity named cells identityCount=\(identityNamedCells.count)", domain: .resolver)
            
            try await self.writeFileDataInCellDirectory(fileData: identityNamedCellsData, filename: identityNamedEmittersFilename)
        }
    }
}
