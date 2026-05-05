// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

//public protocol CloudBridgeProtocol: CellProtocol, OwnerInstantiable {
//    func signMessageForIdentity(messageData: Data, identity: Identity) -> AnyPublisher<Data, Error>
//}

public protocol BridgeProtocol: CellProtocol, OwnerInstantiable {
    func signMessageForIdentity(messageData: Data, identity: Identity) -> AnyPublisher<Data, Error>
}
