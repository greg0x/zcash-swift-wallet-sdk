//
//  PIRError.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

/// Errors that can occur during PIR operations.
public enum PIRError: Error, Equatable {
    /// Failed to create PIR client (connection to server failed).
    case clientCreationFailed(String)
    
    /// Failed to precompute cryptographic keys.
    case keyPrecomputationFailed(String)
    
    /// PIR keys have not been precomputed yet.
    case keysNotReady
    
    /// The provided nullifier data is invalid (must be 32 bytes).
    case invalidNullifierLength(Int)
    
    /// PIR query failed.
    case queryFailed(String)
    
    /// The PIR client has not been initialized.
    case clientNotInitialized
}

extension PIRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .clientCreationFailed(let message):
            return "Failed to create PIR client: \(message)"
        case .keyPrecomputationFailed(let message):
            return "Failed to precompute PIR keys: \(message)"
        case .keysNotReady:
            return "PIR keys have not been precomputed"
        case .invalidNullifierLength(let length):
            return "Invalid nullifier length: expected 32 bytes, got \(length)"
        case .queryFailed(let message):
            return "PIR query failed: \(message)"
        case .clientNotInitialized:
            return "PIR client has not been initialized"
        }
    }
}
