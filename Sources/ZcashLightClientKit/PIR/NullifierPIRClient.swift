//
//  NullifierPIRClient.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation
import libzcashlc

/// PIR protocol selection.
///
/// Choose based on your network constraints:
/// - `ypir`: Larger queries (~5.8 MB) but faster server processing
/// - `inspire`: Smaller queries (~416 KB) but longer key prep
public enum PIRProtocol: UInt32, Sendable {
    /// YPIR+SP protocol - larger queries (~5.8 MB), faster server
    case ypir = 0
    /// InsPIRe protocol - smaller queries (~416 KB), better for mobile
    case inspire = 1
    
    /// Convert to FFI enum value
    var ffiValue: FfiPirProtocol {
        switch self {
        case .ypir: return FfiPirProtocol(0)
        case .inspire: return FfiPirProtocol(1)
        }
    }
}

/// Client for privacy-preserving nullifier lookups using PIR.
///
/// This client connects to a PIR server and allows checking whether notes
/// have been spent without revealing which notes are being queried.
///
/// ## Usage
///
/// ```swift
/// // Create client with InsPIRe protocol (smaller queries for mobile)
/// let client = try await NullifierPIRClient(
///     serverURL: "https://pir.example.com",
///     protocol: .inspire
/// )
///
/// // Precompute cryptographic keys (expensive, do once)
/// try await client.precomputeKeys()
///
/// // Check if a nullifier has been spent
/// if let spentInfo = try await client.checkNullifier(nullifier) {
///     print("Note spent in block \(spentInfo.blockHeight)")
/// }
/// ```
public actor NullifierPIRClient {
    private var clientPtr: OpaquePointer?
    
    /// The PIR protocol in use.
    public let pirProtocol: PIRProtocol
    
    /// Initialize and connect to a PIR server.
    ///
    /// - Parameters:
    ///   - serverURL: Base URL of the PIR server (e.g., "https://pir.example.com")
    ///   - protocol: PIR protocol to use (default: `.inspire` for smaller mobile queries)
    /// - Throws: `PIRError.clientCreationFailed` if connection fails
    public init(serverURL: String, protocol pirProtocol: PIRProtocol = .inspire) throws {
        self.pirProtocol = pirProtocol
        
        // Match TorClient pattern - direct FFI call
        let ptr = serverURL.withCString { urlPtr in
            zcashlc_pir_client_create(urlPtr, pirProtocol.ffiValue)
        }
        
        guard let ptr else {
            throw PIRError.clientCreationFailed(
                lastPIRErrorMessage(fallback: "Unknown error creating PIR client")
            )
        }
        
        self.clientPtr = ptr
    }
    
    deinit {
        if let client = clientPtr {
            zcashlc_pir_client_free(client)
        }
    }
    
    /// Precompute cryptographic keys for fast queries.
    ///
    /// This is an expensive operation that generates the cryptographic material
    /// needed for PIR queries. It should be called once after initialization.
    /// Subsequent queries will be fast (~500ms).
    ///
    /// Timing varies by protocol:
    /// - **YPIR**: ~25 seconds
    /// - **InsPIRe**: ~3 seconds
    ///
    /// - Throws: `PIRError.keyPrecomputationFailed` if key generation fails
    public func precomputeKeys() throws {
        guard let client = clientPtr else {
            throw PIRError.clientNotInitialized
        }
        
        let success = zcashlc_pir_precompute_keys(client)
        
        guard success else {
            throw PIRError.keyPrecomputationFailed(
                lastPIRErrorMessage(fallback: "Unknown error during key precomputation")
            )
        }
    }
    
    /// Check if cryptographic keys are ready for queries.
    public var keysReady: Bool {
        guard let client = clientPtr else { return false }
        return zcashlc_pir_keys_ready(client)
    }
    
    /// Check if a nullifier has been spent.
    ///
    /// - Parameter nullifier: 32-byte nullifier to check
    /// - Returns: `SpentInfo` if the note is spent, `nil` if unspent
    /// - Throws: `PIRError` on invalid input or query failure
    public func checkNullifier(_ nullifier: Data) throws -> SpentInfo? {
        guard nullifier.count == 32 else {
            throw PIRError.invalidNullifierLength(nullifier.count)
        }
        guard let client = clientPtr else {
            throw PIRError.clientNotInitialized
        }
        guard keysReady else {
            throw PIRError.keysNotReady
        }
        
        let resultPtr = nullifier.withUnsafeBytes { bytes in
            zcashlc_pir_check_nullifier(client, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        
        // Null result means not spent (or error - check last error)
        guard let result = resultPtr else {
            // Check if there was an error vs just "not found"
            let errorLen = zcashlc_last_error_length()
            if errorLen > 0 {
                throw PIRError.queryFailed(
                    lastPIRErrorMessage(fallback: "Unknown error during PIR query")
                )
            }
            return nil
        }
        
        defer { zcashlc_pir_free_spent_info(result) }
        
        let info = result.pointee
        return SpentInfo(
            blockHeight: BlockHeight(info.block_height),
            txIndex: Int(info.tx_index)
        )
    }
    
    /// Statistics from a PIR query.
    public struct QueryStats: Sendable {
        /// Bytes uploaded (query data)
        public let uploadBytes: Int
        /// Bytes downloaded (response data)
        public let downloadBytes: Int
        /// Server processing time in milliseconds (nil if not available)
        public let serverTimeMs: Double?
    }
    
    /// Result of a nullifier check with statistics.
    public struct CheckResult: Sendable {
        /// Spent info if the nullifier was found, nil otherwise
        public let spentInfo: SpentInfo?
        /// Query statistics with actual byte counts
        public let stats: QueryStats
    }
    
    /// Check if a nullifier has been spent, with query statistics.
    ///
    /// - Parameter nullifier: 32-byte nullifier to check
    /// - Returns: `CheckResult` containing spent info and actual byte counts
    /// - Throws: `PIRError` on invalid input or query failure
    public func checkNullifierWithStats(_ nullifier: Data) throws -> CheckResult {
        guard nullifier.count == 32 else {
            throw PIRError.invalidNullifierLength(nullifier.count)
        }
        guard let client = clientPtr else {
            throw PIRError.clientNotInitialized
        }
        guard keysReady else {
            throw PIRError.keysNotReady
        }
        
        let resultPtr = nullifier.withUnsafeBytes { bytes in
            zcashlc_pir_check_nullifier_with_stats(client, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        
        guard let result = resultPtr else {
            let errorLen = zcashlc_last_error_length()
            if errorLen > 0 {
                throw PIRError.queryFailed(
                    lastPIRErrorMessage(fallback: "Unknown error during PIR query")
                )
            }
            // Should not happen - FFI always returns a result or sets error
            throw PIRError.queryFailed("Unexpected null result from PIR query")
        }
        
        defer { zcashlc_pir_free_check_result(result) }
        
        let ffiResult = result.pointee
        
        // Extract spent info if present
        let spentInfo: SpentInfo?
        if let infoPtr = ffiResult.spent_info {
            let info = infoPtr.pointee
            spentInfo = SpentInfo(
                blockHeight: BlockHeight(info.block_height),
                txIndex: Int(info.tx_index)
            )
        } else {
            spentInfo = nil
        }
        
        // Extract stats
        let stats = QueryStats(
            uploadBytes: Int(ffiResult.stats.upload_bytes),
            downloadBytes: Int(ffiResult.stats.download_bytes),
            serverTimeMs: ffiResult.stats.server_time_ms >= 0 ? Double(ffiResult.stats.server_time_ms) : nil
        )
        
        return CheckResult(spentInfo: spentInfo, stats: stats)
    }
    
    /// Check multiple nullifiers in batch.
    ///
    /// - Parameter nullifiers: Array of 32-byte nullifiers to check
    /// - Returns: Array of optional `SpentInfo`, one per input nullifier
    /// - Throws: `PIRError` on invalid input or query failure
    public func checkNullifiers(_ nullifiers: [Data]) throws -> [SpentInfo?] {
        // Validate all nullifiers are 32 bytes
        for nf in nullifiers {
            guard nf.count == 32 else {
                throw PIRError.invalidNullifierLength(nf.count)
            }
        }
        
        guard let client = clientPtr else {
            throw PIRError.clientNotInitialized
        }
        guard keysReady else {
            throw PIRError.keysNotReady
        }
        
        // Flatten nullifiers into a single buffer
        var flatData = Data()
        for nf in nullifiers {
            flatData.append(nf)
        }
        
        let resultPtr = flatData.withUnsafeBytes { bytes in
            zcashlc_pir_check_nullifiers(
                client,
                bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                UInt(nullifiers.count)
            )
        }
        
        guard let arrayResult = resultPtr else {
            throw PIRError.queryFailed(
                lastPIRErrorMessage(fallback: "Unknown error during batch PIR query")
            )
        }
        
        defer { zcashlc_pir_free_spent_info_array(arrayResult) }
        
        // Convert FFI array to Swift array
        var results: [SpentInfo?] = []
        let arr = arrayResult.pointee
        
        for i in 0..<Int(arr.count) {
            let itemPtr = arr.items.advanced(by: i).pointee
            
            if let item = itemPtr {
                results.append(SpentInfo(
                    blockHeight: BlockHeight(item.pointee.block_height),
                    txIndex: Int(item.pointee.tx_index)
                ))
            } else {
                results.append(nil)
            }
        }
        
        return results
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
