// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 08/12/2022.
//

import Foundation

public protocol BridgeDelegateProtocol {
    func consumeCommand(command: BridgeCommand) async throws
    func consumeResponse(command: BridgeCommand) async throws
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async
    var uuid: String { get }
    func pushError(errorMessage: String?, error: Error?) async
    func ready() async throws
}

public protocol BridgeBaseProtocol {
    func setup(_ valueType: ValueType) async throws // Set up transportation
    func setup(endpointURL: URL, identity: Identity) async throws
}

public enum TransportError: Error {
    case TransportNotFound
    case InvalidURL
    case UnrecognisedScheme
    case DataToStringError
}

public protocol BridgeTransportProtocol {
//    func setDelegateSource(_ source: (() async throws -> BridgeDelegateProtocol?)?)
    func setDelegate(_ delegate: BridgeDelegateProtocol)
    func setup(_ endpointURL: URL, identity: Identity) async throws // Set up transportation
    func sendData(_ data: Data) async throws
    func identityVault(for: Identity?) async -> IdentityVaultProtocol
    static func new() -> BridgeTransportProtocol
}
