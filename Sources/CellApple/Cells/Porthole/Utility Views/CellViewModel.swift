// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  CellViewModel.swift
//  HAVEN_MVP
//
//  Created by Kjetil Hustveit on 17/10/2024.
//

import CellBase
import Combine

class CellViewModel: ObservableObject {
    @Published var flowElements = [FlowElement]()
    var cellConfiguration: CellConfiguration
    var rootCell: GeneralCell? = nil
    var flowLimit = 10
    var flowCancellable: AnyCancellable?
    
    init(cellConfiguration: CellConfiguration) {
        self.cellConfiguration = cellConfiguration
    }
    
    
    
//    private var cellResolversInitialized = false
//    private func setupCellResolvers() async { // For getting preview to work
//        if self.cellResolversInitialized == false {
//            flowElements.append(FlowElement(title: "Test", content: .string("test"), properties: FlowElement.Properties(type: .content, contentType: .string)))
//            do {
//                let identityVault = IdentityVault.shared
//                _ = await identityVault.initialize()
//                CellBase.sendDataAsText = true
//                CellBase.defaultIdentityVault = identityVault
//                
//                let resolver = CellResolver.sharedInstance
//                CellBase.defaultCellResolver = resolver
//                try await resolver.registerTransport(AppleBridgeTransport.self, for: "ws")
//                try await resolver.addCellResolve(name: "EventEmitter", cellScope: .template, identityDomain: "private", type: EventEmitterCell.self)
//                
//                self.cellResolversInitialized = true
//            } catch {
//                print("setup cell resolvers failed with error: \(error) ")
//            }
//        }
//    }
    func setCellConfiguration(_ cellConfig: CellConfiguration) {
        print("******** Setting cell configuration in view **********")
        Task {
            if rootCell == nil {
                rootCell = await GeneralCell()
            }
            let resolver = CellBase.defaultCellResolver
            let vault = CellBase.defaultIdentityVault
            guard let requester = await vault?.identity(for: "private", makeNewIfNotFound: true) else  {
                print("Error! setCellConfiguration got no private identity")
                return
            }
                do {
                    _ = try await resolver?.loadCell(from: cellConfig, into: rootCell!, requester: requester)
                } catch {
                    print("set cell config failed: \(error)")
                }
            
                do {
                    flowCancellable = try await self.rootCell?.flow(requester: requester)
                        .sink(receiveCompletion: { completion in
                            print("Porthole flow got completion: \(completion)")
                            self.flowCancellable = nil
                        }) { [weak self] flowElement in
                            
                            self?.appendFlowELement(flowElement)
                        }
                } catch {
                    print("starting feed failed with error: \(error)" )
                }
        }
    }
    func appendFlowELement(_ flowElement: FlowElement) {
//            print("Appending flow element: \(flowElement) elements: \(flowElements.count)")
        self.flowElements.insert(flowElement, at: 0)
        if self.flowElements.count > flowLimit {
            self.flowElements.removeLast()
        }
    }
}
