// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import SwiftUI
import Combine
import CellBase

@MainActor
public final class PortholeBindingViewModel: ObservableObject {
    private static let skeletonRootKeys: Set<String> = [
        "List", "Object", "Spacer", "Image", "Text", "TextField", "TextArea",
        "HStack", "VStack", "Reference", "Button", "Divider", "ScrollView",
        "Section", "ZStack", "Grid", "Toggle"
    ]

    @Published public var currentSkeleton: SkeletonElement = .VStack(
        SkeletonVStack(elements: [
            .Text(SkeletonText(text: "Porthole")),
            .Text(SkeletonText(text: "Slipp en CellConfiguration her, eller bruk menykneppene."))
        ])
    )
    
    @Published public var upperLeftMenu: [CellConfiguration] = []
    @Published public var upperMidMenu: [CellConfiguration] = []
    @Published public var upperRightMenu: [CellConfiguration] = []
    @Published public var lowerLeftMenu: [CellConfiguration] = []
    @Published public var lowerMidMenu: [CellConfiguration] = []
    @Published public var lowerRightMenu: [CellConfiguration] = []
    
    @Published public var cellReferences = [CellReference]()
    @Published  var flowElements = [FlowElement]()
    var flowLimit = 10
    private var flowCancellable: AnyCancellable?

    // Keep a weak reference to the resolved porthole if we find one
    private var portholeEmit: Emit?
    private var portholeMeddle: Meddle?

    public var cache = PortholeCache()
    
    public init() {
        print("PortholeBindingViewModel initialized")
    }
    
