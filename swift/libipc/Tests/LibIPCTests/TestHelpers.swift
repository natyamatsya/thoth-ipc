// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

/// Actor-isolated counter for use in concurrent tests.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
