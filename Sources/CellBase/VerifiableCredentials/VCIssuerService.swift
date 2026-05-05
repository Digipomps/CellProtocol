// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 15/04/2024.
//

import Foundation

/*
 Issuer takes an Identity or DID and a claim and mint a VC
 
 */

struct VCIssuerService {
    
    func mintVC(for identity: Identity, claiming claim: ValueType, type: String ) async throws -> VCClaim {
        if case let .object(claimObject) = claim {
            return try await mintVC(for: identity, claiming: claimObject, type: type)
        }
        throw ValueTypeError.unexpectedValueType
    }
    

    func mintVC(for identity: Identity, claiming claim: Object, type: String ) async throws -> VCClaim {
        let issuerIdentity = Identity() // An identity representing the Issuer Entity. Use same for same type of claim
        
        // verifiy credential subject before signing - how?
        
        
        var verifiableClaim = try await VCClaim(type: type, issuerIdentity: issuerIdentity, subjectIdentity: identity, credentialSubject: claim)
        
        return verifiableClaim
    }
    
}
