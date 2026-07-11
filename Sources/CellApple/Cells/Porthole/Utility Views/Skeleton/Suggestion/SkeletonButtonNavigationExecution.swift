// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

public enum SkeletonButtonNavigationExecution {
    @MainActor
    public static func open(
        _ button: SkeletonButton,
        relativeTo baseURL: URL? = SkeletonButtonNavigation.configuredBaseURL(),
        using opener: (URL, @escaping (Bool) -> Void) -> Void
    ) async -> Bool {
        guard let url = SkeletonButtonNavigation.resolveURL(for: button, relativeTo: baseURL) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            opener(url) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}
