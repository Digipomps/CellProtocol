// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  VCProofView.swift
//  CellUtility
//
//  Created by Kjetil Hustveit on 04/04/2024.
//

import SwiftUI
import CellBase

struct VCProofView: View {
    let vcProof: VCProof
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Type: ")
                Text(vcProof.type.rawValue)
            }
            HStack {
                Text("Created: ")
                Text(dateToString(vcProof.created))
            }
            HStack {
                Text("proofPurpose: ")
                Text(vcProof.proofPurpose.rawValue)
            }
            HStack {
                Text("verificationMethod: ")
                Text(vcProof.verificationMethod)
            }
            Text("Jws: ") // TODO: let this reflect output format
            Text(vcProof.signatureData.base64EncodedString())
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
        VCProofView(vcProof: generateVCProof())
}

func generateVCProof() -> VCProof {
    let vcProof = VCProof(proofPurpose: .assertionMethod, issuerIdentity: Identity())

    return vcProof
}
