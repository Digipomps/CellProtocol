// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct Permission : Codable, Equatable {
    public var uuid: String
    
    
    static let r = 0b00000100 // read 1
    static let w = 0b00000010 // write 2
    static let x = 0b00000001 // execute 4

    static let rw = 0b00000011
    static let rwx = 0b00000111
//    static let rwxs = 0b00001111
    
    
//    let user: Int
    let group: Int
    let other: Int
    
    
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
        
        if permissionDescription.count == 3 {
            
            group = Permission.stringToPermissionInt(permissionDescription)
            other = 0
        } else if permissionDescription.count == 6 {
            let groupIndex = permissionDescription.index(permissionDescription.startIndex, offsetBy: 3)
//            let otherIndex = permissionDescription.index(permissionDescription.endIndex, offsetBy: -3)
            
            
            let ownerStringDescription = permissionDescription.prefix(upTo: groupIndex)
            group = Permission.stringToPermissionInt(ownerStringDescription)
            
//            let groupStringDescription = permissionDescription[groupRange]
//            group = Permission.stringToPermissionInt(groupStringDescription)
            
            let otherStringDescription = permissionDescription[groupIndex...]
            other = Permission.stringToPermissionInt( otherStringDescription )
            
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
    static func stringToPermissionInt(_ permissionString: String) -> Int {
        var permission = 0
        
        let firstIndex = permissionString.index(permissionString.startIndex, offsetBy: 0)
        let secondIndex = permissionString.index(permissionString.startIndex, offsetBy: 1)
        let thirdIndex = permissionString.index(permissionString.startIndex, offsetBy: 2)
//        let endIndex = permissionString.index(permissionString.endIndex, offsetBy: -1)
        
        if (permissionString[firstIndex] == "r") {
            permission += Permission.r
        }
        
        if (permissionString[secondIndex] == "w") {
            permission += Permission.w
        }
        if (permissionString[thirdIndex] == "x") {
            permission += Permission.x
        }
        
//        print("permissionString: \(permissionString) gave permission: \(permission)")
        return permission
    }
    
    static func stringToPermissionInt(_ permissionString: String.SubSequence) -> Int {
        var permission = 0
        
        let firstIndex = permissionString.index(permissionString.startIndex, offsetBy: 0)
        let secondIndex = permissionString.index(permissionString.startIndex, offsetBy: 1)
        let thirdIndex = permissionString.index(permissionString.startIndex, offsetBy: 2)
//        let endIndex = permissionString.index(permissionString.endIndex, offsetBy: -1)
        
        if (permissionString[firstIndex] == "r") {
            permission += Permission.r
        }
        
        if (permissionString[secondIndex] == "w") {
            permission += Permission.w
        }
        if (permissionString[thirdIndex] == "x") {
            permission += Permission.x
        }
        
//        print("permissionString: \(permissionString) gave permission: \(permission)")
        return permission
    }
    
    func matchGroupPermission(permission: Int) -> Bool {
        /*
         011
         & 111
         = 011
         */
        
        return group & permission == permission
    }
    
    func matchOtherPermission(permission: Int) -> Bool {
        return other & permission == permission
    }
    
    static func matchPermission(permissionRequested: String, permissionGranted: String) -> Bool {
        return matchPermission(permissionRequested: stringToPermissionInt(permissionRequested), permissionGranted: stringToPermissionInt(permissionGranted))
    }
    
    static func matchPermission(permissionRequested: Int, permissionGranted: Int) -> Bool {
        return permissionGranted & permissionRequested == permissionRequested
    }
    
    func setPermissions(permissionString: String) {
        let other = Permission.stringToPermissionInt(permissionString)
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
        return "user: rwx group: \(group) other: \(other)"
    }
}
