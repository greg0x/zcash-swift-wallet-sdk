//
//  NullifierPIRClient.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

// TODO: Import NullifierCrypto when the UniFFI bindings are integrated.
// The NullifierCrypto module provides:
// - InspireCryptoState: Manages PIR crypto state
// - computeCuckooBuckets(): Computes Cuckoo hash bucket indices
// - computeFingerprint(): Computes 8-byte fingerprint
// - searchBucket(): Searches bucket for fingerprint
// 
// Integration options:
// 1. Add as Swift package: .package(path: "../nullifier-pir/crates/crypto")
// 2. Copy generated bindings to Sources/ZcashLightClientKit/PIR/NullifierCrypto/
//
// For now, this file uses a shim layer that will be replaced when integrated.

#if canImport(NullifierCrypto)
import NullifierCrypto
#else
// MARK: - Placeholder Types (until NullifierCrypto is integrated)
// These placeholder types mirror the NullifierCrypto API.
// They will be removed once the UniFFI bindings are integrated.

/// Placeholder for NullifierCrypto.InspireCryptoState
private class InspireCryptoState {
    init(params: PirParams) throws {
        fatalError("NullifierCrypto not integrated - see TODO above")
    }
    func precomputeKeys() throws {}
    func keysReady() -> Bool { false }
    func getCuckooParams() -> CuckooParams { CuckooParams() }
    func generateQuery(bucketIdx: UInt64) throws -> QueryResult {
        fatalError("NullifierCrypto not integrated")
    }
    func decryptResponse(queryStateId: UInt64, responseBytes: Data) throws -> Data {
        fatalError("NullifierCrypto not integrated")
    }
}

/// Placeholder for NullifierCrypto.PirParams
private struct PirParams {
    var inspireSetup: InspireSetup
    var cuckooParams: CuckooParams
    var recordSize: UInt64
    var factor: UInt64
    
    init(inspireSetup: InspireSetup, cuckooParams: CuckooParams, recordSize: UInt64, factor: UInt64) {
        self.inspireSetup = inspireSetup
        self.cuckooParams = cuckooParams
        self.recordSize = recordSize
        self.factor = factor
    }
}

/// Placeholder for NullifierCrypto.InspireSetup
private struct InspireSetup {
    var polyLen: UInt64
    var dbDim1: UInt64
    var instances: UInt64
    var dbRows: UInt64
    var dbCols: UInt64
    var gamma: UInt64
    var interpolateDegree: UInt64
    var ptModulus: UInt64
    var c: UInt64
    var tGsw: UInt64
    var q2Bits: UInt64
    var tExpLeft: UInt64
    
    init(polyLen: UInt64 = 0, dbDim1: UInt64 = 0, instances: UInt64 = 0, dbRows: UInt64 = 0, 
         dbCols: UInt64 = 0, gamma: UInt64 = 0, interpolateDegree: UInt64 = 0, ptModulus: UInt64 = 0,
         c: UInt64 = 0, tGsw: UInt64 = 0, q2Bits: UInt64 = 0, tExpLeft: UInt64 = 0) {
        self.polyLen = polyLen
        self.dbDim1 = dbDim1
        self.instances = instances
        self.dbRows = dbRows
        self.dbCols = dbCols
        self.gamma = gamma
        self.interpolateDegree = interpolateDegree
        self.ptModulus = ptModulus
        self.c = c
        self.tGsw = tGsw
        self.q2Bits = q2Bits
        self.tExpLeft = tExpLeft
    }
}

/// Placeholder for NullifierCrypto.CuckooParams
private struct CuckooParams {
    var seed: UInt64
    var numBuckets: UInt64
    var bucketSize: UInt32
    var entrySize: UInt32
    var entriesPerBucket: UInt32
    
    init(seed: UInt64 = 0, numBuckets: UInt64 = 0, bucketSize: UInt32 = 0, 
         entrySize: UInt32 = 0, entriesPerBucket: UInt32 = 0) {
        self.seed = seed
        self.numBuckets = numBuckets
        self.bucketSize = bucketSize
        self.entrySize = entrySize
        self.entriesPerBucket = entriesPerBucket
    }
}

/// Placeholder for NullifierCrypto.CuckooBuckets
private struct CuckooBuckets {
    var bucket1: UInt64
    var bucket2: UInt64
}

/// Placeholder for NullifierCrypto.QueryResult
private struct QueryResult {
    var queryBytes: Data
    var queryStateId: UInt64
}

/// Placeholder for NullifierCrypto.SpentInfo
private struct NullifierCryptoSpentInfo {
    var blockHeight: UInt32
    var txIndex: UInt16
}

/// Placeholder for NullifierCrypto.CryptoError
private enum CryptoError: Error {
    case notImplemented
}

private func computeCuckooBuckets(nullifier: Data, hashSeed: UInt64, numBuckets: UInt64) -> CuckooBuckets {
    fatalError("NullifierCrypto not integrated")
}

private func computeFingerprint(nullifier: Data, hashSeed: UInt64) -> Data {
    fatalError("NullifierCrypto not integrated")
}

private func searchBucket(bucketData: Data, fingerprint: Data, entrySize: UInt32) -> NullifierCryptoSpentInfo? {
    fatalError("NullifierCrypto not integrated")
}
#endif

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
    public init(lightWalletService: LightWalletService) {
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
        
        guard params.hasInspireSetup && params.hasCuckooParams else {
            throw PIRError.invalidServerParams("Missing InsPIRe setup or Cuckoo params")
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
              let params = pirParams else {
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
    private func convertToUniffiParams(_ params: PirParamsResponse) throws -> PirParams {
        // Convert Cuckoo params
        let grpcCuckoo = params.cuckooParams
        let cuckooSeed = hashSeedToUInt64(grpcCuckoo.hashSeed)
        
        let cuckoo = CuckooParams(
            seed: cuckooSeed,
            numBuckets: grpcCuckoo.numBuckets,
            bucketSize: grpcCuckoo.bucketSize,
            entrySize: grpcCuckoo.entrySize,
            entriesPerBucket: grpcCuckoo.entriesPerBucket
        )
        
        // Convert InsPIRe setup
        let grpcSetup = params.inspireSetup
        let inspire = InspireSetup(
            polyLen: grpcSetup.polyLen,
            dbDim1: grpcSetup.dbDim1,
            instances: grpcSetup.instances,
            dbRows: grpcSetup.dbRows,
            dbCols: grpcSetup.dbCols,
            gamma: grpcSetup.gamma,
            interpolateDegree: grpcSetup.interpolateDegree,
            ptModulus: grpcSetup.ptModulus,
            c: grpcSetup.c,
            tGsw: grpcSetup.tGsw,
            q2Bits: grpcSetup.q2Bits,
            tExpLeft: grpcSetup.tExpLeft
        )
        
        return PirParams(
            inspireSetup: inspire,
            cuckooParams: cuckoo,
            recordSize: params.recordSize,
            factor: params.factor
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
