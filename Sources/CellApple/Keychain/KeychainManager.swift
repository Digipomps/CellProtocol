// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  KeychainManager.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 30/01/2026.
//


import Foundation
import Security

class KeychainManager {
    
    // Singleton-instans for enkel tilgang
    static let shared = KeychainManager()
    
    private init() {}
    
    /// Lagrer en API-nøkkel sikkert
    func save(key: String, account: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        
        // Slett eventuell gammel nøkkel først for å unngå duplikater
        delete(account: account)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly // Høy sikkerhet
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Henter API-nøkkel
    func retrieve(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    /// Sletter API-nøkkel
    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}


/*
 
 // For å lagre nøkkelen (f.eks. ved første oppstart eller login)
 let apiKey = "din_hemmelige_gemini_api_nøkkel"
 let success = KeychainManager.shared.save(key: apiKey, account: "com.dinapp.geminiKey")

 if success {
     print("Nøkkel lagret trygt i Keychain!")
 }

 // For å hente nøkkelen når du skal gjøre et API-kall
 if let savedKey = KeychainManager.shared.retrieve(account: "com.dinapp.geminiKey") {
     // Bruk savedKey i Gemini-konfigurasjonen
     print("Fant nøkkel: \(savedKey)") // Kun for debugging, fjern i prod!
 }
 
 */
