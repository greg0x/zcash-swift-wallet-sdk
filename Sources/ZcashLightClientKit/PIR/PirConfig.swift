//
//  PirConfig.swift
//  ZcashLightClientKit
//
//  Configuration for PIR-based transaction enhancement.
//

import Foundation

/// Configuration for PIR-based transaction enhancement.
///
/// PIR (Private Information Retrieval) allows the wallet to fetch transaction data
/// without revealing which transaction it's interested in to the server.
public struct PirConfig: Sendable {
    /// Enable PIR for transaction enhancement (production flag).
    /// When true, enhancement will attempt to use PIR instead of GetTransaction.
    public var isPirEnhanceEnabled: Bool

    /// DEBUG: Disable mempool sync to force enhancement path (testing only).
    /// When true, all transactions go through block sync → enhancement → PIR
    /// instead of receiving full data via mempool stream.
    public var debugDisableMempoolSync: Bool

    public init(
        isPirEnhanceEnabled: Bool = false,
        debugDisableMempoolSync: Bool = false
    ) {
        self.isPirEnhanceEnabled = isPirEnhanceEnabled
        self.debugDisableMempoolSync = debugDisableMempoolSync
    }

    /// Default configuration with PIR disabled.
    public static var `default`: PirConfig {
        PirConfig()
    }
}
