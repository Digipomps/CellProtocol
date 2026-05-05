// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  VerifiableCredentialView.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 03/04/2024.
//

import SwiftUI
import CellBase

struct VerifiableCredentialView: View {
    let vcClaim: VCClaim
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Context:")
            if let context =  vcClaim.context {
                ForEach(context, id: \.self) { contextItem in
                    Text(contextItem)
                }
            }
            HStack {
                Text("id: ")
                Text(vcClaim.id)
            }
            Text("Type: ")
            
            ForEach(vcClaim.type, id: \.self) { type in
                Text(type)
            }
            HStack {
                Text("issuer: ")
                Text("vcClaim.issuer")
            }
            HStack {
                Text("issuanceDate: ")
                Text(dateToString(vcClaim.issuanceDate))
            }
            Text("credentialSubject: ")
            JsonViewerView(valueType:  .object(vcClaim.credentialSubject))
            Text("Proof: ")
            VCProofView(vcProof: vcClaim.proof)
        }
    }
    
    func dateToString(_ date: Date) -> String {
        let RFC3339DateFormatter = DateFormatter()
        RFC3339DateFormatter.locale = Locale(identifier: "en_US_POSIX")
        RFC3339DateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        RFC3339DateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let issuanceDateString = RFC3339DateFormatter.string(from: date)
        return issuanceDateString
    }
}

#Preview {
   
    VerifiableCredentialView(vcClaim: generateVCClaim())
//    VerifiableCredentialView()
}

func generateVCClaim() -> VCClaim {
    let issuerIdentity = Identity()
    let subjectIdentity = Identity()
    
    let credentialSubjectObject: Object = ["sumthang" : .string("with value")]
    
//    let credentialSubject = CredentialSubject(id: subjectIdentity.did(), claim: .object(credentialSubjectObject), claimLabel: "TestSubject")
    let vcClaim = VCClaim(
        issuerIdentity: issuerIdentity,
        subjectIdentity: subjectIdentity,
        credentialSubject: credentialSubjectObject)
 
//            Task {
//                try await vcClaim.proof.setSignature(credentialSubject, for: issuerIdentity)
//            }
    return vcClaim
}
/*
 case uuid
 case context = "@context"
 case id
 case type
 case issuer
 case issuanceDate
 case credentialSubject
 case proof
 */