    public func connectIfNeeded() async {
        await AppInitializer.prepareLocalRuntime()
        guard let resolver = CellBase.defaultCellResolver as? CellResolver else { return }
        guard let vault = CellBase.defaultIdentityVault else { return }
        
        guard portholeEmit == nil || portholeMeddle == nil else { return }
        guard let identity = await vault.identity(for: "private", makeNewIfNotFound: true) else { return }

        do {
            let cell = try await resolver.cellAtEndpoint(endpoint: "cell:///Porthole", requester: identity)
            self.portholeEmit = cell
            self.portholeMeddle = cell as? Meddle
            if let meddle = self.portholeMeddle {
                await self.interceptGetAndPopulateMenus(using: meddle, identity: identity)
            }

            if let emit = self.portholeEmit {
                let publisher = try await emit.flow(requester: identity)
                self.flowCancellable = publisher
                    .receive(on: DispatchQueue.main)
                    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] element in
                        guard let self else { return }
                        self.appendFlowELement(element)
                        
                        switch element.content {
                        case .object(let obj):
                            if let skeletonObject = Self.extractSkeletonObject(from: obj),
                               let skeleton = try? Self.decodeSkeleton(from: skeletonObject) {
                                self.currentSkeleton = skeleton
                            }
                        default:
                            break
                        }
                    })
            }
        } catch {
            CellBase.diagnosticLog("PortholeBindingViewModel resolve failed: \(error)", domain: .resolver)
        }
    }

    func refreshMenusWithTestData() {
        var configs: [CellConfiguration] = []
        let base = SkeletonDescriptions.skeletonDescriptionFromJson()
        configs.append(base)
        var textConf = CellConfiguration(name: "Eksempel – Tekst")
        textConf.skeleton = .VStack(
            SkeletonVStack(elements: [
                .Text(SkeletonText(text: "Eksempel – Tittel")),
                .Text(SkeletonText(text: "Dette er et eksempel på Skeleton UI."))
            ])
        )
        configs.append(textConf)
        var imageConf = CellConfiguration(name: "Eksempel – Bilde")
        imageConf.skeleton = .Image(SkeletonImage(name: "AppIcon"))
        configs.append(imageConf)

        // Distribute to all edge menus (for now we seed all with the same test data)
        self.upperLeftMenu = configs
        self.upperMidMenu = upperMidMenuConfigs()
        self.upperRightMenu = configs
        self.lowerLeftMenu = configs
        self.lowerMidMenu = lowerMidMenuConfigs()
        self.lowerRightMenu = configs
    }

    private func lowerMidMenuConfigs() -> [CellConfiguration] {
        
     return [AppleIntelligenceDemoConfiguration]
    }
    
    private func upperMidMenuConfigs() -> [CellConfiguration] {
        let jsonString = """
            [
            {
              "cellReferences": [
                {
                  "label": "markedAgent",
                  "subscribeFeed": true,
                  "subscriptions": [],
                  "setKeysAndValues": [],
                  "endpoint": "cell:///ShoppingHandler"
                }
              ],
              "name": "Person Profile",
              "skeleton": {
                "VStack": [
                  {
                    "Image": {
                      "name": "adventurer",
                      "modifiers": {
                        "scaledToFit": true,
                        "padding": 8
                      }
                    }
                  },
                  {
                    "Text": {
                      "text": "Alex Jensen",
                      "modifiers": {
                        "fontStyle": "title2",
                        "fontWeight": "semibold"
                      }
                    }
                  },
                  {
                    "Text": {
                      "text": "Privacy advocate. Building open tools.",
                      "modifiers": {
                        "foregroundColor": "#555555",
                        "padding": 4
                      }
                    }
                  },
                  {
                    "Grid": {
                      "columns": [
                        {
                          "type": "adaptive",
                          "min": 120,
                          "max": 200
                        }
                      ],
                      "elements": [
                        {
                          "Text": {
                            "text": "Interests: Privacy"
                          }
                        },
                        {
                          "Text": {
                            "text": "Location: Oslo"
                          }
                        },
                        {
                          "Text": {
                            "text": "Website: example.org"
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            },
            {
              "cellReferences": [
                {
                  "label": "markedAgent",
                  "subscribeFeed": true,
                  "subscriptions": [],
                  "setKeysAndValues": [],
                  "endpoint": "cell:///ShoppingHandler"
                }
              ],
              "name": "ZStack overlay",
              "skeleton": {
                "ZStack": {
                  "elements": [
                    {
                      "Image": {
                        "name": "Background",
                        "modifiers": {
                          "maxWidthInfinity": true,
                          "maxHeightInfinity": true
                        }
                      }
                    },
                    {
                      "Text": {
                        "text": "Overlay title",
                        "modifiers": {
                          "fontStyle": "title",
                          "foregroundColor": "#FFFFFF",
                          "padding": 16
                        }
                      }
                    }
                  ],
                  "modifiers": {
                    "padding": 12
                  }
                }
              }
            },
            {
              "cellReferences": [
                {
                  "label": "markedAgent",
                  "subscribeFeed": true,
                  "subscriptions": [],
                  "setKeysAndValues": [],
                  "endpoint": "cell:///ShoppingHandler"
                }
              ],
              "name": "Horizontal cards",
              "skeleton": {
                "ScrollView": {
                  "axis": "horizontal",
                  "elements": [
                    {
                      "VStack": [
                        {
                          "Image": {
                            "name": "photo",
                            "modifiers": {
                              "padding": 8
                            }
                          }
                        },
                        {
                          "Text": {
                            "text": "Card A",
                            "modifiers": {
                              "padding": 4
                            }
                          }
                        }
                      ]
                    },
                    {
                      "VStack": [
                        {
                          "Image": {
                            "name": "photo",
                            "modifiers": {
                              "padding": 8
                            }
                          }
                        },
                        {
                          "Text": {
                            "text": "Card B",
                            "modifiers": {
                              "padding": 4
                            }
                          }
                        }
                      ]
                    },
                    {
                      "VStack": [
                        {
                          "Image": {
                            "name": "photo",
                            "modifiers": {
                              "padding": 8
                            }
                          }
                        },
                        {
                          "Text": {
                            "text": "Card C",
                            "modifiers": {
                              "padding": 4
                            }
                          }
                        }
                      ]
                    }
                  ],
                  "modifiers": {
                    "padding": 8
                  }
                }
              }
            }
            ]
            """
        if let configs = self.jsonStringToCellConfigurations(jsonString) {
            return configs
        }
        
        return []
    }
    
    private func jsonStringToCellConfigurations(_ jsonString: String) -> [CellConfiguration]? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            let values: [CellConfiguration] = try JSONDecoder().decode([CellConfiguration].self, from: data)
            return values
        } catch {
            return nil
        }
    }
    
    func interceptGetAndPopulateMenus(using meddle: Meddle, identity: Identity) async {
        // Try to fetch menus from well-known keypaths; fall back to test data
        do {
            if case let .list(values) = try await meddle.get(keypath: "upperLeftMenu", requester: identity) {
                self.upperLeftMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        do {
            if case let .list(values) = try await meddle.get(keypath: "upperMidMenu", requester: identity) {
                self.upperMidMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        do {
            if case let .list(values) = try await meddle.get(keypath: "upperRightMenu", requester: identity) {
                self.upperRightMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        do {
            if case let .list(values) = try await meddle.get(keypath: "lowerLeftMenu", requester: identity) {
                self.lowerLeftMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        do {
            if case let .list(values) = try await meddle.get(keypath: "lowerMidMenu", requester: identity) {
                self.lowerMidMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        do {
            if case let .list(values) = try await meddle.get(keypath: "lowerRightMenu", requester: identity) {
                self.lowerRightMenu = values.compactMap { if case let .cellConfiguration(c) = $0 { return c } else { return nil } }
            }
        } catch { /* ignore and fall back */ }
        if self.upperLeftMenu.isEmpty && self.upperMidMenu.isEmpty && self.upperRightMenu.isEmpty && self.lowerLeftMenu.isEmpty && self.lowerMidMenu.isEmpty && self.lowerRightMenu.isEmpty {
            self.refreshMenusWithTestData()
        }
    }

    public func load(configuration: CellConfiguration?) async {
        guard let configuration = configuration else { return }
        guard let vault = CellBase.defaultIdentityVault else { return }

        if let skeleton = configuration.skeleton {
            self.currentSkeleton = skeleton
        }
        self.cellReferences = configuration.cellReferences ?? []

        guard let porthole = self.portholeMeddle as? OrchestratorCell,
              let identity = await vault.identity(for: "private", makeNewIfNotFound: true) else {
            return
        }

        do {
            try await porthole.loadCellConfiguration(configuration, requester: identity)
        } catch {
            CellBase.diagnosticLog("PortholeBindingViewModel load failed for \(configuration.name): \(error)", domain: .resolver)
        }
    }

    private static func decodeSkeleton(from object: Object) throws -> SkeletonElement {
        let data = try JSONEncoder().encode(object)
        let element = try JSONDecoder().decode(SkeletonElement.self, from: data)
        return element
    }

    private static func extractSkeletonObject(from object: Object) -> Object? {
        if object.keys.contains(where: { skeletonRootKeys.contains($0) }) {
            return object
        }
        if case let .object(nested)? = object["skeleton"],
           nested.keys.contains(where: { skeletonRootKeys.contains($0) }) {
            return nested
        }
        return nil
    }
    
    // En navngitt konfigurasjon for å teste AppleIntelligenceCell fra appen
    // med fokus på prompt -> spørringer mot PerspectiveCell.
    public lazy var AppleIntelligenceDemoConfiguration: CellConfiguration = {
        func modifiers(_ configure: (inout SkeletonModifiers) -> Void) -> SkeletonModifiers {
            var m = SkeletonModifiers()
            configure(&m)
            return m
        }

        let pageModifiers = modifiers {
            $0.padding = 16
            $0.maxWidthInfinity = true
            $0.background = "#EEF3FA"
        }

        let cardModifiers = modifiers {
            $0.padding = 12
            $0.background = "#FFFFFF"
            $0.cornerRadius = 12
            $0.borderWidth = 1
            $0.borderColor = "#D2DCE8"
        }

        let titleModifiers = modifiers {
            $0.fontStyle = "title3"
            $0.fontWeight = "semibold"
            $0.padding = 2
        }

        let mutedTextModifiers = modifiers {
            $0.foregroundColor = "#4B5563"
            $0.padding = 2
        }

        let textFieldModifiers = modifiers {
            $0.padding = 10
            $0.background = "#F8FAFC"
            $0.cornerRadius = 10
            $0.borderWidth = 1
            $0.borderColor = "#CBD5E1"
        }

        let primaryButtonModifiers = modifiers {
            $0.padding = 10
            $0.background = "#0F4C81"
            $0.cornerRadius = 10
            $0.borderWidth = 1
            $0.borderColor = "#0F4C81"
            $0.foregroundColor = "#FFFFFF"
        }

        let secondaryButtonModifiers = modifiers {
            $0.padding = 10
            $0.background = "#E6EEF7"
            $0.cornerRadius = 10
            $0.borderWidth = 1
            $0.borderColor = "#AFC3D8"
        }

        var config = CellConfiguration(name: "Apple Intelligence Prompt Demo")
        config.description = "Test prompt -> AppleIntelligence -> Perspective med enkel Skeleton-visning."

        var reference = CellReference(endpoint: "cell:///AppleIntelligence", label: "intelligence")
        reference.subscribeFeed = true
        config.addReference(reference)

        var title = SkeletonText(text: "Apple Intelligence -> Perspective")
        title.modifiers = titleModifiers

        var intro = SkeletonText(text: "Skriv prompt, send, og følg resultatene i listen under.")
        intro.modifiers = mutedTextModifiers

        let promptField = SkeletonTextField(
            text: nil,
            sourceKeypath: "intelligence.ai.promptText",
            targetKeypath: "intelligence.ai.sendPrompt",
            placeholder: "Eksempel: Finn relevante purpose-kandidater for i dag",
            modifiers: textFieldModifiers
        )

        let instructionsField = SkeletonTextField(
            text: nil,
            sourceKeypath: "intelligence.ai.promptInstructions",
            targetKeypath: "intelligence.ai.promptInstructions",
            placeholder: "Instruksjoner for hvordan prompt skal tolkes",
            modifiers: textFieldModifiers
        )

        var sendPromptButton = SkeletonButton(
            keypath: "intelligence.ai.sendPrompt",
            label: "Send Prompt",
            payload: .string("")
        )
        sendPromptButton.modifiers = primaryButtonModifiers

        var applyInstructionsButton = SkeletonButton(
            keypath: "intelligence.ai.promptInstructions",
            label: "Sett Instruksjon",
            payload: .string("")
        )
        applyInstructionsButton.modifiers = secondaryButtonModifiers

        var ensurePurposeButton = SkeletonButton(
            keypath: "intelligence.ai.ensurePurpose",
            label: "Ensure Purpose",
            payload: .bool(true)
        )
        ensurePurposeButton.modifiers = secondaryButtonModifiers

        var buildClusterButton = SkeletonButton(
            keypath: "intelligence.ai.buildCluster",
            label: "Build Cluster",
            payload: .bool(true)
        )
        buildClusterButton.modifiers = secondaryButtonModifiers

        var discoverButton = SkeletonButton(
            keypath: "intelligence.ai.discover",
            label: "Discover",
            payload: .bool(true)
        )
        discoverButton.modifiers = secondaryButtonModifiers

        var togglesRow = SkeletonHStack(elements: [
            .Toggle(SkeletonToggle(
                label: "Rank enabled",
                keypath: "intelligence.ai.rankEnabled",
                isOn: true
            )),
            .Toggle(SkeletonToggle(
                label: "Send flow on ingest",
                keypath: "intelligence.ai.sendFlowOnIngest",
                isOn: true
            ))
        ])
        togglesRow.modifiers = modifiers {
            $0.padding = 4
            $0.background = "#F9FBFD"
            $0.cornerRadius = 8
            $0.borderWidth = 1
            $0.borderColor = "#E2E8F0"
        }

        var promptSection = SkeletonSection(
            header: .Text({
                var text = SkeletonText(text: "Prompt og handlinger")
                text.modifiers = titleModifiers
                return text
            }()),
            footer: .Text({
                var text = SkeletonText(text: "Send Prompt trigger AI-svar og verktøykall mot Perspective.")
                text.modifiers = mutedTextModifiers
                return text
            }()),
            content: [
                .TextField(promptField),
                .TextField(instructionsField),
                .HStack(SkeletonHStack(elements: [
                    .Button(sendPromptButton),
                    .Button(applyInstructionsButton)
                ])),
                .HStack(SkeletonHStack(elements: [
                    .Button(ensurePurposeButton),
                    .Button(buildClusterButton),
                    .Button(discoverButton)
                ])),
                .HStack(togglesRow)
            ]
        )
        promptSection.modifiers = cardModifiers

        var responsesList = SkeletonList(
            topic: AITopics.exploreRequest,
            keypath: "intelligence.ai.outbox",
            flowElementSkeleton: nil
        )
        responsesList.modifiers = cardModifiers

        var outboxList = SkeletonList(
            topic: "ai",
            keypath: "intelligence.ai.outbox",
            flowElementSkeleton: SkeletonVStack(elements: [
                .Text(SkeletonText(keypath: "topic")),
                .Text(SkeletonText(keypath: "title")),
                .Text(SkeletonText(keypath: "properties.type")),
                .Text(SkeletonText(keypath: "content"))
            ])
        )
        outboxList.modifiers = cardModifiers

        var rootStack = SkeletonVStack(elements: [
            .Section({
                var introSection = SkeletonSection(
                    header: nil,
                    footer: nil,
                    content: [
                        .Text(title),
                        .Text(intro)
                    ]
                )
                introSection.modifiers = cardModifiers
                return introSection
            }()),
            .Section(promptSection),
            .Section({
                var section = SkeletonSection(
                    header: .Text({
                        var text = SkeletonText(text: "AI respons (explore.request)")
                        text.modifiers = titleModifiers
                        return text
                    }()),
                    footer: nil,
                    content: [
                        .List(responsesList)
                    ]
                )
                section.modifiers = cardModifiers
                return section
            }()),
            .Section({
                var section = SkeletonSection(
                    header: .Text({
                        var text = SkeletonText(text: "Debug outbox")
                        text.modifiers = titleModifiers
                        return text
                    }()),
                    footer: nil,
                    content: [
                        .List(outboxList)
                    ]
                )
                section.modifiers = cardModifiers
                return section
            }())
        ])
        rootStack.modifiers = pageModifiers
        config.skeleton = .VStack(rootStack)
        return config
    }()
    
    @MainActor
    func appendFlowELement(_ flowElement: FlowElement) {
            print("Appending flow element: \(flowElement) elements: \(flowElements.count)")
        self.flowElements.insert(flowElement, at: 0)
        if self.flowElements.count > flowLimit {
            self.flowElements.removeLast()
        }
    }
}
