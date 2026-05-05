// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum GrantError: Error {
    case denied
    case otherError
}

public enum FlowError: Error {
    case noResolver
    case denied
    case noIdentity
}

public enum CellBaseError: Error {
    case noResolver
    case noVault
    case noIdentity
    case noIdentityUUID
    case noTargetCell
    case noSourceCell
    case noTargetMeddleCell
    case noTargetEmitCell
    case noTypedCellUtility
    case noDocumentRoot
    case notImplemented
}

public enum KeychainError: Error {
    case noPassword
    case unexpectedPasswordData
}

public enum IdentityVaultError: Error {
    case publisherGone
    case signingFailed
    case noVaultIdentity
    case notImplemented
    case noKey
    case invalidFilename
}

enum DecodingPDSError: Error {
    case corruptedData
}

public enum DecodingError: Error {
    case corruptedData
    case typeMismatch // This error really resides elsewhere
}

public enum DataError: Error {
    case conversionFailed
    case unknownCase
}

public enum KeypathStorageErrors: Error {
    case noStorage
    case notFound
    case denied
    case objectFailure
    case otherError
}


public enum ConditionError : Error {
    case denied
    case noTargetOwner
    case noSourceOwner
    case noRequester
    case conditionError
}
