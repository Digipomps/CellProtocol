// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AppInitializer.swift
//  HAVEN_MVP
//
//  Created by Assistant on 19/12/2025.
//

import Foundation
import CellBase

public enum AppInitializer {
    private static let localRuntimeOnlyVerifierFlagPath = "/tmp/binding-verifier-local-runtime.flag"
    private static var didPrepareLocalRuntime = false
    private static var didInitialize = false
    private static var scaffoldCellsDict = [String : String]()
    @MainActor private static var initializationTask: Task<Void, Never>?
    @MainActor private static var localPreparationTask: Task<Void, Never>?
    @MainActor private static var deferredPortholeSetupTask: Task<Void, Never>?
    /// Perform early, one-time app initialization for CellBase defaults.
    /// Call this from your App's init or the first scene's task.
    @MainActor
    public static func prepareLocalRuntime() async {
        if didPrepareLocalRuntime { return }
        if let localPreparationTask {
            await localPreparationTask.value
            return
        }

        let task = Task { @MainActor in
            guard !didPrepareLocalRuntime else {
                localPreparationTask = nil
                return
            }
            print("preparing App local runtime...")
            do {
                let resolver = CellResolver.sharedInstance
                CellBase.sendDataAsText = true
                CellBase.defaultCellResolver = resolver

#if DEBUG
                CellBase.webSocketSecurityPolicy = .developmentOnlyInsecureAllowed
#else
                CellBase.webSocketSecurityPolicy = .requireTLS
#endif

                CellBase.documentRootPath = documentsDirectoryPath()

                if resolver.tcUtility == nil {
                    let tcUtility = TypedCellUtility(storage: FileSystemCellStorage())
                    resolver.tcUtility = tcUtility
                    CellBase.typedCellUtility = tcUtility
                } else if CellBase.typedCellUtility == nil {
                    CellBase.typedCellUtility = resolver.tcUtility
                }

                try await resolver.registerDefaultWebSocketBridgeTransports()

                if CellBase.hostname != "localhost", CellBase.hostname != "" {
                    resolver.registerRemoteCellHost(
                        CellBase.hostname,
                        route: RemoteCellHostRoute(websocketEndpoint: "publishersws", schemePreference: .automatic)
                    )
                }

                try loadScaffoldCellsDict()
                try await registerDefaultCellResolves(on: resolver)
                scheduleDeferredPortholeSetupIfNeeded()

                didPrepareLocalRuntime = true
                print("Finished preparing local CellBase toolchain")
            } catch {
                print("Error when preparing local toolchain. Error: \(error)")
            }
            localPreparationTask = nil
            print("finished preparing App local runtime...")
        }
        localPreparationTask = task
        await task.value
    }

    @MainActor
    public static func initialize() async {
        if shouldUseLocalRuntimeOnlyForVerifier() {
            await prepareLocalRuntime()
            return
        }

        if didInitialize { return }
        if let initializationTask {
            await initializationTask.value
            return
        }

        let task = Task { @MainActor in
            guard !didInitialize else {
                initializationTask = nil
                return
            }
            print("initializing App...")
            do {
                // 1) Identity vault
                let identityVault = IdentityVault.shared
                _ = await identityVault.initialize()
                CellBase.defaultIdentityVault = identityVault
                await prepareLocalRuntime()
                await CellResolver.sharedInstance.refreshNamedResolveOwnersFromCurrentVault()

                // 8) Optionally load default CellConfigurations from a folder (adjust to your environment)
                // if let defaultUrl = URL(string: "file:///Users/Shared/CellsContainer/CellConfigurations/") {
                //     try? loadCellConfigurations(from: defaultUrl)
                // }

                didInitialize = true
                print("Finished configuring CellBase toolchain")
            } catch {
                print("Error when configuring tool. Error: \(error)")
            }
            initializationTask = nil
            print("finished initializing App...")
        }
        initializationTask = task
        await task.value
    }

    private static func shouldUseLocalRuntimeOnlyForVerifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if FileManager.default.fileExists(atPath: localRuntimeOnlyVerifierFlagPath) {
            return true
        }

        guard environment["XCTestConfigurationFilePath"] != nil,
              let mode = environment["BINDING_VERIFIER_IDENTITY_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mode.isEmpty else {
            return false
        }

