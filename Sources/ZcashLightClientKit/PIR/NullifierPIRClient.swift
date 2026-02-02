//
//  NullifierPIRClient.swift
//  ZcashLightClientKit
//
//  Nullifier PIR is deprecated in favor of txid PIR.
//  This stub maintains API compatibility while we transition.
//

import Foundation

// Nullifier PIR is disabled - NullifierCrypto dependency removed
// Use TxidPirClient for new PIR queries

/// DEPRECATED: Client for privacy-preserving nullifier lookups using PIR.
///
/// Nullifier PIR is being replaced with txid PIR. This class is a stub
/// that maintains API compatibility during the transition.
@available(*, deprecated, message: "Use TxidPirClient for new PIR queries")
public actor NullifierPIRClient {
    private let lightWalletService: LightWalletService

    init(lightWalletService: LightWalletService) {
        self.lightWalletService = lightWalletService
    }

    /// Initialize the PIR client.
    /// - Throws: PIRError.serviceNotReady (nullifier PIR is disabled)
    public func initialize() async throws {
        throw PIRError.serviceNotReady
    }

    /// Check if cryptographic keys are ready for queries.
    public var keysReady: Bool { false }

    /// Whether the client has been initialized.
    public var isInitialized: Bool { false }

    /// The PIR cutoff height (nil when disabled)
    public var pirCutoffHeight: BlockHeight? { nil }

    /// Check if a nullifier has been spent.
    /// - Throws: PIRError.serviceNotReady (nullifier PIR is disabled)
    public func checkNullifier(_ nullifier: Data) async throws -> SpentInfo? {
        throw PIRError.serviceNotReady
    }

    /// Check multiple nullifiers in batch.
    /// - Throws: PIRError.serviceNotReady (nullifier PIR is disabled)
    public func checkNullifiers(_ nullifiers: [Data]) async throws -> [SpentInfo?] {
        throw PIRError.serviceNotReady
    }
}
