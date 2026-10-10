// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Ett sjekkliste-skjelett, to innganger (PDD lister, purpose://candidate.lister.component.single-source):
//  - flaten «Mine lister» leser cellen gjennom Porthole-referansen `my` → keypath-prefiks "my.lists."
//  - komponentmonteringen (SkeletonComponentMount) snakker rett med cellen → prefiks "lists."
// Alt annet er byte-likt. Bildene Kjetil godkjente (G1-GUI 2026-10-02) er rendret fra JSON-en
// `mineListerConfiguration()` gir; testen `ListsConfigurationTests` holder dem like.
public enum ListsSkeletonFactory {
    public static let componentID = "haven.lists.checklist"
    public static let componentRevision = "1"
    public static let cellEndpoint = "cell:///Lists"
    public static let cellName = "ListsCell"
    public static let referenceLabel = "my"
    public static let surfacePrefix = "my.lists."
    public static let mountPrefix = "lists."

    /// Hex-farger virker på begge renderere (SkeletonView `Color(skeletonHex:)`, web CSS).
    public static let secondaryColor = "#8E8E93"   // iOS secondaryLabel; brukes på utførte punkter
    public static let accentColor = "#007AFF"
    public static let noticeTextColor = "#FFB4AB"
    public static let noticeBackground = "#B0002033"

    /// Handlingene flaten må gi tilgang til (FORMAALSSPEC §3), med flate-prefiks.
    public static var surfaceActionKeypaths: Set<String> {
        Set(["list.create", "list.select", "list.rename", "list.remove", "list.clearDone",
             "item.add", "item.toggle", "item.move", "item.remove"].map { surfacePrefix + $0 })
    }

    // MARK: - Byggeklosser

    private static func modifiers(_ configure: (inout SkeletonModifiers) -> Void) -> SkeletonModifiers {
        var m = SkeletonModifiers()
        configure(&m)
        return m
    }

    private static func itemVisible(_ keypath: String, equals value: Bool) -> SkeletonVisibilityRule {
        SkeletonVisibilityRule(when: SkeletonCondition(scope: .item, keypath: keypath, equals: .bool(value)))
    }

