//
//  PIRError.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

/// Errors that can occur during PIR operations.
public enum PIRError: Error, Equatable {
    /// The PIR client has not been initialized.
    /// Call `initialize()` before making queries.
    case clientNotInitialized
    
    /// PIR keys have not been precomputed yet.
    case keysNotReady
    
    /// The PIR service is not ready to handle queries.
    case serviceNotReady
    
    /// The provided nullifier data is invalid (must be 32 bytes).
    case invalidNullifierLength(Int)
    
    /// Server returned invalid or incomplete parameters.
    case invalidServerParams(String)
    
    /// A cryptographic operation failed (query generation, decryption, etc.).
    case cryptoError(String)
    
    /// A network operation failed (gRPC call to lightwalletd).
    case networkError(String)
    
    /// PIR query failed.
    case queryFailed(String)
    
    /// Failed to read from wallet database.
    case walletReadFailed(String)
    
    // MARK: - Deprecated (kept for compatibility)
    
    /// Failed to create PIR client (connection to server failed).
    /// Deprecated: Use `networkError` instead.
    case clientCreationFailed(String)
    
    /// Failed to precompute cryptographic keys.
    /// Deprecated: Use `cryptoError` instead.
    case keyPrecomputationFailed(String)
}

extension PIRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "PIR client has not been initialized"
        case .keysNotReady:
            return "PIR keys have not been precomputed"
        case .serviceNotReady:
            return "PIR service is not ready"
        case .invalidNullifierLength(let length):
            return "Invalid nullifier length: expected 32 bytes, got \(length)"
        case .invalidServerParams(let message):
            return "Invalid server parameters: \(message)"
        case .cryptoError(let message):
            return "PIR crypto error: \(message)"
        case .networkError(let message):
            return "PIR network error: \(message)"
        case .queryFailed(let message):
            return "PIR query failed: \(message)"
        case .walletReadFailed(let message):
            return "Failed to read from wallet: \(message)"
        case .clientCreationFailed(let message):
            return "Failed to create PIR client: \(message)"
        case .keyPrecomputationFailed(let message):
            return "Failed to precompute PIR keys: \(message)"
        }
    }
}
