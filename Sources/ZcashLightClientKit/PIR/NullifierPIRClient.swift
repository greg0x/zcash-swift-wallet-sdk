//
//  NullifierPIRClient.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation
import NullifierCrypto

/// Client for privacy-preserving nullifier lookups using PIR.
///
/// This client uses Private Information Retrieval to check whether notes
/// have been spent without revealing which notes are being queried.
///
/// ## Architecture
///
/// The client separates concerns:
/// - **Cryptographic operations**: Handled by `NullifierCrypto` (UniFFI bindings)
/// - **Network operations**: Handled by `LightWalletService` (gRPC)
///
/// This design allows the SDK to control networking (for Tor integration)
/// while keeping cryptographic operations in optimized Rust code.
///
/// ## Usage
///
/// ```swift
/// // Create client with existing lightwalletd service
/// let pirClient = NullifierPIRClient(lightWalletService: service)
///
/// // Initialize: fetches params and precomputes keys (expensive, ~3-10s)
/// try await pirClient.initialize()
///
/// // Check if a nullifier has been spent
/// if let spentInfo = try await pirClient.checkNullifier(nullifier) {
///     print("Note spent in block \(spentInfo.blockHeight)")
/// }
/// ```
public actor NullifierPIRClient {
    private let lightWalletService: LightWalletService
    private var cryptoState: InspireCryptoState?
    private var pirParams: PirParamsResponse?
    
    /// Create a new PIR client using an existing LightWalletService.
    ///
    /// This does not perform any initialization. Call `initialize()` before
    /// making queries.
    ///
    /// - Parameter lightWalletService: The gRPC service to use for PIR queries.
    /// - Note: Internal because LightWalletService is internal. Use Synchronizer.createPIRClient() instead.
    init(lightWalletService: LightWalletService) {
        self.lightWalletService = lightWalletService
    }
    
    /// Initialize the PIR client by fetching parameters and precomputing keys.
    ///
    /// This is an expensive operation that:
    /// 1. Fetches PIR parameters from lightwalletd (gRPC)
    /// 2. Creates crypto state with those parameters
    /// 3. Precomputes cryptographic keys (~3-10 seconds)
    ///
    /// Call this once before making any queries. Subsequent queries will be fast.
    ///
    /// - Throws: `PIRError` if initialization fails
    public func initialize() async throws {
        // 1. Get PIR params from lightwalletd via gRPC
        let params = try await lightWalletService.getPirParams(mode: .direct)
        
        guard params.pirReady else {
            throw PIRError.serviceNotReady
        }
        
        guard params.hasInspireParams && params.hasCuckooParams else {
            throw PIRError.invalidServerParams("Missing InsPIRe params or Cuckoo params")
        }
        
        self.pirParams = params
        
        // 2. Convert gRPC params to UniFFI types and create crypto state
        let uniffiParams = try convertToUniffiParams(params)
        
        do {
            let state = try InspireCryptoState(params: uniffiParams)
            
            // 3. Precompute cryptographic keys (expensive)
            try state.precomputeKeys()
            
            self.cryptoState = state
        } catch let error as CryptoError {
            throw PIRError.cryptoError(error.localizedDescription)
        }
    }
    
    /// Check if cryptographic keys are ready for queries.
    public var keysReady: Bool {
        cryptoState?.keysReady() ?? false
    }
    
    /// Whether the client has been initialized.
    public var isInitialized: Bool {
        cryptoState != nil && pirParams != nil
    }
    
    /// The PIR cutoff height below which PIR queries should be used.
    ///
    /// Clients should use PIR for blocks at or below this height,
    /// and trial decryption for blocks above it.
    public var pirCutoffHeight: BlockHeight? {
        pirParams.map { BlockHeight($0.pirCutoffHeight) }
    }
    
    /// Check if a nullifier has been spent.
    ///
    /// Uses Cuckoo hashing to compute two bucket indices, then queries each
    /// bucket via PIR until the nullifier is found or both buckets are checked.
    ///
    /// - Parameter nullifier: 32-byte nullifier to check
    /// - Returns: `SpentInfo` if the note is spent, `nil` if unspent
    /// - Throws: `PIRError` on invalid input or query failure
    public func checkNullifier(_ nullifier: Data) async throws -> SpentInfo? {
        guard nullifier.count == 32 else {
            throw PIRError.invalidNullifierLength(nullifier.count)
        }
        
        guard let cryptoState = cryptoState,
              let _ = pirParams else {
            throw PIRError.clientNotInitialized
        }
        
        guard cryptoState.keysReady() else {
            throw PIRError.keysNotReady
        }
        
        let cuckooParams = cryptoState.getCuckooParams()
        
        // Compute bucket indices using Cuckoo hashing
        let buckets = computeCuckooBuckets(
            nullifier: nullifier,
            hashSeed: cuckooParams.seed,
            numBuckets: cuckooParams.numBuckets
        )
        
        // Compute fingerprint for searching
        let fingerprint = computeFingerprint(
            nullifier: nullifier,
            hashSeed: cuckooParams.seed
        )
        
        // Check each bucket
        for bucketIdx in [buckets.bucket1, buckets.bucket2] {
            if let found = try await checkBucket(
                bucketIdx: bucketIdx,
                fingerprint: fingerprint,
                entrySize: cuckooParams.entrySize,
                cryptoState: cryptoState
            ) {
                return SpentInfo(
                    blockHeight: BlockHeight(found.blockHeight),
                    txIndex: Int(found.txIndex)
                )
            }
        }
        
        return nil // Not found = not spent
    }
    
    /// Check multiple nullifiers in batch.
    ///
    /// This is more efficient than checking nullifiers one at a time when
    /// you have multiple nullifiers to check.
    ///
    /// - Parameter nullifiers: Array of 32-byte nullifiers to check
    /// - Returns: Array of optional `SpentInfo`, one per input nullifier
    /// - Throws: `PIRError` on invalid input or query failure
    public func checkNullifiers(_ nullifiers: [Data]) async throws -> [SpentInfo?] {
        // Validate all nullifiers first
        for nf in nullifiers {
            guard nf.count == 32 else {
                throw PIRError.invalidNullifierLength(nf.count)
            }
        }
        
        // Check each nullifier (could be parallelized in future)
        var results: [SpentInfo?] = []
        for nullifier in nullifiers {
            let result = try await checkNullifier(nullifier)
            results.append(result)
        }
        return results
    }
    
    // MARK: - Private Helpers
    
    /// Check a single bucket for a fingerprint.
    private func checkBucket(
        bucketIdx: UInt64,
        fingerprint: Data,
        entrySize: UInt32,
        cryptoState: InspireCryptoState
    ) async throws -> (blockHeight: UInt32, txIndex: UInt16)? {
        do {
            // Generate query (crypto operation)
            let queryResult = try cryptoState.generateQuery(bucketIdx: bucketIdx)
            
            // Send query via gRPC
            let response = try await lightWalletService.inspireQuery(
                queryResult.queryBytes,
                mode: .direct
            )
            
            // Decrypt response (crypto operation)
            let bucketData = try cryptoState.decryptResponse(
                queryStateId: queryResult.queryStateId,
                responseBytes: response.response
            )
            
            // Search bucket for fingerprint
            if let found = searchBucket(
                bucketData: bucketData,
                fingerprint: fingerprint,
                entrySize: entrySize
            ) {
                return (blockHeight: found.blockHeight, txIndex: found.txIndex)
            }
            return nil
        } catch let error as CryptoError {
            throw PIRError.cryptoError(error.localizedDescription)
        } catch let error as ZcashError {
            throw PIRError.networkError(error.localizedDescription)
        }
    }
    
    /// Convert gRPC PirParamsResponse to UniFFI PirParams.
    private func convertToUniffiParams(_ params: PirParamsResponse) throws -> NullifierCrypto.PirParams {
        // Convert Cuckoo params from gRPC
        let grpcCuckoo = params.cuckooParams
        let cuckooSeed = hashSeedToUInt64(grpcCuckoo.hashSeed)
        
        // Entry format: fingerprint(8) + blockHeight(4) + txIndex(2) = 14 bytes
        let entrySize: UInt32 = 14
        let entriesPerBucket = grpcCuckoo.bucketSize / entrySize
        
        let cuckoo = NullifierCrypto.CuckooParams(
            seed: cuckooSeed,
            numBuckets: grpcCuckoo.numBuckets,
            bucketSize: grpcCuckoo.bucketSize,
            entrySize: entrySize,
            entriesPerBucket: entriesPerBucket
        )
        
        // Convert InsPIRe params - all fields now come from the server
        let grpcInspire = params.inspireParams
        
        let inspire = NullifierCrypto.InspireSetup(
            polyLen: grpcInspire.polyLen,
            dbDim1: grpcInspire.dbDim1,
            instances: grpcInspire.instances,
            dbRows: grpcInspire.dbRows,
            dbCols: grpcInspire.dbCols,
            gamma: grpcInspire.gamma,
            interpolateDegree: grpcInspire.interpolateDegree,
            ptModulus: grpcInspire.ptModulus,
            c: grpcInspire.c,
            tGsw: grpcInspire.tGsw,
            q2Bits: grpcInspire.q2Bits,
            tExpLeft: grpcInspire.tExpLeft
        )
        
        return NullifierCrypto.PirParams(
            inspireSetup: inspire,
            cuckooParams: cuckoo,
            recordSize: grpcInspire.recordSize,
            factor: UInt64(grpcInspire.factor)
        )
    }
    
    /// Convert hash seed bytes to UInt64 (little-endian).
    private func hashSeedToUInt64(_ data: Data) -> UInt64 {
        guard data.count >= 8 else {
            return 0
        }
        return data.withUnsafeBytes { ptr in
            ptr.load(as: UInt64.self)
        }
    }
}
