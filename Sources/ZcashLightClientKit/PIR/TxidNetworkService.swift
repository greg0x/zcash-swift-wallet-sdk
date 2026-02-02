//
//  TxidNetworkService.swift
//  ZcashLightClientKit
//
//  Network service for direct PIR server communication.
//

import Foundation

// MARK: - Response Types

/// Response from a PIR query
public struct TxidPirQueryResponse: Sendable {
    public let data: Data
    public let serverTimeMs: Double
}

/// TX Lookup params from server
struct TxLookupParamsResponse: Decodable, Sendable {
    let dbVersion: DbVersionResponse
    let pirSetup: InspireSetupResponse
    let cuckooParams: TxidCuckooParamsResponse
    let recordSize: UInt64
    let factor: UInt64
    let txCount: UInt64

    enum CodingKeys: String, CodingKey {
        case dbVersion = "db_version"
        case pirSetup = "pir_setup"
        case cuckooParams = "cuckoo_params"
        case recordSize = "record_size"
        case factor
        case txCount = "tx_count"
    }

    var dbVersionValue: UInt64 { dbVersion.version }
}

/// Action Data params from server
struct ActionDataParamsResponse: Decodable, Sendable {
    let dbVersion: DbVersionResponse
    let pirSetup: InspireSetupResponse
    let actionCount: UInt64
    let columnHeight: UInt64
    let numColumns: UInt64
    let actionSize: UInt64
    let recordSize: UInt64
    let factor: UInt64

    enum CodingKeys: String, CodingKey {
        case dbVersion = "db_version"
        case pirSetup = "pir_setup"
        case actionCount = "action_count"
        case columnHeight = "column_height"
        case numColumns = "num_columns"
        case actionSize = "action_size"
        case recordSize = "record_size"
        case factor
    }

    var dbVersionValue: UInt64 { dbVersion.version }
}

/// Database version info
struct DbVersionResponse: Decodable, Sendable {
    let version: UInt64
    let startHeight: UInt32
    let endHeight: UInt32

    enum CodingKeys: String, CodingKey {
        case version
        case startHeight = "start_height"
        case endHeight = "end_height"
    }
}

/// InSPIRe setup parameters
struct InspireSetupResponse: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case polyLen = "poly_len"
        case dbDim1 = "db_dim_1"
        case instances
        case dbRows = "db_rows"
        case dbCols = "db_cols"
        case gamma
        case interpolateDegree = "interpolate_degree"
        case ptModulus = "pt_modulus"
        case c
        case tGsw = "t_gsw"
        case q2Bits = "q2_bits"
        case tExpLeft = "t_exp_left"
        case factor
        case recordSize = "record_size"
    }
}

/// Cuckoo hash parameters (named to avoid conflict with service.pb.swift)
struct TxidCuckooParamsResponse: Decodable, Sendable {
    let seed: String  // String for u64 precision
    let numBuckets: UInt64
    let valueSize: UInt64
    let entrySize: UInt64
    let bucketSize: UInt64

    enum CodingKeys: String, CodingKey {
        case seed
        case numBuckets = "num_buckets"
        case valueSize = "value_size"
        case entrySize = "entry_size"
        case bucketSize = "bucket_size"
    }

    var seedValue: UInt64 {
        UInt64(seed) ?? 0
    }
}

/// PIR query response from server
struct PIRQueryServerResponse: Decodable, Sendable {
    let packedResponseB64: [String]
    let processingTimeMs: Double

    enum CodingKeys: String, CodingKey {
        case packedResponseB64 = "packed_response_b64"
        case processingTimeMs = "processing_time_ms"
    }
}

// MARK: - Network Service

/// Network service for communicating with PIR server via HTTP.
///
/// This is separate from the gRPC-based LightWalletService to allow
/// direct communication with PIR servers during the transition period.
public actor TxidNetworkService {
    private let urlSession: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Params Fetching

    func fetchTxLookupParams(serverURL: String) async throws -> TxLookupParamsResponse {
        guard let url = URL(string: "\(serverURL)/pir/tx-lookup/params") else {
            throw TxidNetworkError.invalidURL
        }

        let (data, response) = try await urlSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TxidNetworkError.invalidResponse
        }

        if httpResponse.statusCode == 503 {
            throw TxidNetworkError.serverInitializing
        }

        guard httpResponse.statusCode == 200 else {
            throw TxidNetworkError.serverError("Status \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(TxLookupParamsResponse.self, from: data)
    }

    func fetchActionDataParams(serverURL: String) async throws -> ActionDataParamsResponse {
        guard let url = URL(string: "\(serverURL)/pir/action-data/params") else {
            throw TxidNetworkError.invalidURL
        }

        let (data, response) = try await urlSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TxidNetworkError.invalidResponse
        }

        if httpResponse.statusCode == 503 {
            throw TxidNetworkError.serverInitializing
        }

        guard httpResponse.statusCode == 200 else {
            throw TxidNetworkError.serverError("Status \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(ActionDataParamsResponse.self, from: data)
    }

    // MARK: - Query Sending

    public func sendQuery(queryData: Data, endpoint: String) async throws -> TxidPirQueryResponse {
        guard let url = URL(string: endpoint) else {
            throw TxidNetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = queryData

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TxidNetworkError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Try to parse error from server
            let errorMessage: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                errorMessage = error
            } else if let body = String(data: data, encoding: .utf8) {
                errorMessage = "Status \(httpResponse.statusCode): \(body)"
            } else {
                errorMessage = "Status \(httpResponse.statusCode)"
            }
            throw TxidNetworkError.serverError(errorMessage)
        }

        // Parse server response to get processing time
        let decoder = JSONDecoder()
        let serverResponse = try decoder.decode(PIRQueryServerResponse.self, from: data)

        return TxidPirQueryResponse(
            data: data,
            serverTimeMs: serverResponse.processingTimeMs
        )
    }
}

// MARK: - Errors

/// Errors from the txid PIR network service.
public enum TxidNetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case serverInitializing
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverInitializing:
            return "Server is still initializing. Please wait for sync to complete."
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
