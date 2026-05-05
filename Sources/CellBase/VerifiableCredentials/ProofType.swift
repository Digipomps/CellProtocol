// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ProofType: String, Codable {
    case EcdsaSecp256r1Signature2019
    case Ed25519Signature2018
    case Ed25519Signature2020
    case RsaSignature2018 // We will not use this?
}
