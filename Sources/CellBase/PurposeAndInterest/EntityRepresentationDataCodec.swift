// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Serializes the existing PerspectiveNode/Weight graph. It does not introduce
/// another graph model, a matcher, or an authorization policy. Owner-private
/// storage includes `person`; the default matching representation omits it.
public enum EntityRepresentationDataCodec {
    static let ownerPrivateKey = CodingUserInfoKey(rawValue: "haven.entityRepresentation.ownerPrivate")!

    /// Create a fresh encoder/register set for each independent document.
    /// Reusing it for separate documents would leave references to the first.
    public static func encoder(ownerPrivate: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[ownerPrivateKey] = ownerPrivate
        encoder.userInfo[CodingUserInfoKey(rawValue: "interestFacilitator")!] = Facilitator<Interest>()
        encoder.userInfo[CodingUserInfoKey(rawValue: "purposeFacilitator")!] = Facilitator<Purpose>()
        let entities = Facilitator<EntityRepresentation>()
        encoder.userInfo[CodingUserInfoKey(rawValue: "entityRepresentationsFacilitator")!] = entities
        encoder.userInfo[CodingUserInfoKey(rawValue: "entityFacilitator")!] = entities
        return encoder
    }

    public static func decoder(ownerPrivate: Bool = false, context: Perspective? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[ownerPrivateKey] = ownerPrivate
        if let context { decoder.userInfo[CodingUserInfoKey(rawValue: "context")!] = context }
        return decoder
    }

    /// Makes an independent node graph, retaining explicit weights, conditions,
    /// purposes and functionality references. No string-tag ranking is involved.
    public static func copy(_ entity: EntityRepresentation, ownerPrivate: Bool) throws -> EntityRepresentation {
        let data = try encoder(ownerPrivate: ownerPrivate).encode(entity)
        let result = try decoder(ownerPrivate: ownerPrivate).decode(EntityRepresentation.self, from: data)
        resolveInlineReferences(in: result)
        return result
    }

    public static func value(_ entity: EntityRepresentation, ownerPrivate: Bool = false) throws -> ValueType {
        let data = try encoder(ownerPrivate: ownerPrivate).encode(entity)
        return try JSONDecoder().decode(ValueType.self, from: data)
    }

    /// Remap resolved back references when a private root receives a salted
    /// projection ID. External entity references are left unchanged.
    public static func setRootReference(_ reference: String, in root: EntityRepresentation) {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: PerspectiveNodeImpl) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            func remap(_ edges: [Weighted]) -> [Weighted] {
                edges.map { edge in
                    if let child = edge.value as? PerspectiveNodeImpl { walk(child) }
                    if var typed = edge as? Weight<EntityRepresentation>, typed.value == nil,
                       typed.resolvedReference === root {
                        typed.reference = reference
                        return typed
                    }
                    return edge
                }
            }
            node.types = remap(node.types)
            node.subTypes = remap(node.subTypes)
            node.parts = remap(node.parts)
            node.partOf = remap(node.partOf)
            node.interests = remap(node.interests)
            node.purposes = remap(node.purposes)
            node.entities = remap(node.entities)
            node.states = remap(node.states)
        }
        walk(root)
        root.nodeIdentifier = reference
    }

    /// A graph encoded by Weight emits a shared node inline once, and subsequent
    /// edges as references. Reconnect those references after the complete graph
    /// has decoded, including back edges. External refs stay refs and require
    /// the caller's ordinary Perspective lookup; missing refs are never invented.
    public static func resolveInlineReferences(in root: EntityRepresentation) {
        var nodes: [String: PerspectiveNodeImpl] = [:]
        var visited = Set<ObjectIdentifier>()
        func key(_ node: PerspectiveNodeImpl) -> String {
            "\(String(describing: type(of: node))):\(node.reference)"
        }
        func collect(_ node: PerspectiveNodeImpl) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if nodes[key(node)] == nil { nodes[key(node)] = node }
            for edge in node.types + node.subTypes + node.parts + node.partOf + node.interests + node.purposes + node.entities + node.states {
                if let child = edge.value as? PerspectiveNodeImpl { collect(child) }
            }
        }
        collect(root)
        func bind(_ edges: [Weighted]) -> [Weighted] {
            edges.map { edge in
                guard edge.value == nil, let reference = edge.reference else { return edge }
                if var typed = edge as? Weight<Interest> {
                    typed.resolvedReference = nodes["Interest:\(reference)"]
                    return typed
                }
                if var typed = edge as? Weight<Purpose> {
                    typed.resolvedReference = nodes["Purpose:\(reference)"]
                    return typed
                }
                if var typed = edge as? Weight<EntityRepresentation> {
                    typed.resolvedReference = nodes["EntityRepresentation:\(reference)"]
                    return typed
                }
                return edge
            }
        }
        for node in nodes.values {
            node.types = bind(node.types)
            node.subTypes = bind(node.subTypes)
            node.parts = bind(node.parts)
            node.partOf = bind(node.partOf)
            node.interests = bind(node.interests)
            node.purposes = bind(node.purposes)
            node.entities = bind(node.entities)
            node.states = bind(node.states)
        }
    }
}
