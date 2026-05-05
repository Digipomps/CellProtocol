// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class SkeletonTests: XCTestCase {
    private func decodeJSONObject(_ data: Data, file: StaticString = #file, line: UInt = #line) -> [String: Any] {
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                XCTFail("Expected top-level JSON object", file: file, line: line)
                return [:]
            }
            return dict
        } catch {
            XCTFail("JSON decode failed: \(error)", file: file, line: line)
            return [:]
        }
    }

    private func mapList(_ values: [ValueType]) -> ValueType {
        .list(values)
    }

    private func mapObject(_ values: [String: ValueType]) -> ValueType {
        .object(values)
    }

    private func mapFloat(_ value: Double) -> ValueType {
        .float(value)
    }

    func testTextEncodesWithWrapperKey() throws {
        let element = SkeletonElement.Text(SkeletonText(text: "Hello"))
        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        XCTAssertNotNil(json["Text"], "Expected wrapper key 'Text' to be present")
    }

    func testTextAreaEncodesWithWrapperKey() throws {
        let element = SkeletonElement.TextArea(SkeletonTextArea(
            text: "Hello",
            sourceKeypath: "chat.editorDraft",
            targetKeypath: "chat.postMessage",
            placeholder: "Skriv melding",
            minLines: 4,
            maxLines: 10,
            submitOnEnter: true,
            editorMode: .richMarkdown
        ))
        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        XCTAssertNotNil(json["TextArea"], "Expected wrapper key 'TextArea' to be present")
        let textarea = json["TextArea"] as? [String: Any]
        XCTAssertEqual(textarea?["editorMode"] as? String, "richMarkdown")
    }

    func testTextAreaDecodesWrapped() throws {
        let json = """
        {
          "TextArea": {
            "text": "Hei",
            "sourceKeypath": "chat.editorDraft",
            "targetKeypath": "chat.postMessage",
            "placeholder": "Skriv melding",
            "minLines": 3,
            "maxLines": 9,
            "submitOnEnter": true,
            "editorMode": "richMarkdown"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let element = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .TextArea(textArea) = element else {
            XCTFail("Expected TextArea element")
            return
        }
        XCTAssertEqual(textArea.sourceKeypath, "chat.editorDraft")
        XCTAssertEqual(textArea.targetKeypath, "chat.postMessage")
        XCTAssertEqual(textArea.minLines, 3)
        XCTAssertEqual(textArea.maxLines, 9)
        XCTAssertEqual(textArea.submitOnEnter, true)
        XCTAssertEqual(textArea.editorMode, .richMarkdown)
    }

    func testTextFieldAutocompleteEncodesAndDecodes() throws {
        let element = SkeletonElement.TextField(SkeletonTextField(
            sourceKeypath: "agreement.state.selectedGrant.keypath",
            targetKeypath: "agreement.setSelectedGrantKeypath",
            placeholder: "person.displayName",
            autocomplete: SkeletonAutocomplete(
                queryActionKeypath: "agreement.keypathSetQuery",
                suggestionsKeypath: "agreement.state.keypathNormalization.suggestions",
                optionLabelKeypath: "label",
                optionValueKeypath: "canonical",
                optionDetailKeypaths: ["canonical", "category", "status"],
                selectionActionKeypath: "agreement.keypathSelectSuggestion",
                debounceMilliseconds: 125,
                minCharacters: 2,
                allowsCustomValue: false
            )
        ))

        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let fieldJSON = json["TextField"] as? [String: Any]
        let autocompleteJSON = fieldJSON?["autocomplete"] as? [String: Any]
        XCTAssertEqual(autocompleteJSON?["queryActionKeypath"] as? String, "agreement.keypathSetQuery")
        XCTAssertEqual(autocompleteJSON?["suggestionsKeypath"] as? String, "agreement.state.keypathNormalization.suggestions")
        XCTAssertEqual(autocompleteJSON?["optionValueKeypath"] as? String, "canonical")
        XCTAssertEqual(autocompleteJSON?["debounceMilliseconds"] as? Int, 125)
        XCTAssertEqual(autocompleteJSON?["minCharacters"] as? Int, 2)
        XCTAssertEqual(autocompleteJSON?["allowsCustomValue"] as? Bool, false)

        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .TextField(textField) = decoded else {
            XCTFail("Expected TextField element")
            return
        }
        XCTAssertEqual(textField.autocomplete?.queryActionKeypath, "agreement.keypathSetQuery")
        XCTAssertEqual(textField.autocomplete?.optionDetailKeypaths, ["canonical", "category", "status"])
        XCTAssertEqual(textField.autocomplete?.allowsCustomValue, false)
    }

    func testFileUploadEncodesWithWrapperKey() throws {
        let element = SkeletonElement.FileUpload(SkeletonFileUpload(
            title: "Upload image",
            helperText: "Velg bilde som sendes til cellen.",
            valueKeypath: "profile.attachment",
            stateKeypath: "profile.attachmentState",
            actionKeypath: "profile.uploadAttachment",
            acceptedContentTypes: ["image/*", "application/pdf"],
            allowsMultiple: true,
            supportsDrop: true,
            maxSizeBytes: 5_242_880,
            uploadMode: "base64"
        ))

        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let uploadJSON = json["FileUpload"] as? [String: Any]
        XCTAssertEqual(uploadJSON?["title"] as? String, "Upload image")
        XCTAssertEqual(uploadJSON?["valueKeypath"] as? String, "profile.attachment")
        XCTAssertEqual(uploadJSON?["stateKeypath"] as? String, "profile.attachmentState")
        XCTAssertEqual(uploadJSON?["actionKeypath"] as? String, "profile.uploadAttachment")
        XCTAssertEqual(uploadJSON?["allowsMultiple"] as? Bool, true)
        XCTAssertEqual(uploadJSON?["supportsDrop"] as? Bool, true)
        XCTAssertEqual(uploadJSON?["maxSizeBytes"] as? Int, 5_242_880)
        XCTAssertEqual(uploadJSON?["uploadMode"] as? String, "base64")
    }

    func testFileUploadDecodesPlannedAliasFields() throws {
        let json = """
        {
          "FileUpload": {
            "label": "Attach proof",
            "sourceKeypath": "proof.current",
            "stateKeypath": "proof.transfer",
            "targetKeypath": "proof.upload",
            "accept": ["public.image"],
            "multiple": true,
            "supportsDrop": true,
            "uploadMode": "chunked"
          }
        }
        """

        let element = try JSONDecoder().decode(SkeletonElement.self, from: Data(json.utf8))
        guard case let .FileUpload(fileUpload) = element else {
            return XCTFail("Expected FileUpload element")
        }

        XCTAssertEqual(fileUpload.title, "Attach proof")
        XCTAssertEqual(fileUpload.valueKeypath, "proof.current")
        XCTAssertEqual(fileUpload.stateKeypath, "proof.transfer")
        XCTAssertEqual(fileUpload.actionKeypath, "proof.upload")
        XCTAssertEqual(fileUpload.acceptedContentTypes, ["public.image"])
        XCTAssertEqual(fileUpload.allowsMultiple, true)
        XCTAssertEqual(fileUpload.supportsDrop, true)
        XCTAssertEqual(fileUpload.uploadMode, "chunked")
    }

    func testTabsEncodeDecodeWrapped() throws {
        let element = SkeletonElement.Tabs(SkeletonTabs(
            tabsKeypath: "agreement.state.tabs",
            activeTabStateKeypath: "agreement.state.activeTabID",
            selectionActionKeypath: "agreement.selectTab",
            panels: [
                SkeletonTabPanel(id: "overview", content: [.Text(SkeletonText(text: "Overview"))]),
                SkeletonTabPanel(id: "grants", content: [.Text(SkeletonText(text: "Grants"))])
            ]
        ))

        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let tabsJSON = json["Tabs"] as? [String: Any]
        XCTAssertEqual(tabsJSON?["tabsKeypath"] as? String, "agreement.state.tabs")
        XCTAssertEqual(tabsJSON?["activeTabStateKeypath"] as? String, "agreement.state.activeTabID")
        XCTAssertEqual(tabsJSON?["selectionActionKeypath"] as? String, "agreement.selectTab")
        XCTAssertEqual(tabsJSON?["idKeypath"] as? String, "id")
        XCTAssertEqual(tabsJSON?["labelKeypath"] as? String, "title")
        XCTAssertEqual((tabsJSON?["panels"] as? [[String: Any]])?.count, 2)

        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .Tabs(tabs) = decoded else {
            XCTFail("Expected Tabs element")
            return
        }
        XCTAssertEqual(tabs.tabsKeypath, "agreement.state.tabs")
        XCTAssertEqual(tabs.activeTabStateKeypath, "agreement.state.activeTabID")
        XCTAssertEqual(tabs.panels.map(\.id), ["overview", "grants"])
    }

    func testVisualizationEncodeDecodeWrapped() throws {
        let element = SkeletonElement.Visualization(
            SkeletonVisualization(
                kind: "network",
                keypath: "graph.state.snapshot",
                stateKeypath: "graph.state.selection",
                actionKeypath: "graph.selectNode",
                spec: .object([
                    "nodes": .list([
                        .object([
                            "id": .string("a"),
                            "label": .string("Alpha")
                        ])
                    ]),
                    "edges": .list([
                        .object([
                            "source": .string("a"),
                            "target": .string("a")
                        ])
                    ])
                ])
            )
        )

        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let visualizationJSON = json["Visualization"] as? [String: Any]
        XCTAssertEqual(visualizationJSON?["kind"] as? String, "network")
        XCTAssertEqual(visualizationJSON?["keypath"] as? String, "graph.state.snapshot")
        XCTAssertEqual(visualizationJSON?["stateKeypath"] as? String, "graph.state.selection")
        XCTAssertEqual(visualizationJSON?["actionKeypath"] as? String, "graph.selectNode")
        XCTAssertNotNil(visualizationJSON?["spec"] as? [String: Any])

        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .Visualization(visualization) = decoded else {
            return XCTFail("Expected Visualization element")
        }

        XCTAssertEqual(visualization.kind, "network")
        XCTAssertEqual(visualization.keypath, "graph.state.snapshot")
        XCTAssertEqual(visualization.stateKeypath, "graph.state.selection")
        XCTAssertEqual(visualization.actionKeypath, "graph.selectNode")
        XCTAssertEqual(try? visualization.spec?.jsonString(), try? element.specificationJSON())
    }

    func testMapVisualizationEncodeDecodeWrapped() throws {
        let spec = MapVisualizationSpec(
            coordinateSpace: .planar,
            base: .image(
                MapVisualizationImageBase(
                    url: "https://example.com/floor.png",
                    bounds: MapVisualizationBounds(minX: 0, minY: 0, maxX: 1000, maxY: 800),
                    intrinsicSize: MapVisualizationSize(width: 2000, height: 1600)
                )
            ),
            viewport: MapVisualizationViewport(
                center: MapVisualizationCoordinate(500, 400),
                zoom: 1.5
            ),
            fit: .fitBase,
            features: [
                MapVisualizationFeature(
                    id: "booth-a",
                    geometry: .point(MapVisualizationCoordinate(120, 240)),
                    label: "Booth A",
                    properties: [
                        "category": .string("booth")
                    ],
                    selectable: true,
                    style: MapVisualizationStyle(
                        fillColor: "#2563EB",
                        radius: 10
                    )
                ),
                MapVisualizationFeature(
                    id: "zone-1",
                    geometry: .polygon([
                        MapVisualizationCoordinate(300, 120),
                        MapVisualizationCoordinate(640, 120),
                        MapVisualizationCoordinate(640, 360),
                        MapVisualizationCoordinate(300, 360)
                    ]),
                    label: "Zone 1",
                    selectable: true,
                    style: MapVisualizationStyle(
                        strokeColor: "#0F172A",
                        strokeWidth: 2,
                        fillColor: "#38BDF8",
                        fillOpacity: 0.24
                    )
                )
            ],
            revision: "map-v1"
        )

        let element = SkeletonElement.Visualization(
            SkeletonVisualization(
                kind: "map",
                keypath: "venue.map",
                stateKeypath: "venue.mapSelection",
                actionKeypath: "venue.selectMapFeature",
                spec: spec.valueType
            )
        )

        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let visualizationJSON = json["Visualization"] as? [String: Any]
        XCTAssertEqual(visualizationJSON?["kind"] as? String, "map")
        XCTAssertEqual(visualizationJSON?["keypath"] as? String, "venue.map")
        XCTAssertEqual(visualizationJSON?["stateKeypath"] as? String, "venue.mapSelection")
        XCTAssertEqual(visualizationJSON?["actionKeypath"] as? String, "venue.selectMapFeature")

        let specJSON = visualizationJSON?["spec"] as? [String: Any]
        XCTAssertEqual(specJSON?["coordinateSpace"] as? String, "planar")
        XCTAssertEqual(specJSON?["revision"] as? String, "map-v1")

        let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .Visualization(visualization) = decoded else {
            return XCTFail("Expected Visualization element")
        }

        XCTAssertEqual(visualization.kind, "map")
        XCTAssertEqual(visualization.keypath, "venue.map")
        XCTAssertEqual(visualization.stateKeypath, "venue.mapSelection")
        XCTAssertEqual(visualization.actionKeypath, "venue.selectMapFeature")

        let decodedSpec = try XCTUnwrap(MapVisualizationSpec.decode(from: visualization.spec))
        XCTAssertEqual(decodedSpec.coordinateSpace, .planar)
        XCTAssertEqual(decodedSpec.revision, "map-v1")
        XCTAssertEqual(decodedSpec.features.count, 2)
        XCTAssertEqual(decodedSpec.features.first?.id, "booth-a")
    }

    func testMapVisualizationSpecDecodesGeospatialValueType() throws {
        let tileBase = mapObject([
            "kind": .string("tiles"),
            "urlTemplate": .string("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"),
            "attribution": .string("OpenStreetMap"),
            "minZoom": mapFloat(2),
            "maxZoom": mapFloat(18),
            "subdomains": mapList([.string("a"), .string("b"), .string("c")])
        ])
        let viewport = mapObject([
            "center": mapList([mapFloat(10.7522), mapFloat(59.9139)]),
            "zoom": mapFloat(5)
        ])
        let pointFeature = mapObject([
            "id": .string("oslo"),
            "geometry": mapObject([
                "type": .string("point"),
                "coordinates": mapList([mapFloat(10.7522), mapFloat(59.9139)])
            ]),
            "label": .string("Oslo"),
            "selectable": .bool(true),
            "style": mapObject([
                "fillColor": .string("#2563EB"),
                "radius": mapFloat(8)
            ])
        ])
        let routeFeature = mapObject([
            "id": .string("route-1"),
            "geometry": mapObject([
                "type": .string("polyline"),
                "coordinates": mapList([
                    mapList([mapFloat(10.70), mapFloat(59.91)]),
                    mapList([mapFloat(10.80), mapFloat(59.95)])
                ])
            ])
        ])
        let raw = mapObject([
            "coordinateSpace": .string("geospatial"),
            "base": tileBase,
            "viewport": viewport,
            "fit": .string("manual"),
            "features": mapList([pointFeature, routeFeature]),
            "revision": .string("geo-rev-1")
        ])

        let spec = try XCTUnwrap(MapVisualizationSpec.decode(from: raw))
        XCTAssertEqual(spec.coordinateSpace, .geospatial)
        XCTAssertEqual(spec.fit, .manual)
        XCTAssertEqual(spec.revision, "geo-rev-1")

        guard case let .tiles(base)? = spec.base else {
            return XCTFail("Expected tile base")
        }
        XCTAssertEqual(base.urlTemplate, "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        XCTAssertEqual(base.subdomains ?? [], ["a", "b", "c"])

        XCTAssertEqual(spec.viewport?.center?.lng, 10.7522)
        XCTAssertEqual(spec.viewport?.center?.lat, 59.9139)
        XCTAssertEqual(spec.viewport?.zoom, 5)

        guard case let .point(coordinate) = spec.features.first?.geometry else {
            return XCTFail("Expected point geometry")
        }
        XCTAssertEqual(coordinate.lng, 10.7522)
        XCTAssertEqual(coordinate.lat, 59.9139)

        guard case let .polyline(coordinates) = spec.features.last?.geometry else {
            return XCTFail("Expected polyline geometry")
        }
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates[0].lng, 10.70)
        XCTAssertEqual(coordinates[0].lat, 59.91)
    }

    func testMapVisualizationSpecDecodesPlanarImageBoundsAndRevision() throws {
        let imageBase = mapObject([
            "kind": .string("image"),
            "url": .string("https://example.com/plan.png"),
            "bounds": mapObject([
                "minX": mapFloat(0),
                "minY": mapFloat(0),
                "maxX": mapFloat(1200),
                "maxY": mapFloat(800)
            ]),
            "intrinsicSize": mapObject([
                "width": mapFloat(2400),
                "height": mapFloat(1600)
            ]),
            "opacity": mapFloat(0.85)
        ])
        let viewport = mapObject([
            "bounds": mapObject([
                "minX": mapFloat(100),
                "minY": mapFloat(120),
                "maxX": mapFloat(900),
                "maxY": mapFloat(620)
            ])
        ])
        let polygonFeature = mapObject([
            "id": .string("zone-a"),
            "geometry": mapObject([
                "type": .string("polygon"),
                "coordinates": mapList([
                    mapList([mapFloat(120), mapFloat(140)]),
                    mapList([mapFloat(420), mapFloat(140)]),
                    mapList([mapFloat(420), mapFloat(360)]),
                    mapList([mapFloat(120), mapFloat(360)])
                ])
            ]),
            "label": .string("Zone A"),
            "selectable": .bool(true)
        ])
        let raw = mapObject([
            "coordinateSpace": .string("planar"),
            "base": imageBase,
            "viewport": viewport,
            "fit": .string("fitBase"),
            "features": mapList([polygonFeature]),
            "revision": .string("planar-rev-2")
        ])

        let spec = try XCTUnwrap(MapVisualizationSpec.decode(from: raw))
        XCTAssertEqual(spec.coordinateSpace, .planar)
        XCTAssertEqual(spec.fit, .fitBase)
        XCTAssertEqual(spec.revision, "planar-rev-2")

        guard case let .image(base)? = spec.base else {
            return XCTFail("Expected image base")
        }
        XCTAssertEqual(base.bounds.minX, 0)
        XCTAssertEqual(base.bounds.maxY, 800)
        XCTAssertEqual(base.intrinsicSize?.width, 2400)
        XCTAssertEqual(base.opacity, 0.85)

        XCTAssertEqual(spec.viewport?.bounds?.minX, 100)
        XCTAssertEqual(spec.viewport?.bounds?.maxY, 620)

        guard case let .polygon(coordinates) = spec.features.first?.geometry else {
            return XCTFail("Expected polygon geometry")
        }
        XCTAssertEqual(coordinates.count, 4)
        XCTAssertEqual(coordinates[0].x, 120)
        XCTAssertEqual(coordinates[0].y, 140)

        let reencoded = try XCTUnwrap(spec.valueType)
        let reparsed = try XCTUnwrap(MapVisualizationSpec.decode(from: reencoded))
        XCTAssertEqual(reparsed.revision, "planar-rev-2")
        guard case let .polygon(reparsedCoordinates) = reparsed.features.first?.geometry else {
            return XCTFail("Expected polygon geometry after reparse")
        }
        XCTAssertEqual(reparsedCoordinates[3].x, 120)
        XCTAssertEqual(reparsedCoordinates[3].y, 360)
    }

    func testTextAsyncContentFetchesFromDefaultPortholeForKeypathOnly() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
        }

        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "conferenceParticipantShell.state.workspace.title") { _, _ in
            .string("Conference Participant Portal")
        }
        try await resolver.registerNamedEmitCell(name: "Porthole", emitCell: cell, scope: .scaffoldUnique, identity: owner)

        let text = SkeletonText(keypath: "conferenceParticipantShell.state.workspace.title")
        let content = await text.asyncContent()
        XCTAssertEqual(content, "Conference Participant Portal")
    }

    func testTextAsyncContentFetchesFromCellURLKeypath() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
        }

        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: owner)
        await cell.addInterceptForGet(requester: owner, key: "conferenceParticipantShell.state.access.headline") { _, _ in
            .string("Ownership & Access")
        }
        try await resolver.registerNamedEmitCell(name: "Porthole", emitCell: cell, scope: .scaffoldUnique, identity: owner)

        let text = SkeletonText(keypath: "cell:///Porthole/conferenceParticipantShell.state.access.headline")
        let content = await text.asyncContent()
        XCTAssertEqual(content, "Ownership & Access")
    }

    func testTextAsyncContentUsesExplicitRequesterWhenProvided() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let previousResolver = CellBase.defaultCellResolver
        defer {
            CellBase.defaultIdentityVault = previousVault
            CellBase.defaultCellResolver = previousResolver
        }

        let vault = MockIdentityVault()
        let resolver = MockCellResolver()
        CellBase.defaultIdentityVault = vault
        CellBase.defaultCellResolver = resolver

        let sourceIdentity = await vault.identity(for: "conference-shell", makeNewIfNotFound: true)!
        let cell = await GeneralCell(owner: sourceIdentity)
        await cell.addInterceptForGet(requester: sourceIdentity, key: "conferenceParticipantShell.state.workspace.title") { _, _ in
            .string("Conference Participant Portal")
        }
        try await resolver.registerNamedEmitCell(
            name: "Porthole",
            emitCell: cell,
            scope: .scaffoldUnique,
            identity: sourceIdentity
        )

        let text = SkeletonText(keypath: "conferenceParticipantShell.state.workspace.title")
        let content = await text.asyncContent(requester: sourceIdentity)
        XCTAssertEqual(content, "Conference Participant Portal")
    }

    func testModifiersEncodeStyleMetadata() throws {
        var modifiers = SkeletonModifiers()
        modifiers.styleRole = "chatComposer"
        modifiers.styleClasses = ["chat", "composer", "elevated"]
        let data = try JSONEncoder().encode(modifiers)
        let json = decodeJSONObject(data)
        XCTAssertEqual(json["styleRole"] as? String, "chatComposer")
        XCTAssertEqual(json["styleClasses"] as? [String], ["chat", "composer", "elevated"])
    }

    func testObjectEncodesWrapped() throws {
        let obj = SkeletonObject(elements: ["title": .Text(SkeletonText(text: "Hello"))])
        let data = try JSONEncoder().encode(obj)
        let json = decodeJSONObject(data)
        XCTAssertNotNil(json["Object"], "Expected wrapper key 'Object' to be present")
        XCTAssertNil(json["elements"], "Expected legacy 'elements' key to be absent at top level when wrapped")
    }

    func testObjectDecodesWrapped() throws {
        let json = """
        {
          "Object": {
            "elements": {
              "title": { "Text": { "text": "Hello" } }
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let obj = try JSONDecoder().decode(SkeletonObject.self, from: data)
        XCTAssertEqual(obj.elements.count, 1)
    }

    func testObjectDecodesLegacyUnwrapped() throws {
        let json = """
        {
          "elements": {
            "title": { "Text": { "text": "Hello" } }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let obj = try JSONDecoder().decode(SkeletonObject.self, from: data)
        XCTAssertEqual(obj.elements.count, 1)
    }

    func testListEncodesFlowElementSkeletonKey() throws {
        let list = SkeletonList(
            topic: "test.topic",
            keypath: "cell:///Porthole/test",
            flowElementSkeleton: SkeletonVStack(elements: [
                .Text(SkeletonText(text: "Item"))
            ])
        )
        let element = SkeletonElement.List(list)
        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let listJSON = json["List"] as? [String: Any]
        XCTAssertNotNil(listJSON?["flowElementSkeleton"], "Expected 'flowElementSkeleton' to be encoded with correct casing")
        XCTAssertNil(listJSON?["flowELementSkeleton"], "Unexpected misspelled 'flowELementSkeleton' key present")
    }

    func testListDecodesFlowElementSkeleton() throws {
        let json = """
        {
          "List": {
            "flowElementSkeleton": {
              "VStack": [
                { "Text": { "text": "Item" } }
              ]
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let element = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .List(list) = element else {
            XCTFail("Expected List element")
            return
        }
        XCTAssertNotNil(list.flowElementSkeleton)
    }

    func testListEncodesSelectionFields() throws {
        var list = SkeletonList(
            topic: "agreements",
            keypath: "cell:///Porthole/agreements",
            flowElementSkeleton: SkeletonVStack(elements: [
                .Text(SkeletonText(text: "Item"))
            ])
        )
        list.selectionMode = .single
        list.selectionValueKeypath = "agreementId"
        list.selectionStateKeypath = "workbench.selection.set"
        list.activationActionKeypath = "workbench.selection.open"
        list.selectionPayloadMode = .itemID
        list.allowsEmptySelection = false

        let element = SkeletonElement.List(list)
        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let listJSON = json["List"] as? [String: Any]

        XCTAssertEqual(listJSON?["selectionMode"] as? String, "single")
        XCTAssertEqual(listJSON?["selectionValueKeypath"] as? String, "agreementId")
        XCTAssertEqual(listJSON?["selectionStateKeypath"] as? String, "workbench.selection.set")
        XCTAssertEqual(listJSON?["activationActionKeypath"] as? String, "workbench.selection.open")
        XCTAssertEqual(listJSON?["selectionPayloadMode"] as? String, "item_id")
        XCTAssertEqual(listJSON?["allowsEmptySelection"] as? Bool, false)
    }

    func testListDecodesSelectionFields() throws {
        let json = """
        {
          "List": {
            "selectionMode": "multiple",
            "selectionValueKeypath": "entityId",
            "selectionActionKeypath": "entityBrowser.selection.set",
            "selectionPayloadMode": "selected_ids",
            "allowsEmptySelection": true
          }
        }
        """

        let data = json.data(using: .utf8)!
        let element = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .List(list) = element else {
            XCTFail("Expected List element")
            return
        }

        XCTAssertEqual(list.selectionMode, .multiple)
        XCTAssertEqual(list.selectionValueKeypath, "entityId")
        XCTAssertEqual(list.selectionActionKeypath, "entityBrowser.selection.set")
        XCTAssertEqual(list.selectionPayloadMode, .selectedIDs)
        XCTAssertEqual(list.allowsEmptySelection, true)
    }

    func testListDecodeRejectsIDSelectionPayloadWithoutSelectionValueKeypath() throws {
        let json = """
        {
          "List": {
            "selectionMode": "single",
            "selectionPayloadMode": "item_id"
          }
        }
        """

        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SkeletonElement.self, from: data))
    }

    func testListEncodeRejectsIDSelectionPayloadWithoutSelectionValueKeypath() throws {
        var list = SkeletonList(topic: "agreements", keypath: "cell:///Porthole/agreements", flowElementSkeleton: nil)
        list.selectionMode = .single
        list.selectionPayloadMode = .itemID

        XCTAssertThrowsError(try JSONEncoder().encode(SkeletonElement.List(list)))
    }

    func testListBuildsSingleSelectionPayloadWithIDValue() throws {
        var list = SkeletonList(topic: "agreements", keypath: "cell:///Porthole/agreements", flowElementSkeleton: nil)
        list.selectionMode = .single
        list.selectionValueKeypath = "agreementId"
        list.selectionPayloadMode = .itemID

        let rows: [ValueType] = [
            .object(["agreementId": .string("agreement-1"), "status": .string("active")]),
            .object(["agreementId": .string("agreement-2"), "status": .string("draft")])
        ]

        let payload = try list.selectionPayload(trigger: .select, rows: rows, selectedIndices: [1])
        guard case let .object(object) = payload else {
            XCTFail("Expected object payload")
            return
        }

        guard case let .string(selectionMode)? = object["selectionMode"],
              case let .string(trigger)? = object["trigger"],
              case let .integer(selectedIndex)? = object["selectedIndex"],
              case let .string(selectedValue)? = object["selected"] else {
            XCTFail("Expected single-select payload fields")
            return
        }

        XCTAssertEqual(selectionMode, "single")
        XCTAssertEqual(trigger, "select")
        XCTAssertEqual(selectedIndex, 1)
        XCTAssertEqual(selectedValue, "agreement-2")
    }

    func testListBuildsMultiSelectionPayloadInSourceOrder() throws {
        var list = SkeletonList(topic: "entities", keypath: "cell:///Porthole/entities", flowElementSkeleton: nil)
        list.selectionMode = .multiple
        list.selectionValueKeypath = "entityId"
        list.selectionPayloadMode = .selectedIDs

        let rows: [ValueType] = [
            .object(["entityId": .string("entity-a")]),
            .object(["entityId": .string("entity-b")]),
            .object(["entityId": .string("entity-c")])
        ]

        let payload = try list.selectionPayload(trigger: .select, rows: rows, selectedIndices: [2, 0])
        guard case let .object(object) = payload else {
            XCTFail("Expected object payload")
            return
        }
        guard case let .list(indices)? = object["selectedIndices"],
              case let .list(selected)? = object["selected"] else {
            XCTFail("Expected list payload values")
            return
        }

        let selectedIndices = indices.compactMap { value -> Int? in
            guard case let .integer(index) = value else { return nil }
            return index
        }
        let selectedIDs = selected.compactMap { value -> String? in
            guard case let .string(id) = value else { return nil }
            return id
        }

        XCTAssertEqual(selectedIndices, [0, 2])
        XCTAssertEqual(selectedIDs, ["entity-a", "entity-c"])
    }

    func testReferenceEncodesFlowElementSkeletonKey() throws {
        var reference = SkeletonCellReference(keypath: "cell:///Porthole/test", topic: "test")
        reference.flowElementSkeleton = SkeletonVStack(elements: [
            .Text(SkeletonText(text: "Item"))
        ])
        let element = SkeletonElement.Reference(reference)
        let data = try JSONEncoder().encode(element)
        let json = decodeJSONObject(data)
        let refJSON = json["Reference"] as? [String: Any]
        XCTAssertNotNil(refJSON?["flowElementSkeleton"], "Expected 'flowElementSkeleton' to be encoded with correct casing")
        XCTAssertNil(refJSON?["flowELementSkeleton"], "Unexpected misspelled 'flowELementSkeleton' key present")
    }

    func testReferenceDecodesFlowElementSkeleton() throws {
        let json = """
        {
          "Reference": {
            "topic": "test",
            "keypath": "cell:///Porthole/test",
            "flowElementSkeleton": {
              "VStack": [
                { "Text": { "text": "Item" } }
              ]
            }
          }
        }
        """
        let data = json.data(using: .utf8)!
        let element = try JSONDecoder().decode(SkeletonElement.self, from: data)
        guard case let .Reference(reference) = element else {
            XCTFail("Expected Reference element")
            return
        }
        XCTAssertNotNil(reference.flowElementSkeleton)
    }
}

private extension SkeletonElement {
    func specificationJSON() throws -> String? {
        guard case let .Visualization(visualization) = self else {
            return nil
        }
        return try visualization.spec?.jsonString()
    }
}
