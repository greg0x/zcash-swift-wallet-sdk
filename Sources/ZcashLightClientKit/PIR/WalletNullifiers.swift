//
//  WalletNullifiers.swift
//  ZcashLightClientKit
//
//  Utilities for retrieving nullifiers from the wallet database.
//

import Foundation
import libzcashlc

/// Provides access to wallet nullifier data for PIR verification.
///
/// This utility allows retrieving unspent nullifiers from the wallet database,
/// which can then be checked against a PIR server to verify no double-spends
/// have occurred without revealing which notes are owned.
public enum WalletNullifiers {
    
    /// Retrieves all unspent nullifiers from the wallet database.
    ///
    /// Returns nullifiers for both Sapling and Orchard notes that:
    /// - Have been confirmed in a mined transaction
    /// - Have not been marked as spent
    ///
    /// These nullifiers can be passed to a PIR server to verify none have
    /// been double-spent, without revealing which specific nullifiers belong
    /// to this wallet.
    ///
    /// - Parameters:
    ///   - dataDbURL: URL to the wallet database file
    ///   - networkType: The Zcash network (mainnet or testnet)
    /// - Returns: Array of 32-byte nullifier `Data` objects
    /// - Throws: `PIRError.walletReadFailed` if database cannot be read
    public static func getUnspentNullifiers(
        dataDbURL: URL,
        networkType: NetworkType
    ) throws -> [Data] {
        let dbPath = dataDbURL.path
        let pathBytes = dbPath.utf8CString
        
        let result = pathBytes.withUnsafeBufferPointer { pathPtr -> OpaquePointer? in
            // Convert CChar buffer to UInt8 pointer, excluding the null terminator
            pathPtr.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: pathPtr.count - 1) { ptr in
                zcashlc_pir_get_unspent_nullifiers(
                    ptr,
                    UInt(pathPtr.count - 1), // Exclude null terminator
                    networkType.networkId
                )
            }
        }
        
        guard let arrayPtr = result else {
            throw PIRError.walletReadFailed(
                lastPIRErrorMessage(fallback: "Failed to read unspent nullifiers from wallet")
            )
        }
        
        defer { zcashlc_pir_free_nullifier_array(arrayPtr) }
        
        let array = arrayPtr.pointee
        
        guard array.count > 0, let dataPtr = array.data else {
            return []
        }
        
        // Convert contiguous byte buffer to array of 32-byte Data objects
        var nullifiers: [Data] = []
        nullifiers.reserveCapacity(Int(array.count))
        
        for i in 0..<Int(array.count) {
            let offset = i * 32
            let nullifierData = Data(bytes: dataPtr.advanced(by: offset), count: 32)
            nullifiers.append(nullifierData)
        }
        
        return nullifiers
    }
}

// MARK: - Internal Helpers

/// Get the last error message from the FFI layer.
private func lastPIRErrorMessage(fallback: String) -> String {
    let errorLen = zcashlc_last_error_length()
    defer { zcashlc_clear_last_error() }
    
    if errorLen > 0 {
        let error = UnsafeMutablePointer<Int8>.allocate(capacity: Int(errorLen))
        defer { error.deallocate() }
        
        zcashlc_error_message_utf8(error, errorLen)
        if let errorMessage = String(validatingUTF8: error) {
            return errorMessage
        }
    }
    
    return fallback
}
