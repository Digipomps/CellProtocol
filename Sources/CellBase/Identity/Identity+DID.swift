// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 07/02/2024.
//

import Foundation

public enum DidMethod {
    case cell
    case key
    case web
}

extension Identity {
    public func did(_ urlString: String? = nil, type: DidMethod = .key ) throws -> String {
        switch type {
        case .cell:
            if urlString == nil {
                let host = "http://\(CellBase.hostname):9089/identities/"
                guard let idUrlBase64 = "\(host)\(self.uuid)".data(using: .utf8)?.base64EncodedString() else  {
                    throw DIDError.invalidDID
                }
                
                return "did:cell:\(idUrlBase64)" // Should we get the host address form somewhere?
            } else {
                return "did:cell:\(urlString!)\(self.uuid)"
            }
            
        case .key:
            if let publicKeyData = self.publicSecureKey?.compressedKey,
               let curveType = self.publicSecureKey?.curveType {
                let multibase = try DIDKeyParser.multibaseEncodedPublicKey(publicKeyData, curveType: curveType)
                CellBase.diagnosticLog("Identity.did generated multikey identifier", domain: .identity)
                return "did:key:\(multibase)"
            }
            
        case .web:
            let urlSource = urlString ?? "https://\(CellBase.hostname)"
            return try DIDWebParser.did(from: urlSource)
        }
        
        
        // did key
        return "error no meaningful output"
    }
    
    public func didDocument() async throws -> DIDDocument {
        let didDocument = try DIDDocument(with: self)
        // set host for did here?
        return didDocument
        
    }

    public func didDocument(type: DidMethod, urlString: String? = nil) async throws -> DIDDocument {
        try DIDDocument(with: self, method: type, urlString: urlString)
    }
    
    public static func urlFromCellDid(_ did: String) throws -> URL {
        if !did.hasPrefix("did:") {
            throw DIDError.invalidDID
        }
        
        let methodDid = try stringFrom(string: did, index: 4)
        if !did.hasPrefix("cell:") {
            throw DIDError.invalidDID
        }
        let identityUrlBase64 = try stringFrom(string: methodDid, index: 5) // or should we use multibase?
        guard let identityUrlData = Data(base64Encoded: identityUrlBase64) else {
            throw DIDError.invalidDID
        }
        guard let identityUrlString = String(data: identityUrlData, encoding: .utf8) else {
            throw DIDError.invalidDID
        }
        
        guard let identityUrl = URL(string: identityUrlString) else {
            throw DIDError.invalidDID
        }
        
        return identityUrl
    }

    public static func urlFromWebDid(_ did: String) throws -> URL {
        try DIDWebParser.url(from: did)
    }
    
    enum StringError: Error {
        case slicingFailed
    }
    
    static func stringFrom(string: String, index: Int) throws -> String {
        if let to = string.index(string.startIndex, offsetBy: index, limitedBy: string.endIndex) {
                        return String(string[..<to])
        }
        throw StringError.slicingFailed
    }
}
