// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import LocalAuthentication
import CellBase

public struct CellApple {
    public private(set) var text = "Hello, World!"
    private static let testDocumentRootDirectoryName = "CellProtocolTests"
    
    public init() {
    }

    public static var isXCTestOrSwiftPMTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        if Bundle.main.bundlePath.contains(".xctest") {
            return true
        }

        return ProcessInfo.processInfo.arguments.contains { argument in
            argument.contains(".xctest")
        }
    }
    
    public static func getDocumentsDirectory() -> URL {
        if let documentRootPath = CellBase.documentRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           documentRootPath.isEmpty == false {
            let url = URL(fileURLWithPath: documentRootPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        if isXCTestOrSwiftPMTestHost {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(testDocumentRootDirectoryName, isDirectory: true)
                .appendingPathComponent("CellApple-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // find all possible documents directories for this user
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        
        // just send back the first one, which ought to be the only one
        return paths[0]
    }
    
    public static func getCellsDocumentsDirectory() -> URL {
        getDocumentsDirectory().appendingPathComponent("CellsContainer")
    }
    
    public static func aquireKeyForTag(tag: String) async throws -> Data {
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
            CellBase.diagnosticLog("Got unhandled error matching secItem. Status: \(searchStatus)", domain: .identity)
            throw KeychainError.unhandledError(status: searchStatus)
        }
        guard let existingItem = item as? [String : Any],
              let keyData = existingItem[kSecValueData as String] as? Data
        else {
            CellBase.diagnosticLog("Extracting credentials failed", domain: .identity)
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
                                        kSecAttrAccessControl as String: access as Any,
                                        
                                        kSecUseAuthenticationContext as String: context,
                                        kSecValueData as String: keyData]
            
#endif
            
            
            var status = SecItemAdd(query as CFDictionary, nil)
        if status == -25299 { // Sec Item exists
            CellBase.diagnosticLog("Trying to update existing sec item", domain: .identity)
            let updateDict: [String: Any] = [kSecValueData as String: keyData]
            status = SecItemUpdate(query as CFDictionary, updateDict as CFDictionary)
        }
            guard status == errSecSuccess else {
                if let errorMessage = SecCopyErrorMessageString(status, nil) {
                    CellBase.diagnosticLog("Adding sec item failed. Status: \(status) message: \(String(errorMessage))", domain: .identity)
                } else {
                    CellBase.diagnosticLog("Adding sec item failed. Status: \(status)", domain: .identity)
                }
                
                
                throw KeychainError.unhandledError(status: status)
            }
    }
}
