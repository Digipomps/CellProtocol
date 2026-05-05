// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  KeypathExpression.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 26/05/2025.
//
import Foundation

enum ParsedValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([ParsedValue])

    var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .date(let v): return v
        case .array(let v): return v.map { $0.rawValue }
        }
    }
}

struct AnyKeypathExpression {
    let keypathComponents: [String]
    let operatorString: String
    let value: ParsedValue
    var keypath: String {
        get {
            return keypathComponents.joined(separator: ".")
        }
    }
    var shortenendKeypath: String {
        get {
            if keypathComponents.count > 1 {
                return keypathComponents[ 1 ... keypathComponents.count - 1].joined(separator: ".")
            }
            return ""
        }
    }
    
    var keypathContext: String {
        get {
            return keypathComponents[0]
        }
    }
    
    static func parseStatement(_ statement: String) -> AnyKeypathExpression? {
        let pattern = #"^([a-zA-Z0-9._]+)\s*(=|==|!=|>=|<=|>|<|IN)\s*(.+)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)
        guard let match = regex.firstMatch(in: statement, options: [], range: range),
              match.numberOfRanges == 4 else {
            return nil
        }

        let keypath = String(statement[Range(match.range(at: 1), in: statement)!])
        let op = String(statement[Range(match.range(at: 2), in: statement)!])
        let valueString = String(statement[Range(match.range(at: 3), in: statement)!]).trimmingCharacters(in: .whitespaces)

        // ARRAY: Brukes med IN eller lignende og angis som ["val1", "val2"] eller [1, 2, 3]
        if valueString.hasPrefix("[") && valueString.hasSuffix("]") {
            let contents = valueString.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            let items = contents.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let parsedItems: [ParsedValue] = items.compactMap { item in
                let unquoted = item.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return parseSingleValue(unquoted)
            }

            return AnyKeypathExpression(
                keypathComponents: keypath.components(separatedBy: "."),
                operatorString: op,
                value: .array(parsedItems)
            )
        }

        // Enkel verdi
        let cleaned = valueString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if let parsed = parseSingleValue(cleaned) {
            return AnyKeypathExpression(
                keypathComponents: keypath.components(separatedBy: "."),
                operatorString: op,
                value: parsed
            )
        }

        return nil
    }

    private static func parseSingleValue(_ value: String) -> ParsedValue? {
        if let boolValue = Bool(value) {
            return .bool(boolValue)
        } else if let intValue = Int(value) {
            return .int(intValue)
        } else if let doubleValue = Double(value) {
            return .double(doubleValue)
        } else if let date = ISO8601DateFormatter().date(from: value) {
            return .date(date)
        } else {
            return .string(value)
        }
    }
    
    func joinKeypathComponents(_ components: [String]) -> String {
        return components.joined(separator: ".")
    }
}


func testParser() {
    // Bool
    print(AnyKeypathExpression.parseStatement("identity.person.human = true") as Any)

    // Int
    print(AnyKeypathExpression.parseStatement("identity.person.age >= 18") as Any)

    // Double
    print(AnyKeypathExpression.parseStatement("identity.person.body.weight < 100.0") as Any)

    // String
    print(AnyKeypathExpression.parseStatement("identity.person.name.last = \"Kjetil\"") as Any)

    // Date (ISO8601)
    print(AnyKeypathExpression.parseStatement("identity.person.birthday = 2023-12-24T12:00:00Z") as Any)

    // Array (Strings)
    print(AnyKeypathExpression.parseStatement("identity.person.tags IN [\"admin\", \"user\"]") as Any)

    // Array (Numbers)
    print(AnyKeypathExpression.parseStatement("identity.person.scores IN [1, 2, 3.5]") as Any)
}

/*
 extension Array where Element == String {
     func joinedAsKeypath() -> String {
         return self.joined(separator: ".")
     }
 }

 // Bruk:
 let keypath = ["identity", "person", "name"].joinedAsKeypath()
 print(keypath)  // "identity.person.name"
 */


/*
 identity.person.human = true
 identity.person.age >= 18
 identity.person.body.weight < 100.0
 identity.person.name.last = "Kjetil"
 */
