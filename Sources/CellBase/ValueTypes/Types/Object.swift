// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public typealias Object = [String: ValueType]
public typealias Entity = Object
public typealias ValueTypeList = [ValueType]

/// Utility struct for encoding / coding list of dynamic properties
extension Object {
    public init(propertyValues: [String: ValueType]) {
        self = propertyValues
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        
        var object = Object()
        for key in container.allKeys {
            do {
                let decodedObject = try container.decode(ValueType.self, forKey: key /* DynamicCodingKeys(stringValue: key.stringValue) */ )
                object[key.stringValue] = decodedObject
                
            } catch {
                continue
            }
        }
        self = object
    }
    
    // Maybe just move it one level up...
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        
        for (key, value) in self {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            
        }
    }
}

//extension Object2 {
//    
//    public mutating func set(keypath: String, setValue: ValueType?) async throws {
//        let keypathArray = keypath.split(separator: ".") // Needs parser
//        
//        var valueStack = [ValueType]()
//        var keyStack = [String]()
//        
//        var currentValue: ValueType = .object(self)
//        var lastKey: String = "$"
//        
//        for currentKey in keypathArray {
//            lastKey = String(currentKey)
//            keyStack.append(lastKey)
//            switch currentValue {
//            case .object(var objectValue):
//                if let value = objectValue[lastKey] {
//                    valueStack.insert(value, at: 0)
//                    currentValue = value
//                } else {
//                    if valueStack.count < keypathArray.count {
//                        
//                        
//                        if  Int(lastKey) != nil {
//                            let value = ValueType.object(Object())
//                            let list = ValueTypeList()
//                            let listValue = ValueType.list(list)
//                            valueStack[0] = listValue // Replace the object already placed there from last iteration
//                            valueStack.insert(value, at: 0)
//                            currentValue = value
// 
//                        } else {
//                            let value = ValueType.object(Object())
//                            
//                            objectValue[lastKey] = value
//                            valueStack.insert(value, at: 0)
//                            currentValue = value
//                        }
//                    }
//                }
//                
//            case .list(let listValue):
//                if let index = Int(lastKey) {
//                    var value: ValueType
//                    if index < 0 || index >= listValue.count {
//                        let object = Object()
//                        value = .object(object)
//                        
//                    } else {
//                        value = listValue[index]
//                    }
//                    valueStack.insert(value, at: 0)
//                    currentValue = value
//                }
//            default: ()
//            }
//        }
//        
//        if let setValue = setValue { // Then assemble
//            var didSetTargetValue = false
//            var targetValue: ValueType = .string(".")
//                currentValue = setValue
//            for currentStackValue in valueStack {
//                if let key = keyStack.last {
//                    lastKey = key
//                } else {
//                    break
//                }
//                switch currentStackValue {
//                case .object(var objectValue):
//                    objectValue[lastKey] = targetValue
//                    targetValue = .object(objectValue)
//                    if didSetTargetValue {
//                        keyStack.removeLast()
//                    } else {
//                        didSetTargetValue = true
//                        targetValue = setValue
//                    }
// 
//                case .list(var listValue):
//                    if let index = Int(lastKey) {
//                        if index < 0 || index > listValue.count {
//                            listValue.append(targetValue)
//                        } else {
//                            listValue[index] = targetValue
//                        }
//                        targetValue = .list(listValue)
//                    }
//                    print("Not implemented yet?: \(listValue)")
//
//
//                default:
//                    targetValue = setValue
//                    didSetTargetValue = true
//                }
//            }
//            if keyStack.count > 0 {
//                self[keyStack[0]] = targetValue
//            }
//        }
//    }
//    
//    public mutating func get(keypath: String) async throws -> ValueType? {
//        let keyPathArray = keypath.split(separator: ".") // Needs parser
//        var keyStack = [String]()
//        var currentValue: ValueType? = .object(self)
//        var lastKey: String = "$"
//        
//        for currentKey in keyPathArray {
//            lastKey = String(currentKey)
//            keyStack.append(lastKey)
//            switch currentValue {
//            case .object(let objectValue):
//                if let value = objectValue[lastKey] {
//                    currentValue = value
//                } else {
//                    currentValue = nil
//                }
//                
//            case .list(let listValue):
//                if let index = Int(lastKey) {
//                    let value = listValue[index]
//                    currentValue = value
//                } else {
//                    currentValue = nil
//                }
//            default:
//                currentValue = nil
//            }
//               
//        }
//        return currentValue
//    }
//}

