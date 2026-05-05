// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct Grant: Codable, Equatable {
    public static func == (lhs: Grant, rhs: Grant) -> Bool {
        //        return lhs.keypath == rhs.keypath && lhs.permission == rhs.permission ...must decode Permission
        return lhs.keypath == rhs.keypath
    }
    
    public var uuid: String
    public var name: String
    public var permission: Permission
    public var keypath: String
    
    enum CodingKeys: String, CodingKey
    {
        case uuid
        case name
        case permission
        case keypath
    }
    
    public init() {
        uuid = UUID().uuidString
        name = "test grant"
        permission = Permission("r--")
        keypath =  "identity.displayName"
    }
    
    public init(_ name: String? = nil, keypath: String, permission: String) {
        uuid = UUID().uuidString
        self.name = name ?? "Condition grant"
        self.keypath = keypath
        self.permission = Permission(permission)
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decodeIfPresent(String.self, forKey: .uuid) ?? UUID().uuidString
        name = try values.decode(String.self, forKey: .name)
        permission = try values.decode(Permission.self, forKey: .permission)
        keypath = try values.decode(String.self, forKey: .keypath)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(permission, forKey: .permission)
        try container.encode(keypath, forKey: .keypath)
    }
    
    var keypathComponents: [Substring]? {
        get {
            return keypath.split(separator: ".")
        }
    }
    
    public func granted(_ grant: Grant) -> Bool {
        var granted = false
        if self.keypath == grant.keypath {
            if (self.permission.matchGroupPermission(permission: grant.permission.group)) { // Must be implemented to match all
                granted = true
            }
        }
        
        return granted
    }
    public func childGrant() -> Grant? {
        var childGrant: Grant?
        if let keypathArray = self.keypathComponents{
            if keypathArray.count >= 2 {
                let childKeypath = String(self.keypath.dropFirst("\(keypathArray[0]).".count))
                childGrant = Grant(keypath: childKeypath, permission: permission.permissionString)
            }
        }
        return childGrant
    }
}
