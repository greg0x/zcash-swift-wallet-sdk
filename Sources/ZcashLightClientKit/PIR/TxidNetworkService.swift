//
//  TxidNetworkService.swift
//  ZcashLightClientKit
//
//  Network service for txid PIR communication via gRPC through lightwalletd.
//

import Foundation

// MARK: - Response Types

/// Response from a PIR query
public struct TxidPirQueryResponse: Sendable {
    public let data: Data
    public let serverTimeMs: Double
}

/// TX Lookup params (internal representation)
struct TxLookupParamsResponse: Sendable {
    let dbVersion: DbVersionResponse
    let pirSetup: InspireSetupResponse
    let cuckooParams: TxidCuckooParamsResponse
    let recordSize: UInt64
    let factor: UInt64
    let txCount: UInt64

    var dbVersionValue: UInt64 { dbVersion.version }

    /// Initialize from gRPC response
    init(from grpc: TxidLookupParamsResponse) {
        self.dbVersion = DbVersionResponse(
            version: grpc.dbVersion,
            startHeight: grpc.startHeight,
            endHeight: grpc.endHeight
        )
        self.pirSetup = InspireSetupResponse(from: grpc.inspire)
        self.cuckooParams = TxidCuckooParamsResponse(from: grpc.cuckoo)
        self.recordSize = grpc.recordSize
        self.factor = grpc.factor
        self.txCount = grpc.txCount
    }
}

/// Action Data params (internal representation)
struct ActionDataParamsResponseInternal: Sendable {
    let dbVersion: DbVersionResponse
    let pirSetup: InspireSetupResponse
    let actionCount: UInt64
    let columnHeight: UInt64
    let recordSize: UInt64
    let factor: UInt64

    var dbVersionValue: UInt64 { dbVersion.version }

    /// Initialize from gRPC response
    init(from grpc: ActionDataParamsResponse) {
        self.dbVersion = DbVersionResponse(
            version: grpc.dbVersion,
            startHeight: grpc.startHeight,
            endHeight: grpc.endHeight
        )
        self.pirSetup = InspireSetupResponse(from: grpc.inspire)
        self.actionCount = grpc.actionCount
        self.columnHeight = grpc.columnHeight
        self.recordSize = grpc.recordSize
        self.factor = grpc.factor
    }
}

/// Database version info
struct DbVersionResponse: Sendable {
    let version: UInt64
    let startHeight: UInt32
    let endHeight: UInt32
}

/// InSPIRe setup parameters (internal representation)
struct InspireSetupResponse: Sendable {
    let polyLen: UInt64
    let dbDim1: UInt64
    let instances: UInt64
    let dbRows: UInt64
    let dbCols: UInt64
    let gamma: UInt64
    let interpolateDegree: UInt64
    let ptModulus: UInt64
    let c: UInt64
    let tGsw: UInt64
    let q2Bits: UInt64
    let tExpLeft: UInt64
    let factor: UInt64?
    let recordSize: UInt64?

    /// Initialize from gRPC InspireParams
    init(from grpc: InspireParams) {
        self.polyLen = grpc.polyLen
        self.dbDim1 = grpc.dbDim1
        self.instances = grpc.instances
        self.dbRows = grpc.dbRows
        self.dbCols = grpc.dbCols
        self.gamma = grpc.gamma
        self.interpolateDegree = grpc.interpolateDegree
        self.ptModulus = grpc.ptModulus
        self.c = grpc.c
        self.tGsw = grpc.tGsw
        self.q2Bits = grpc.q2Bits
        self.tExpLeft = grpc.tExpLeft
        self.factor = grpc.factor > 0 ? UInt64(grpc.factor) : nil
        self.recordSize = grpc.recordSize > 0 ? grpc.recordSize : nil
    }
}

/// Cuckoo hash parameters (internal representation)
struct TxidCuckooParamsResponse: Sendable {
    let seed: UInt64
    let numBuckets: UInt64
    let bucketSize: UInt32
    let valueSize: UInt32
    let entrySize: UInt32

    var seedValue: UInt64 { seed }

    /// Initialize from gRPC CuckooParams
    init(from grpc: CuckooParams) {
        // hashSeed is little-endian bytes
        if grpc.hashSeed.count >= 8 {
            self.seed = grpc.hashSeed.withUnsafeBytes { ptr in
                ptr.loadUnaligned(as: UInt64.self)
            }
        } else {
            self.seed = 0
        }
        self.numBuckets = grpc.numBuckets
        self.bucketSize = grpc.bucketSize
        self.valueSize = grpc.valueSize
        self.entrySize = grpc.entrySize
    }
}

// MARK: - Network Service

/// Network service for communicating with lightwalletd's txid PIR endpoints via gRPC.
///
/// This service uses the LightWalletService to proxy PIR queries through lightwalletd,
/// which then forwards them to the external PIR server.
public actor TxidNetworkService {
    private let service: LightWalletService

    init(service: LightWalletService) {
        self.service = service
    }

    // MARK: - Params Fetching

    func fetchTxLookupParams() async throws -> TxLookupParamsResponse {
        let grpcResponse = try await service.getTxidLookupParams(mode: .direct)
        return TxLookupParamsResponse(from: grpcResponse)
    }

    func fetchActionDataParams() async throws -> ActionDataParamsResponseInternal {
        let grpcResponse = try await service.getActionDataParams(mode: .direct)
        return ActionDataParamsResponseInternal(from: grpcResponse)
    }

    // MARK: - Query Sending

    public func sendTxLookupQuery(queryData: Data) async throws -> TxidPirQueryResponse {
        let grpcResponse = try await service.txidLookupQuery(queryData, mode: .direct)
        return TxidPirQueryResponse(
            data: grpcResponse.responseData,
            serverTimeMs: grpcResponse.serverTimeMs
        )
    }

    public func sendActionDataQuery(queryData: Data) async throws -> TxidPirQueryResponse {
        let grpcResponse = try await service.actionDataQuery(queryData, mode: .direct)
        return TxidPirQueryResponse(
            data: grpcResponse.responseData,
            serverTimeMs: grpcResponse.serverTimeMs
        )
    }
}

// MARK: - Errors

/// Errors from the txid PIR network service.
public enum TxidNetworkError: LocalizedError, Sendable {
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