//----------------------------- ChatGPT generated ---------

public enum KeyPathError: Error {
    case notFound(String)       // path where it failed
    case typeMismatch(String)   // when an operation needs list/object but finds something else
    case invalidPath(String)    // parse errors etc.
}


// MARK: - KeyPath parsing

private enum PathSegment: CustomStringConvertible {
    case key(String)                          // .foo
    case listIndex(Int)                       // [2]
    case listAppend                           // [+]
    case listMatch(key: String, value: Literal) // [id=42], [name="x"]

    var description: String {
        switch self {
        case .key(let k): return ".\(k)"
        case .listIndex(let i): return "[\(i)]"
        case .listAppend: return "[+]"
        case .listMatch(let k, let v): return "[\(k)=\(v)]"
        }
    }
}

private struct KeyPathParser {
    static func parse(_ path: String) throws -> [PathSegment] {
        guard !path.isEmpty else { return [] }
        var result: [PathSegment] = []
        var i = path.startIndex

        func peek() -> Character? { i < path.endIndex ? path[i] : nil }
        func advance() { i = path.index(after: i) }

        func readName() -> String {
            let start = i
            while let ch = peek(), ch != ".", ch != "[" {
                advance()
            }
            return String(path[start..<i])
        }

        func readBracket() throws -> PathSegment {
            // assumes current char is '['
            advance() // skip '['
            // skip spaces
            while let ch = peek(), ch.isWhitespace { advance() }

            // Append?
            if let ch = peek(), ch == "+" {
                advance()
                // consume spaces
                while let ch2 = peek(), ch2.isWhitespace { advance() }
                guard peek() == "]" else { throw KeyPathError.invalidPath("Missing ']' after [+] in \(path)") }
                advance()
                return .listAppend
            }

            // Index? (digits)
            if let ch = peek(), ch.isNumber || ch == "-" {
                var start = i
                advance()
                while let ch2 = peek(), ch2.isNumber { advance() }
                let numStr = String(path[start..<i])
                guard let idx = Int(numStr) else {
                    throw KeyPathError.invalidPath("Bad index '\(numStr)' in \(path)")
                }
                // spaces + ]
                while let ch2 = peek(), ch2.isWhitespace { advance() }
                guard peek() == "]" else { throw KeyPathError.invalidPath("Missing ']' after index in \(path)") }
                advance()
                return .listIndex(idx)
            }

            // Match: key=literal
            let keyStart = i
            while let ch = peek(), ch != "=", ch != "]" { advance() }
            let key = String(path[keyStart..<i]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, peek() == "=" else {
                throw KeyPathError.invalidPath("Expected key=value inside [] in \(path)")
            }
            advance() // skip '='

            // literal: "string" | number | true/false
            func readLiteral() throws -> Literal {
                guard let ch = peek() else { throw KeyPathError.invalidPath("Missing literal in \(path)") }
                if ch == "\"" {
                    advance()
                    var s = ""
                    while let c = peek(), c != "\"" {
                        if c == "\\" {
                            advance()
                            if let esc = peek() {
                                s.append(esc)
                                advance()
                                continue
                            } else { break }
                        }
                        s.append(c)
                        advance()
                    }
                    guard peek() == "\"" else { throw KeyPathError.invalidPath("Unterminated string literal in \(path)") }
                    advance()
                    return .string(s)
                } else {
                    // read until ] or whitespace
                    var start = i
                    while let c = peek(), c != "]", !c.isWhitespace { advance() }
                    let raw = String(path[start..<i])
                    if raw == "true" { return .bool(true) }
                    if raw == "false" { return .bool(false) }
                    if let iv = Int(raw) { return .int(iv) }
                    if let dv = Double(raw) { return .double(dv) }
                    // fallback: bare word as string
                    return .string(raw)
                }
            }

            let lit = try readLiteral()
            // spaces + ]
            while let ch2 = peek(), ch2.isWhitespace { advance() }
            guard peek() == "]" else { throw KeyPathError.invalidPath("Missing ']' after match in \(path)") }
            advance()
            return .listMatch(key: key, value: lit)
        }

        // Start: first token may be a bare name (no leading '.')
        if let ch = peek(), ch != "[", ch != "." {
            let name = readName()
            guard !name.isEmpty else { throw KeyPathError.invalidPath("Empty key component in \(path)") }
            result.append(.key(name))
        }

        while let ch = peek() {
            if ch == "." {
                advance()
                let name = readName()
                guard !name.isEmpty else { throw KeyPathError.invalidPath("Empty key after '.' in \(path)") }
                result.append(.key(name))
            } else if ch == "[" {
                let seg = try readBracket()
                result.append(seg)
            } else {
                throw KeyPathError.invalidPath("Unexpected character '\(ch)' in \(path)")
            }
        }

        return result
    }
}

// MARK: - Navigation helpers (get / set)

private struct Navigator {
    static func get(in root: ValueType, segments: [PathSegment], fullPath: String) throws -> ValueType {
        var current = root
        var consumed: [PathSegment] = []

        func fail(_ reason: String) throws -> Never {
            let whereStr = (consumed.map { "\($0)" }.joined())
            throw KeyPathError.notFound("\(reason) at \(whereStr) in \(fullPath)")
        }

        for seg in segments {
            consumed.append(seg)
            switch seg {
            case .key(let k):
                guard case .object(let obj) = current else {
                    try fail("Expected object, found \(current)")
                }
                guard let next = obj[k] else { try fail("Missing key '\(k)'") }
                current = next

            case .listIndex(let idx):
                guard case .list(let arr) = current else {
                    try fail("Expected list before [\(idx)]")
                }
                guard idx >= 0 && idx < arr.count else { try fail("Index out of bounds [\(idx)]") }
                current = arr[idx]

            case .listAppend:
                // get() with append doesn't make sense
                try fail("Append [+] not valid for get")

            case .listMatch(let key, let lit):
                guard case .list(let arr) = current else {
                    try fail("Expected list before [\(key)=...]")
                }
                let matchVal = ValueType.fromLiteral(lit)
                guard let found = arr.first(where: { element in
                    guard case .object(let o) = element, let v = o[key] else { return false }
                    return ValueComparer.equals(v, matchVal)
                }) else {
                    try fail("No match for [\(key)=\(lit)]")
                }
                current = found
            }
        }

        return current
    }

