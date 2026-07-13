// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A capability bitmask rendered canonically as `rwxs`.
///
/// `s` authorizes persistent retention of output. It is evidence carried by an
/// identity-bound Agreement/Contract; it is not a technical copy-prevention
/// mechanism and does not by itself authorize forwarding or redistribution.
public struct Permission : Codable, Equatable {
    public var uuid: String
    
    
    static let r = 0b00000100 // read 4
    static let w = 0b00000010 // write 2
    static let x = 0b00000001 // execute 1
    static let s = 0b00001000 // storage 8

    static let rw = Permission.r | Permission.w
    static let rwx = Permission.r | Permission.w | Permission.x
    static let rwxs = Permission.r | Permission.w | Permission.x | Permission.s
    
    
//    let user: Int
    var group: Int
    var other: Int
    
    
    public var permissionString: String {
        get {
            var perm = ""
            if group & Permission.r == Permission.r {
                perm += "r"
            } else {
                perm += "-"
            }
            if group & Permission.w == Permission.w {
                perm += "w"
            } else {
                perm += "-"
            }
            if group & Permission.x == Permission.x {
                perm += "x"
            } else {
                perm += "-"
            }
            if group & Permission.s == Permission.s {
                perm += "s"
            } else {
                perm += "-"
            }
            return perm
        }
        set {
            setPermissions(permissionString: newValue)
        }
    }
    
    enum CodingKeys: String, CodingKey
    {
        case uuid
        //        case endpoint
//        case user
        case group
        case other
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let suppliedUuid = try? values.decode(String.self, forKey: .uuid) {
            uuid = suppliedUuid
            
        } else {
            uuid = UUID.init().uuidString
            
        }
        //        if values.contains(.endpointId) {
        //            endpointId = try  values.decode(String.self, forKey: .endpointId)
        //        }
        //        if values.contains(.endpoint) {
        //            endpoint =  try  values.decode(String.self, forKey: .endpoint)
        //        }
//        user = try  values.decode(Int.self, forKey: .user)
        group = try  values.decode(Int.self, forKey: .group)
        other = try  values.decode(Int.self, forKey: .other)
    }
    
    init(_ permissionDescription: String) {
        if let parsed = Permission.parse(permissionDescription) {
            group = parsed.group
            other = parsed.other
        } else {
            group = 0
            other = 0
        }
        uuid = UUID.init().uuidString
    }
    
    
    public func encode(to encoder: Encoder) throws {
        //        print("encoding: \(self)")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(group, forKey: .group)
        try container.encode(other, forKey: .other)
        
    }

    static func parse(_ permissionDescription: String) -> (group: Int, other: Int)? {
        let trimmed = permissionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // Three- and six-character forms are legacy text compatibility paths.
        // New code emits four/eight characters; legacy input never infers storage.
        if trimmed.count == 3 {
            guard let group = permissionTripletToInt(trimmed) else { return nil }
            return (group, 0)
        }

        if trimmed.count == 4,
           let group = permissionQuadToInt(trimmed) {
            return (group, 0)
        }

        if trimmed.count == 6 {
            let groupIndex = trimmed.index(trimmed.startIndex, offsetBy: 3)
            guard
                let group = permissionTripletToInt(String(trimmed.prefix(upTo: groupIndex))),
                let other = permissionTripletToInt(String(trimmed[groupIndex...]))
            else {
                return nil
            }
            return (group, other)
        }

        if trimmed.count == 8 {
            let groupIndex = trimmed.index(trimmed.startIndex, offsetBy: 4)
            guard
                let group = permissionQuadToInt(String(trimmed.prefix(upTo: groupIndex))),
                let other = permissionQuadToInt(String(trimmed[groupIndex...]))
            else {
                return nil
            }
            return (group, other)
        }

        return nil
    }

    static func stringToPermissionInt(_ permissionString: String) -> Int {
        return parse(permissionString)?.group ?? 0
    }
    
    static func stringToPermissionInt(_ permissionString: String.SubSequence) -> Int {
        return stringToPermissionInt(String(permissionString))
    }

    private static func permissionTripletToInt(_ permissionString: String) -> Int? {
        guard permissionString.count == 3 else { return nil }
        var permission = 0

        let firstIndex = permissionString.index(permissionString.startIndex, offsetBy: 0)
        let secondIndex = permissionString.index(permissionString.startIndex, offsetBy: 1)
        let thirdIndex = permissionString.index(permissionString.startIndex, offsetBy: 2)

        switch permissionString[firstIndex] {
        case "r":
            permission += Permission.r
        case "-":
            break
        default:
            return nil
        }

        switch permissionString[secondIndex] {
        case "w":
            permission += Permission.w
        case "-":
            break
        default:
            return nil
        }

        switch permissionString[thirdIndex] {
        case "x":
            permission += Permission.x
        case "-":
            break
        default:
            return nil
        }

        return permission
    }

    private static func permissionQuadToInt(_ permissionString: String) -> Int? {
        guard permissionString.count == 4 else { return nil }
        let triplet = String(permissionString.prefix(3))
        guard var permission = permissionTripletToInt(triplet) else {
            return nil
        }

        let fourthIndex = permissionString.index(permissionString.startIndex, offsetBy: 3)
        switch permissionString[fourthIndex] {
        case "s":
            permission += Permission.s
        case "-":
            break
        default:
            return nil
        }

        return permission
    }
    
    func matchGroupPermission(permission: Int) -> Bool {
        /*
         011
         & 111
         = 011
         */
        
        guard permission != 0 else { return false }
        return group & permission == permission
    }
    
    func matchOtherPermission(permission: Int) -> Bool {
        guard permission != 0 else { return false }
        return other & permission == permission
    }
    
    static func matchPermission(permissionRequested: String, permissionGranted: String) -> Bool {
        guard
            let requested = parse(permissionRequested),
            let granted = parse(permissionGranted)
        else {
            return false
        }
        return matchPermission(permissionRequested: requested.group, permissionGranted: granted.group)
    }
    
    static func matchPermission(permissionRequested: Int, permissionGranted: Int) -> Bool {
        guard permissionRequested != 0 else { return false }
        return permissionGranted & permissionRequested == permissionRequested
    }
    
    mutating func setPermissions(permissionString: String) {
        if let parsed = Permission.parse(permissionString) {
            group = parsed.group
            other = parsed.other
        } else {
            group = 0
            other = 0
        }
    }
    
    mutating func isGrantedForIdentity(identity: Identity, group: GroupProtocol, requestedAccess: String) -> Bool {
        let requestedPermission = Permission.stringToPermissionInt(requestedAccess)
        //        if uuid == self.endpoint?.owner?.uuid {
        //            return true
        //        }
        //Need to fix this in regard to whom can check
        //        if matchUserPermission(permission: requestedPermission) && group.isMember(identity: identity, requester: self.endpoint?.owner?) {
        //            return true
        //        }
        
        return matchOtherPermission(permission: requestedPermission)
    }
    
    public func description() -> String {
        return "group: \(Permission.permissionString(for: group)) other: \(Permission.permissionString(for: other))"
    }

    private static func permissionString(for permission: Int) -> String {
        var result = ""
        result += permission & Permission.r == Permission.r ? "r" : "-"
        result += permission & Permission.w == Permission.w ? "w" : "-"
        result += permission & Permission.x == Permission.x ? "x" : "-"
        result += permission & Permission.s == Permission.s ? "s" : "-"
        return result
    }
}
