// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import LocalAuthentication
import CellBase

public struct CellApple {
    public private(set) var text = "Hello, World!"
    
    public init() {
    }
    
    public static func getDocumentsDirectory() -> URL {
        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    
    public static func getCellsDocumentsDirectory() -> URL {
        getDocumentsDirectory().appendingPathComponent("CellsContainer")
    }
    
    public static func aquireKeyForTag(tag: String) async throws -> Data {
        let access = SecAccessControlCreateWithFlags(nil, // Use the default allocator.
                                                     kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                     .userPresence,
                                                     nil) // Ignore any error.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        
        
        let searchQuery: [String: Any] = [kSecClass as String: kSecClassKey,
                                          kSecAttrApplicationTag as String: tag,
                                          //                                       kSecAttrKeyType as String: kSecAttrKeyType,
                                          kSecMatchLimit as String: kSecMatchLimitOne,
                                          kSecReturnAttributes as String: true,
                                          kSecReturnData as String: true]
        
        var item: CFTypeRef?
        let searchStatus = SecItemCopyMatching(searchQuery as CFDictionary, &item)
        
        guard searchStatus != errSecItemNotFound else {
            throw KeychainError.noPassword
        }
        guard searchStatus == errSecSuccess else {
            print("Got unhandled error when matchin secItem! Status: \(searchStatus)")
            throw KeychainError.unhandledError(status: searchStatus)
        }
        guard let existingItem = item as? [String : Any],
              let keyData = existingItem[kSecValueData as String] as? Data
        else {
            print("Extracting credentials failed")
            throw KeychainError.unexpectedPasswordData

        }
        return keyData
    }
    
    public static func persistKeyForTag(tag: String, keyData: Data) async throws {
        let access = SecAccessControlCreateWithFlags(nil,
                                                     kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                     .userPresence,
                                                     nil)
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
#if targetEnvironment(simulator)
            // "Bug in simulator causes AecItemAdd to fail if kSecAttrAccessControl is used"
            let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                        kSecAttrApplicationTag as String: tag,
                                        kSecUseAuthenticationContext as String: context,
                                        kSecValueData as String: keyData]
            
#else
            
            let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                        kSecAttrApplicationTag as String: tag,
                                        kSecAttrAccessControl as String: access, // as Any
                                        
                                        kSecUseAuthenticationContext as String: context,
                                        kSecValueData as String: keyData]
            
#endif
            
            
            var status = SecItemAdd(query as CFDictionary, nil)
        if status == -25299 { // Sec Item exists
            print("Trying to update sec item")
            let updateDict: [String: Any] = [kSecValueData as String: keyData]
            status = SecItemUpdate(query as CFDictionary, updateDict as CFDictionary)
        }
            guard status == errSecSuccess else {
                print("Adding sec item failed! Status: \(status)")
                
                if let errorMessage = SecCopyErrorMessageString(status, nil) {
                  print("Error message: \(String(errorMessage))")
                } else {
                  print("Status Code: \(status)")
                }
                
                
                throw KeychainError.unhandledError(status: status)
            }
    }
}