    static func set( root: inout ValueType, segments: [PathSegment], value: ValueType, fullPath: String) throws {
        guard !segments.isEmpty else {
            root = value
            return
        }

        var current = root

        func ensureObject(_ val: ValueType) -> Object {
            if case .object(let o) = val { return o }
            return [:]
        }

        func ensureList(_ val: ValueType) -> ValueTypeList {
            if case .list(let a) = val { return a }
            return []
        }

        func recurseSet(_ node: inout ValueType, at idx: Int) throws {
            if idx == segments.count {
                node = value
                return
            }

            switch segments[idx] {
            case .key(let k):
                // Ensure object
                var obj = ensureObject(node)
                var child = obj[k] ?? .object([:]) // default to object; could be list depending on next seg
                try recurseSet(&child, at: idx + 1)
                obj[k] = child
                node = .object(obj)

            case .listIndex(let i):
                // Ensure list
                var arr = ensureList(node)
                // If index is negative, error (we could support -1 but holder oss enkle)
                guard i >= 0 else { throw KeyPathError.invalidPath("Negative index [\(i)] in \(fullPath)") }
                // Extend with empty objects until i reachable
                while arr.count <= i {
                    arr.append(.object([:]))
                }
                var child = arr[i]
                try recurseSet(&child, at: idx + 1)
                arr[i] = child
                node = .list(arr)

            case .listAppend:
                // Ensure list
                var arr = ensureList(node)
                if idx == segments.count - 1 {
                    // terminal: append the value itself
                    arr.append(value)
                    node = .list(arr)
                } else {
                    // append an empty object, then continue setting into it
                    var child: ValueType = .object([:])
                    try recurseSet(&child, at: idx + 1)
                    arr.append(child)
                    node = .list(arr)
                }

            case .listMatch(let key, let lit):
                // Ensure list
                var arr = ensureList(node)
                let desired = ValueType.fromLiteral(lit)

                // Finn eksisterende
                var foundIndex: Int? = nil
                for (idx2, el) in arr.enumerated() {
                    if case .object(let o) = el, let v = o[key], ValueComparer.equals(v, desired) {
                        foundIndex = idx2
                        break
                    }
                }

                if let fi = foundIndex {
                    var child = arr[fi]
                    try recurseSet(&child, at: idx + 1)
                    arr[fi] = child
                    node = .list(arr)
                } else {
                    // Opprett nytt objekt med match-feltet, og sett videre nedover pathen
                    var newObj: Object = [key: desired]
                    var child: ValueType = .object(newObj)
                    try recurseSet(&child, at: idx + 1)
                    // sørg for at matchfeltet fortsatt finnes (kan ha blitt overskrevet)
                    if case .object(var o2) = child, o2[key] == nil {
                        o2[key] = desired
                        child = .object(o2)
                    }
                    arr.append(child)
                    node = .list(arr)
                }
            }
        }

        try recurseSet(&current, at: 0)
        root = current
    }
}

// Verdilikehet (for matching)
private enum ValueComparer {
    static func equals(_ a: ValueType, _ b: ValueType) -> Bool {
        switch (a, b) {
        case (.bool(let x), .bool(let y)): return x == y
        case (.integer(let x), .integer(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.integer(let x), .number(let y)): return x == y
        case (.number(let x), .integer(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        default: return false
        }
    }
}

// MARK: - Public API on Object

public extension Dictionary where Key == String, Value == ValueType {
    /// Hent verdi på keypath. Kaster `notFound` ved manglende sti.
    /// func get(keypath: String) async throws -> ValueType?
    func get(keypath path: String) throws -> ValueType {
        let segs = try KeyPathParser.parse(path)
        let root: ValueType = .object(self)
        return try Navigator.get(in: root, segments: segs, fullPath: path)
    }

    /// Sett verdi på keypath. Oppretter nødvendige noder (objekter/lister) underveis.
    /// Støtter listeappend via `[+]` og match via `[field=literal]`.
    /// set(keypath: String, setValue: ValueType?)
    mutating func set(_ value: ValueType, keypath path: String) throws {
        let segs = try KeyPathParser.parse(path)
        var root: ValueType = .object(self)
        try Navigator.set(root: &root, segments: segs, value: value, fullPath: path)
        guard case .object(let newObj) = root else {
            // Toppen ble ikke objekt (kunne skje hvis path er tom)
            throw KeyPathError.invalidPath("Root must remain an object for Object.set")
        }
        self = newObj
    }
    
    mutating func set(keypath path: String, setValue value: ValueType) throws {
        let segs = try KeyPathParser.parse(path)
        var root: ValueType = .object(self)
        try Navigator.set(root: &root, segments: segs, value: value, fullPath: path)
        guard case .object(let newObj) = root else {
            // Toppen ble ikke objekt (kunne skje hvis path er tom)
            throw KeyPathError.invalidPath("Root must remain an object for Object.set")
        }
        self = newObj
    }
}

// MARK: - Små demotester

#if DEBUG
func _demo() throws {
    var obj: Object = [:]

    try obj.set(.string("Kjetil"), keypath: "user.profile.name")
    try obj.set(.integer(17),       keypath: "user.age")

    // Lag liste og append to elementer
    try obj.set(.object(["id": .integer(1), "name": .string("A")]), keypath: "users[+]")
    try obj.set(.object(["id": .integer(2), "name": .string("B")]), keypath: "users[+]")

    // Sett felt på element hvor id=2
    try obj.set(.string("Bjørn"), keypath: "users[id=2].name")

    // Append et nytt element ved match (ikke funnet -> opprettes)
    try obj.set(.string("Cato"), keypath: "users[id=3].name")

    // Sett via indeks
    try obj.set(.bool(true), keypath: "users[0].active")

    // Hent
    let name = try obj.get(keypath: "user.profile.name")         // .string("Kjetil")
    let second = try obj.get(keypath: "users[1].name")           // .string("Bjørn")
    let third = try obj.get(keypath: "users[id=3].name")         // .string("Cato")

    CellBase.diagnosticLog("Object demo values: \(name), \(second), \(third)", domain: .flow)
}
#endif
