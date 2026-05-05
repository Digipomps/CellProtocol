// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import HavenCoreSchemas

public enum PathURI {
    public static func make(entityId: String, path: String) -> String {
        "haven://entity/\(entityId)#\(withoutLeadingHash(path))"
    }

    public static func makeSelf(path: String) -> String {
        make(entityId: "self", path: path)
    }

    public static func parse(_ uri: String) -> (entityId: String, path: String)? {
        guard uri.hasPrefix("haven://entity/") else {
            return nil
        }

        let remainder = String(uri.dropFirst("haven://entity/".count))
        guard let hashIndex = remainder.firstIndex(of: "#") else {
            return nil
        }

        let entityId = String(remainder[..<hashIndex])
        let pathPart = String(remainder[hashIndex...])
        return (entityId, JSONPointer.normalize(pathPart))
    }

    private static func withoutLeadingHash(_ path: String) -> String {
        let normalized = JSONPointer.normalize(path)
        return String(normalized.dropFirst())
    }
}
