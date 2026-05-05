// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CommonsPaths {
    public static func defaultRootURL(from currentDirectoryPath: String = FileManager.default.currentDirectoryPath) -> URL {
        URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
    }

    public static func taxonomiesURL(root: URL = defaultRootURL()) -> URL {
        root.appendingPathComponent("taxonomies", isDirectory: true)
    }

    public static func keypathsURL(root: URL = defaultRootURL()) -> URL {
        root.appendingPathComponent("keypaths", isDirectory: true)
    }

    public static func schemasURL(root: URL = defaultRootURL()) -> URL {
        root.appendingPathComponent("schemas", isDirectory: true)
    }
}