    private static func text(_ text: String, _ configure: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonElement {
        var element = SkeletonText(text: text)
        if let configure { element.modifiers = modifiers(configure) }
        return .Text(element)
    }

    private static func boundText(_ keypath: String, _ configure: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonElement {
        var element = SkeletonText(keypath: keypath)
        if let configure { element.modifiers = modifiers(configure) }
        return .Text(element)
    }

    private static func button(_ keypath: String, label: String = "", icon: String? = nil, payloadKeypath: String,
                               _ configure: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonElement {
        var element = SkeletonButton(keypath: keypath, label: label, payloadKeypath: payloadKeypath, icon: icon)
        if let configure { element.modifiers = modifiers(configure) }
        return .Button(element)
    }

    private static func spacer() -> SkeletonElement { .Spacer(SkeletonSpacer()) }

    private static func list(_ keypath: String, row: SkeletonVStack, _ configure: ((inout SkeletonList) -> Void)? = nil) -> SkeletonElement {
        var element = SkeletonList(topic: nil, keypath: keypath, flowElementSkeleton: row)
        if let configure { configure(&element) }
        return .List(element)
    }

    private static func hstack(_ elements: [SkeletonElement], spacing: Double? = nil, _ configure: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonElement {
        var element = SkeletonHStack(elements: elements, spacing: spacing)
        if let configure { element.modifiers = modifiers(configure) }
        return .HStack(element)
    }

    private static func vstack(_ elements: [SkeletonElement], spacing: Double? = nil, _ configure: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonVStack {
        var element = SkeletonVStack(elements: elements, spacing: spacing)
        if let configure { element.modifiers = modifiers(configure) }
        return element
    }

    private static func textRow(_ keypath: String, color: String, rowModifiers: ((inout SkeletonModifiers) -> Void)? = nil) -> SkeletonVStack {
        vstack([boundText(keypath) { m in m.fontStyle = "callout"; m.foregroundColor = color }], rowModifiers)
    }

    // MARK: - Sjekklisten (én liste)

    /// Én rad i sjekklista: sirkel/hake, tittel, piler (skjult der verten har `drag`) og fjern.
    /// Alt leser radens egne data (`togglePayload`, `moveUpPayload`, …), som cellen legger i hvert punkt.
    public static func checklistItemRow(keypathPrefix p: String) -> SkeletonVStack {
        let hideWhenDrag: [SkeletonLayoutVariant] = [SkeletonLayoutVariant(requiresCapability: [.drag], hidden: true)]
        let unchecked = button(p + "item.toggle", label: "○", payloadKeypath: "togglePayload") { m in
            m.controlStyle = .plain; m.fontSize = 22; m.foregroundColor = secondaryColor
            m.accessibilityLabel = "Merk som utført"; m.width = 28
            m.visibility = itemVisible("done", equals: false)
        }
        let checked = button(p + "item.toggle", icon: "checkmark.circle.fill", payloadKeypath: "togglePayload") { m in
            m.controlStyle = .plain; m.fontSize = 22; m.foregroundColor = accentColor
            m.accessibilityLabel = "Merk som ikke utført"; m.width = 28
            m.visibility = itemVisible("done", equals: true)
        }
        let title = boundText("title") { m in m.fontStyle = "body"; m.foregroundColorKeypath = "titleColor" }
        let up = button(p + "item.move", icon: "chevron.up", payloadKeypath: "moveUpPayload") { m in
            m.controlStyle = .plain; m.foregroundColor = secondaryColor; m.accessibilityLabel = "Flytt opp"
            m.layoutVariants = hideWhenDrag
            m.visibility = itemVisible("done", equals: false)
        }
        let down = button(p + "item.move", icon: "chevron.down", payloadKeypath: "moveDownPayload") { m in
            m.controlStyle = .plain; m.foregroundColor = secondaryColor; m.accessibilityLabel = "Flytt ned"
            m.layoutVariants = hideWhenDrag
            m.visibility = itemVisible("done", equals: false)
        }
        let remove = button(p + "item.remove", icon: "trash", payloadKeypath: "removePayload") { m in
            m.controlStyle = .plain; m.foregroundColor = secondaryColor; m.accessibilityLabel = "Fjern"
        }
        let row = hstack([unchecked, checked, title, spacer(), up, down, remove], spacing: 8) { m in
            m.draggableRole = "list-item"
            m.dragPayloadKeypath = "dragPayload"
            m.dropTargetRole = "list-item-slot"
            m.acceptedDragRoles = ["list-item"]
            m.dropTargetPayloadKeypath = "dropPayload"
            m.dropActionKeypath = p + "item.move"
            m.accessibilityDragLabel = "Dra for å flytte"
            m.paddingInsets = SkeletonInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        }
        return vstack([row])
    }

    /// Sjekkliste-fragmentet for ÉN liste. Leser radens/monteringens item: `title`, `summaryText`,
    /// `items`, `emptyRows`, `doneRows`, `removeListPayload`, `clearDonePayload`.
    public static func checklistSkeleton(keypathPrefix p: String) -> SkeletonVStack {
        var titleField = SkeletonTextField(sourceKeypath: "title", targetKeypath: p + "list.rename", placeholder: "Listenavn")
        titleField.modifiers = modifiers { m in m.fontStyle = "title2"; m.fontWeight = "semibold" }
        let header = hstack([
            .TextField(titleField),
            spacer(),
            boundText("summaryText") { m in m.fontStyle = "caption"; m.foregroundColor = secondaryColor },
            button(p + "list.remove", icon: "trash", payloadKeypath: "removeListPayload") { m in
                m.controlStyle = .plain; m.foregroundColor = secondaryColor; m.accessibilityLabel = "Slett listen"
            }
        ], spacing: 8)
        var addField = SkeletonTextField(targetKeypath: p + "item.add", placeholder: "Legg til …")
        addField.modifiers = modifiers { m in m.maxWidthInfinity = true }
        let items = list("items", row: checklistItemRow(keypathPrefix: p)) { l in
            l.modifiers = modifiers { m in m.itemSpacing = 0; m.rowDecoration = SkeletonRowDecoration.none }
        }
        let empty = list("emptyRows", row: textRow("text", color: secondaryColor))
        let clearDone = list("doneRows", row: vstack([
            hstack([spacer(), button(p + "list.clearDone", label: "Fjern utførte", payloadKeypath: "clearDonePayload") { m in
                m.controlStyle = .plain; m.foregroundColor = accentColor; m.fontStyle = "callout"
            }])
        ]))
        return vstack([header, .TextField(addField), items, empty, clearDone], spacing: 10)
    }

    // MARK: - Flaten «Mine lister»

    public static func mineListerSkeleton() -> SkeletonElement {
        let p = surfacePrefix
        var newList = SkeletonTextField(targetKeypath: p + "list.create", placeholder: "Ny liste … (Enter)")
        newList.modifiers = modifiers { m in m.maxWidthInfinity = true }
        let listRow = vstack([hstack([
            boundText("title") { m in m.fontStyle = "body"; m.fontWeight = "semibold"; m.visibility = itemVisible("isActive", equals: true) },
            boundText("title") { m in m.fontStyle = "body"; m.visibility = itemVisible("isActive", equals: false) },
            spacer(),
            boundText("summaryText") { m in m.fontStyle = "caption"; m.foregroundColor = secondaryColor }
        ], spacing: 8)])
        let lists = list(p + "state.lists", row: listRow) { l in
            l.selectionMode = .single
            l.selectionValueKeypath = "id"
            l.selectionPayloadMode = .itemID
            l.selectionActionKeypath = p + "list.select"
            l.allowsEmptySelection = false
            l.modifiers = modifiers { m in m.itemSpacing = 0 }
        }
        let hint = list(p + "state.emptyHint", row: textRow("text", color: secondaryColor))
        let notice = list(p + "state.notice", row: textRow("text", color: noticeTextColor) { m in
            m.background = noticeBackground; m.cornerRadius = 8; m.padding = 10
        })
        let active = list(p + "state.activeAsRows", row: checklistSkeleton(keypathPrefix: p)) { l in
            l.modifiers = modifiers { m in m.itemSpacing = 0 }
        }
        let left = vstack([text("Mine lister") { m in m.fontStyle = "title"; m.fontWeight = "bold" }, .TextField(newList), lists, hint], spacing: 10)
        let right = vstack([notice, active], spacing: 10)
        let columns = hstack([
            .VStack(vstack([.VStack(left)]) { m in m.layoutVariants = [SkeletonLayoutVariant(minAvailableWidth: 701, width: 300)] }),
            .VStack(vstack([.VStack(right)]) { m in m.maxWidthInfinity = true })
        ], spacing: 24) { m in
            m.vAlignment = "top"
            m.layoutVariants = [SkeletonLayoutVariant(maxAvailableWidth: 700, axis: .vertical)]
        }
        return .VStack(vstack([columns], spacing: 16) { m in m.padding = 16 })
    }

    public static func mineListerConfiguration() -> CellConfiguration {
        var configuration = CellConfiguration(name: "Mine lister")
        configuration.description = "Brukerens egne lister (handleliste, huskeliste, idéliste …) fra cell:///Lists: velg liste, legg til, kryss av, flytt, fjern. Utførte sorteres i bunn."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: cellEndpoint,
            sourceCellName: cellName,
            purpose: "Mine lister",
            purposeDescription: "Holde brukerens lister og krysse av det som er gjort.",
            interests: ["lists", "handleliste", "huskeliste", "ideer", "todo"],
            menuSlots: ["lowerMid"]
        )
        configuration.addReference(CellReference(endpoint: cellEndpoint, label: referenceLabel))
        configuration.skeleton = mineListerSkeleton()
        return configuration
    }

    // MARK: - Komponentmontering (én per liste)

    public static func componentMount(item: ValueType) -> SkeletonComponentMount {
        SkeletonComponentMount(
            componentID: componentID,
            revision: componentRevision,
            sourceCellEndpoint: cellEndpoint,
            skeleton: .VStack(checklistSkeleton(keypathPrefix: mountPrefix)),
            item: item
        )
    }
}
