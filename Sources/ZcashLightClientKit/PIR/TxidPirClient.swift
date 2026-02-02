//
//  TxidPirClient.swift
//  ZcashLightClientKit
//
//  Actor-based client for txid PIR queries.
//  Separates cryptographic operations (via PIRClientFFI) from networking.
//

import Foundation

// MARK: - Public Types

/// Connection state of the txid PIR client.
public enum TxidPirConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case paramsLoaded
    case precomputing
    case ready
    case error(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// InSPIRe parameters for display.
public struct TxidInspireParamsInfo: Sendable, Equatable {
    public let dbRows: UInt64
    public let dbCols: UInt64
    public let polyLen: UInt64
    public let instances: UInt64
    public let gamma: UInt64
}

/// TX Lookup parameters from server.
public struct TxidLookupParamsInfo: Sendable, Equatable {
    public let dbVersion: UInt64
    public let startHeight: UInt32
    public let endHeight: UInt32
    public let txCount: UInt64
    public let factor: UInt64
    public let recordSize: UInt64
    public let inspire: TxidInspireParamsInfo
}

/// Action Data parameters from server.
public struct TxidActionDataParamsInfo: Sendable, Equatable {
    public let dbVersion: UInt64
    public let startHeight: UInt32
    public let endHeight: UInt32
    public let actionCount: UInt64
    public let columnHeight: UInt64
    public let factor: UInt64
    public let recordSize: UInt64
    public let inspire: TxidInspireParamsInfo
}

/// Query timing breakdown.
public struct TxidQueryTiming: Sendable {
    public var queryGenMs: Double = 0
    public var networkMs: Double = 0
    public var serverMs: Double = 0
    public var decryptMs: Double = 0

    public var totalMs: Double {
        queryGenMs + networkMs + serverMs + decryptMs
    }
}

/// Query bandwidth stats.
public struct TxidQueryBandwidth: Sendable {
    public var uploadBytes: Int = 0
    public var downloadBytes: Int = 0
}

/// Result from a TX lookup query.
public struct TxidLookupResult: Sendable {
    /// Starting index into the action data database.
    public let startIndex: UInt64
    /// Number of Orchard actions in this transaction.
    public let actionCount: UInt16
}

/// Action data returned from PIR query.
public struct TxidActionData: Sendable {
    /// Encrypted ciphertext tail (enc_ciphertext bytes 52-564).
    public let encCiphertextTail: Data
    /// Output ciphertext (out_ciphertext, 80 bytes).
    public let outCiphertext: Data
    /// Commitment value (cv, 32 bytes).
    public let cv: Data
}

/// Full TX lookup result with timing and bandwidth stats.
public struct TxidLookupFullResult: Sendable {
    public let result: TxidLookupResult?
    public let timing: TxidQueryTiming
    public let bandwidth: TxidQueryBandwidth
}

/// Full action data result with timing and bandwidth stats.
public struct TxidActionDataFullResult: Sendable {
    public let actions: [TxidActionData]
    public let timing: TxidQueryTiming
    public let bandwidth: TxidQueryBandwidth
}

// MARK: - TxidPirClient

/// Client for txid PIR queries.
///
/// This client provides privacy-preserving lookups for:
/// 1. **TX Lookup**: Given (blockHeight, txIndex), returns the action data indices.
/// 2. **Action Data**: Given (startIndex, count), returns Orchard action data.
///
/// ## Usage
///
/// ```swift
/// let networkService = TxidNetworkService(service: lightWalletService)
/// let client = TxidPirClient(networkService: networkService)
///
/// // Connect via gRPC (through lightwalletd) and precompute keys (expensive, ~3-10s)
/// try await client.connect()
/// try await client.precomputeKeys()
///
/// // Query for a transaction
/// let txResult = try await client.queryTxLookup(blockHeight: 2000000, txIndex: 5)
/// if let result = txResult.result {
///     let actions = try await client.queryActionData(
///         startIndex: result.startIndex,
///         actionCount: result.actionCount
///     )
/// }
/// ```
public actor TxidPirClient {
    public private(set) var state: TxidPirConnectionState = .disconnected
    public private(set) var txLookupParams: TxidLookupParamsInfo?
    public private(set) var actionDataParams: TxidActionDataParamsInfo?

    private var rustClient: TxidPirClientState?  // FFI class from PIRClientFFI
    private let networkService: TxidNetworkService?

    public init(networkService: TxidNetworkService) {
        self.networkService = networkService
    }

    /// Creates a placeholder client that will fail when used.
    /// Only for dependency injection stubs - real usage requires networkService.
    public init() {
        self.networkService = nil
    }

    // MARK: - Connection

    /// Connect to the PIR server (via lightwalletd) and fetch parameters.
    ///
    /// This fetches the PIR parameters from the server and initializes
    /// the cryptographic state. Call `precomputeKeys()` after this.
    public func connect() async throws {
        guard let networkService = networkService else {
            throw TxidPirError.notConfigured
        }

        self.state = TxidPirConnectionState.connecting

        do {
            // Fetch TX Lookup params via gRPC
            let txParams = try await networkService.fetchTxLookupParams()
            self.txLookupParams = TxidLookupParamsInfo(
                dbVersion: txParams.dbVersionValue,
                startHeight: txParams.dbVersion.startHeight,
                endHeight: txParams.dbVersion.endHeight,
                txCount: txParams.txCount,
                factor: txParams.factor,
                recordSize: txParams.recordSize,
                inspire: TxidInspireParamsInfo(
                    dbRows: txParams.pirSetup.dbRows,
                    dbCols: txParams.pirSetup.dbCols,
                    polyLen: txParams.pirSetup.polyLen,
                    instances: txParams.pirSetup.instances,
                    gamma: txParams.pirSetup.gamma
                )
            )

            // Fetch Action Data params via gRPC
            let actionParams = try await networkService.fetchActionDataParams()
            self.actionDataParams = TxidActionDataParamsInfo(
                dbVersion: actionParams.dbVersionValue,
                startHeight: actionParams.dbVersion.startHeight,
                endHeight: actionParams.dbVersion.endHeight,
                actionCount: actionParams.actionCount,
                columnHeight: actionParams.columnHeight,
                factor: actionParams.factor,
                recordSize: actionParams.recordSize,
                inspire: TxidInspireParamsInfo(
                    dbRows: actionParams.pirSetup.dbRows,
                    dbCols: actionParams.pirSetup.dbCols,
                    polyLen: actionParams.pirSetup.polyLen,
                    instances: actionParams.pirSetup.instances,
                    gamma: actionParams.pirSetup.gamma
                )
            )

            // Create Rust client with params
            let txLookupSetup = txParams.pirSetup.toInspireSetup(
                factor: txParams.factor,
                recordSize: txParams.recordSize
            )
            let txLookupCuckoo = txParams.cuckooParams.toTxidCuckooParams()

            let actionDataSetup = actionParams.pirSetup.toInspireSetup(
                factor: actionParams.factor,
                recordSize: actionParams.recordSize
            )

            self.rustClient = try TxidPirClientState(
                txLookupSetup: txLookupSetup,
                txLookupCuckoo: txLookupCuckoo,
                txLookupFactor: txParams.factor,
                txLookupRecordSize: txParams.recordSize,
                txLookupDbVersion: txParams.dbVersionValue,
                actionDataSetup: actionDataSetup,
                actionDataFactor: actionParams.factor,
                actionDataRecordSize: actionParams.recordSize,
                actionDataColumnHeight: actionParams.columnHeight,
                actionDataDbVersion: actionParams.dbVersionValue
            )

            self.state = TxidPirConnectionState.paramsLoaded

        } catch {
            self.state = TxidPirConnectionState.error(error.localizedDescription)
            throw error
        }
    }

    /// Precompute cryptographic keys.
    ///
    /// This is an expensive operation (~3-10 seconds) that must be called
    /// after `connect()` and before making any queries.
    public func precomputeKeys() async throws {
        guard case TxidPirConnectionState.paramsLoaded = state, let rustClient = rustClient else {
            throw TxidPirError.notConnected
        }

        state = TxidPirConnectionState.precomputing

        do {
            // Run key precomputation on background thread (expensive operation)
            try await Task.detached(priority: .userInitiated) {
                try rustClient.precomputeKeys()
            }.value

            state = TxidPirConnectionState.ready

        } catch {
            state = TxidPirConnectionState.error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - TX Lookup Query

    /// Query for a transaction by block height and index.
    ///
    /// - Parameters:
    ///   - blockHeight: The block height containing the transaction.
    ///   - txIndex: The index of the transaction within the block.
    /// - Returns: The result including action data indices, timing, and bandwidth stats.
    public func queryTxLookup(blockHeight: UInt32, txIndex: UInt16) async throws -> TxidLookupFullResult {
        guard let networkService = networkService else {
            throw TxidPirError.notConfigured
        }
        guard case TxidPirConnectionState.ready = state, let rustClient = rustClient else {
            throw TxidPirError.notReady
        }

        var timing = TxidQueryTiming()
        var bandwidth = TxidQueryBandwidth()

        // Generate query
        let queryGenStart = CFAbsoluteTimeGetCurrent()
        let queryBundle = try rustClient.prepareTxLookupQuery(blockHeight: blockHeight, txIndex: txIndex)
        timing.queryGenMs = (CFAbsoluteTimeGetCurrent() - queryGenStart) * 1000

        // Send queries via gRPC (through lightwalletd)
        var responses: [Data] = []
        for query in queryBundle.queries {
            bandwidth.uploadBytes += query.queryBytes.count

            let networkStart = CFAbsoluteTimeGetCurrent()
            let response = try await networkService.sendTxLookupQuery(queryData: query.queryBytes)
            timing.networkMs += (CFAbsoluteTimeGetCurrent() - networkStart) * 1000

            bandwidth.downloadBytes += response.data.count
            timing.serverMs += response.serverTimeMs

            responses.append(response.data)
        }

        // Decrypt responses
        let decryptStart = CFAbsoluteTimeGetCurrent()
        let ffiResult = try rustClient.completeTxLookupQuery(bundle: queryBundle, responses: responses)
        timing.decryptMs = (CFAbsoluteTimeGetCurrent() - decryptStart) * 1000

        let result = ffiResult.map {
            TxidLookupResult(startIndex: $0.startIndex, actionCount: $0.actionCount)
        }

        return TxidLookupFullResult(
            result: result,
            timing: timing,
            bandwidth: bandwidth
        )
    }

    // MARK: - Action Data Query

    /// Query for Orchard action data.
    ///
    /// - Parameters:
    ///   - startIndex: Starting index into the action data database.
    ///   - actionCount: Number of actions to retrieve.
    /// - Returns: The action data along with timing and bandwidth stats.
    public func queryActionData(startIndex: UInt64, actionCount: UInt16) async throws -> TxidActionDataFullResult {
        guard let networkService = networkService else {
            throw TxidPirError.notConfigured
        }
        guard case TxidPirConnectionState.ready = state, let rustClient = rustClient else {
            throw TxidPirError.notReady
        }

        var timing = TxidQueryTiming()
        var bandwidth = TxidQueryBandwidth()

        // Generate query
        let queryGenStart = CFAbsoluteTimeGetCurrent()
        let queryBundle = try rustClient.prepareActionDataQuery(startIndex: startIndex, actionCount: actionCount)
        timing.queryGenMs = (CFAbsoluteTimeGetCurrent() - queryGenStart) * 1000

        // Send queries via gRPC (through lightwalletd)
        var responses: [Data] = []
        for query in queryBundle.queries {
            bandwidth.uploadBytes += query.queryBytes.count

            let networkStart = CFAbsoluteTimeGetCurrent()
            let response = try await networkService.sendActionDataQuery(queryData: query.queryBytes)
            timing.networkMs += (CFAbsoluteTimeGetCurrent() - networkStart) * 1000

            bandwidth.downloadBytes += response.data.count
            timing.serverMs += response.serverTimeMs

            responses.append(response.data)
        }

        // Decrypt responses
        let decryptStart = CFAbsoluteTimeGetCurrent()
        let ffiActions = try rustClient.completeActionDataQuery(bundle: queryBundle, responses: responses)
        timing.decryptMs = (CFAbsoluteTimeGetCurrent() - decryptStart) * 1000

        let actions = ffiActions.map {
            TxidActionData(
                encCiphertextTail: $0.encCiphertextTail,
                outCiphertext: $0.outCiphertext,
                cv: $0.cv
            )
        }

        return TxidActionDataFullResult(
            actions: actions,
            timing: timing,
            bandwidth: bandwidth
        )
    }

    /// Disconnect and reset state.
    public func disconnect() {
        rustClient = nil
        txLookupParams = nil
        actionDataParams = nil
        state = TxidPirConnectionState.disconnected
    }
}

// MARK: - Conversions

extension InspireSetupResponse {
    func toInspireSetup(factor: UInt64, recordSize: UInt64) -> InspireSetup {
        InspireSetup(
            polyLen: polyLen,
            dbDim1: dbDim1,
            instances: instances,
            dbRows: dbRows,
            dbCols: dbCols,
            gamma: gamma,
            interpolateDegree: interpolateDegree,
            ptModulus: ptModulus,
            c: c,
            tGsw: tGsw,
            q2Bits: q2Bits,
            tExpLeft: tExpLeft,
            factor: self.factor ?? factor,
            recordSize: self.recordSize ?? recordSize
        )
    }
}

extension TxidCuckooParamsResponse {
    func toTxidCuckooParams() -> TxidCuckooParams {
        TxidCuckooParams(
            seed: seedValue,
            numBuckets: numBuckets,
            valueSize: UInt32(valueSize),
            entrySize: UInt32(entrySize),
            bucketSize: UInt32(bucketSize)
        )
    }
}

// MARK: - Errors

/// Errors from the txid PIR client.
public enum TxidPirError: LocalizedError, Sendable {
    case notConfigured
    case notConnected
    case notReady
    case networkError(String)
    case cryptoError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "PIR client not configured - networkService is required"
        case .notConnected:
            return "PIR client not connected - call connect() first"
        case .notReady:
            return "PIR client not ready - call connect() and precomputeKeys() first"
        case .networkError(let message):
            return "Network error: \(message)"
        case .cryptoError(let message):
            return "Crypto error: \(message)"
        }
    }
}