        switch mode {
        case "startup", "local", "test", "deterministic":
            return true
        default:
            return false
        }
    }

    @MainActor
    private static func registerDefaultCellResolves(on resolver: CellResolver) async throws {
        try await registerResolve(
            on: resolver,
            name: "GeneralCell",
            cellScope: .template,
            identityDomain: "private",
            type: GeneralCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "GeneralCellTemplate",
            cellScope: .template,
            identityDomain: "private",
            type: GeneralCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "CloudBridge",
            cellScope: .template,
            identityDomain: "private",
            type: BridgeBase.self
        )
        try await registerResolve(
            on: resolver,
            name: "EntityAnchor",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: EntityAnchorCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "ShoppingHandler",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: ShoppingHandlerCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "Porthole",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: OrchestratorCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "Perspective",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: PerspectiveCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "Vault",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: VaultCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "GraphIndex",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: GraphIndexCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "FileCrypto",
            cellScope: .template,
            identityDomain: "private",
            type: FileCryptoCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "CommonsResolver",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: CommonsResolverCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "CommonsTaxonomy",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: CommonsTaxonomyCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "EntityAtlas",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: EntityAtlasInspectorCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "FlowProbe",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: FlowProbeCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "StateSnapshot",
            cellScope: .identityUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: StateSnapshotCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "TrustedIssuers",
            cellScope: .scaffoldUnique,
            persistency: .persistant,
            identityDomain: "private",
            type: TrustedIssuerCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "Chat",
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            type: ChatCell.self
        )
        try await registerResolve(
            on: resolver,
            name: "EntityScanner",
            cellScope: .scaffoldUnique,
            identityDomain: "private",
            type: EntityScannerCell.self
        )

        if #available(macOS 26.0, iOS 27.0, tvOS 27.0, watchOS 20.0, *) {
            try await registerResolve(
                on: resolver,
                name: "AppleIntelligence",
                cellScope: .identityUnique,
                persistency: .persistant,
                identityDomain: "private",
                type: AppleIntelligenceCell.self
            )
        } else {
            print("Os not supported for AppleIntelligenceCell")
        }
    }

    @MainActor
    private static func registerResolve<CellType: Emit & OwnerInstantiable>(
        on resolver: CellResolver,
        name: String,
        cellScope: CellUsageScope,
        persistency: Persistancy? = nil,
        identityDomain: String,
        type: CellType.Type
    ) async throws {
        do {
            if let persistency {
                try await resolver.addCellResolve(
                    name: name,
                    cellScope: cellScope,
                    persistency: persistency,
                    identityDomain: identityDomain,
                    type: type
                )
            } else {
                try await resolver.addCellResolve(
                    name: name,
                    cellScope: cellScope,
                    identityDomain: identityDomain,
                    type: type
                )
            }
        } catch {
            let description = String(describing: error).lowercased()
            guard description.contains("duplicatedendpointname")
                    || description.contains("registeratalreadytakenendpoint") else {
                throw error
            }
        }
    }

    @MainActor
    private static func scheduleDeferredPortholeSetupIfNeeded() {
        guard deferredPortholeSetupTask == nil else { return }
        deferredPortholeSetupTask = Task { @MainActor in
            do {
                try await setupPorthole()
            } catch {
                print("Deferred Porthole setup failed with error: \(error)")
            }
        }
    }

    private static func documentsDirectoryPath() -> String {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return urls.first?.path ?? ""
    }
    
    static func loadScaffoldCellsDict() throws {
        let scaffoldCellsDictURL = getDocumentsDirectory().appending(path: "ScaffoldCells.json")
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: scaffoldCellsDictURL.path()) {
            let scaffoldCellsDictJson = try Data(contentsOf: scaffoldCellsDictURL)
            AppInitializer.scaffoldCellsDict = try JSONDecoder().decode([String : String].self, from: scaffoldCellsDictJson)
        }
    }
    
    static func saveScaffoldCellsDict() throws {
        let scaffoldCellsDictJson = try JSONEncoder().encode(self.scaffoldCellsDict)
        try scaffoldCellsDictJson.write(to: getDocumentsDirectory().appending(path: "ScaffoldCells.json"))
    }
    
    static func getDocumentsDirectory() -> URL {
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    static func setupPorthole() async throws {
        print("****** Setup Porthole *****")
            if let identity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true) {
                // Check whether Porthole exists in filesystem
                let resolver = CellResolver.sharedInstance
                
                if let porthole = try await self.getPorthole(identity: identity) {
                    
                    let resolverEmitter = FlowElementPusherCell(owner: identity)
                    try await resolver.setResolverEmitter(resolverEmitter, requester: identity)
                    let status = try await porthole.attach(emitter: resolverEmitter, label: "resolver", requester: identity)
                    
                    if status == .connected {
                        try await porthole.absorbFlow(label: "resolver", requester: identity)
                        
                        let resolverEmitterTestFlowElement = FlowElement(title: "Test Resolver", content: .string("Nothing to see here..."), properties: FlowElement.Properties(type: .content, contentType: .string))
                        
                        resolverEmitter.pushFlowElement(resolverEmitterTestFlowElement, requester: identity)
                    }
//                    self.cockpitCell = porthole
//                    self.selectedAgreement = cockpitCell?.agreementTemplate
                }
                // Make a Identities Cell for handling interactions with identities (never expose identity vaults)
                try await resolver.addCellResolve(name: "Identities", cellScope: .scaffoldUnique, type: IdentitiesCell.self)
            }
        
    }
    
    static func getPorthole(identity: Identity) async throws -> OrchestratorCell? {
        let resolver = CellResolver.sharedInstance
        if let portholeUUID = self.scaffoldCellsDict["Porthole"] {
            
            
            let fileManager = FileManager()
            let portholeURL = getDocumentsDirectory().appending(path: "CellsContainer/\(portholeUUID)")
            
            if fileManager.fileExists(atPath: portholeURL.path()) {
                if let porthole = resolver.tcUtility?.loadTypedEmitCell(at: "CellsContainer/\(portholeUUID)") as? OrchestratorCell {
                    do {
                        try await resolver.registerNamedEmitCell(name: "Porthole", emitCell: porthole, scope: .identityUnique, identity: identity)
                        self.scaffoldCellsDict["Porthole"] = porthole.uuid
                        try self.saveScaffoldCellsDict()
                        print("Porthole loaded as persisted on disk")
                        return porthole
                    } catch {
                        print("Getting porthole from disk failed with error: \(error)")
                    }
                }
            }
            
        }
        if let porthole = try await resolver.cellAtEndpoint(endpoint: "cell:///Porthole", requester: identity) as? OrchestratorCell {
            resolver.tcUtility?.storeAsTypedCell(
                cellName: "OrchestratorCell",
                cell: porthole,
                uuid: porthole.uuid
            )
            try await resolver.registerNamedEmitCell(name: "Porthole", emitCell: porthole, scope: .identityUnique, identity: identity)
            self.scaffoldCellsDict["Porthole"] = porthole.uuid
            try self.saveScaffoldCellsDict()
            print("Porthole loaded as new and pristine")
            return porthole
            
        }
        return nil // or throw?
    }
}
