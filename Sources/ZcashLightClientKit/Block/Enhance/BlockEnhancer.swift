//
//  CompactBlockEnhancement.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 4/10/20.
//

import Foundation

public struct EnhancementProgress: Equatable {
    /// total transactions that were detected in the `range`
    public let totalTransactions: Int
    /// enhanced transactions so far
    public let enhancedTransactions: Int
    /// last found transaction
    public let lastFoundTransaction: ZcashTransaction.Overview?
    /// block range that's being enhanced
    public let range: CompactBlockRange
    /// whether this transaction can be considered `newly mined` and not part of the
    /// wallet catching up to stale and uneventful blocks.
    public let newlyMined: Bool

    public init(
        totalTransactions: Int,
        enhancedTransactions: Int,
        lastFoundTransaction: ZcashTransaction.Overview?,
        range: CompactBlockRange,
        newlyMined: Bool
    ) {
        self.totalTransactions = totalTransactions
        self.enhancedTransactions = enhancedTransactions
        self.lastFoundTransaction = lastFoundTransaction
        self.range = range
        self.newlyMined = newlyMined
    }

    public var progress: Float {
        totalTransactions > 0 ? Float(enhancedTransactions) / Float(totalTransactions) : 0
    }

    public static var zero: EnhancementProgress {
        EnhancementProgress(totalTransactions: 0, enhancedTransactions: 0, lastFoundTransaction: nil, range: 0...0, newlyMined: false)
    }

    public static func == (lhs: EnhancementProgress, rhs: EnhancementProgress) -> Bool {
        return
            lhs.totalTransactions == rhs.totalTransactions &&
            lhs.enhancedTransactions == rhs.enhancedTransactions &&
            lhs.lastFoundTransaction?.rawID == rhs.lastFoundTransaction?.rawID &&
            lhs.range == rhs.range
    }
}

protocol BlockEnhancer {
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]?
}

struct BlockEnhancerImpl {
    let blockDownloaderService: BlockDownloaderService
    let rustBackend: ZcashRustBackendWelding
    let transactionRepository: TransactionRepository
    let metrics: SDKMetrics
    let service: LightWalletService
    let logger: Logger
    let sdkFlags: SDKFlags
    let txidPirClient: TxidPirClient?
    let pirConfig: CompactBlockProcessor.PirConfig
}

extension BlockEnhancerImpl: BlockEnhancer {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]? {
        try Task.checkCancellation()

        logger.debug("Started Enhancing range: \(range)")

        // fetch transactions
        do {
            let transactionDataRequests = try await rustBackend.transactionDataRequests()

            guard !transactionDataRequests.isEmpty else {
                logger.debug("No transaction data requests detected.")
                logger.sync("No transaction data requests detected.")
                return nil
            }

            for index in 0 ..< transactionDataRequests.count {
                let transactionDataRequest = transactionDataRequests[index]
                var retry = true
                var retries = 0
                let maxRetries = 5

                while retry && retries < maxRetries {
                    try Task.checkCancellation()
                    do {
                        switch transactionDataRequest {
                        case .getStatus(let txId):
                            let response = try await blockDownloaderService.fetchTransaction(
                                txId: txId.data,
                                mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txId.data))
                            )
                            retry = false

                            if response.status == .txidNotRecognized {
                                try await rustBackend.setTransactionStatus(txId: txId.data, status: response.status)
                            } else if let fetchedTransaction = response.tx {
                                try await rustBackend.setTransactionStatus(txId: fetchedTransaction.rawID, status: response.status)
                            }

                        case .enhancement(let txId):
                            // Check if PIR enhancement is enabled and client is ready
                            if pirConfig.isPirEnhanceEnabled,
                               let pirClient = txidPirClient,
                               await pirClient.state.isReady {
                                logger.info("Enhancement: Using PIR path for tx \(txId.data.hexEncodedString())")
                                do {
                                    try await enhanceViaPir(txId: txId.data, pirClient: pirClient)
                                    retry = false
                                } catch {
                                    logger.warn("PIR enhancement failed, falling back to GetTransaction: \(error)")
                                    // Fall through to legacy path
                                    try await enhanceViaGetTransaction(txId: txId.data)
                                    retry = false
                                }
                            } else {
                                // Legacy path: GetTransaction (leaks txid to server)
                                logger.info("Enhancement: Using GetTransaction path for tx \(txId.data.hexEncodedString())")
                                try await enhanceViaGetTransaction(txId: txId.data)
                                retry = false
                            }

                        case .transactionsInvolvingAddress(let tia):
                            // TODO: [#1554] Remove this guard once lightwalletd servers support open-ended ranges.
                            guard tia.blockRangeEnd != nil else {
                                logger.error("transactionsInvolvingAddress \(tia) is missing blockRangeEnd, ignoring the request.")
                                retry = false
                                continue
                            }

                            // TODO: [#1551] Support this.
                            if tia.requestAt != nil {
                                logger.error("transactionsInvolvingAddress \(tia) has requestAt set, ignoring the unsupported request.")
                                retry = false
                                continue
                            }

                            // TODO: [#1552] Support the OutputStatusFilter
                            if tia.outputStatusFilter == .unspent {
                                retry = false
                                continue
                            }

                            var filter = TransparentAddressBlockFilter()
                            filter.address = tia.address
                            filter.range = if let blockRangeEnd = tia.blockRangeEnd {
                                BlockRange(startHeight: Int(tia.blockRangeStart), endHeight: Int(blockRangeEnd - 1))
                            } else {
                                BlockRange(startHeight: Int(tia.blockRangeStart))
                            }

                            // ServiceMode to resolve
                            let stream = try service.getTaddressTxids(filter, mode: .direct)

                            for try await rawTransaction in stream {
                                let minedHeight = (rawTransaction.height == 0 || rawTransaction.height > UInt32.max)
                                ? nil : UInt32(rawTransaction.height)

                                // Ignore transactions that don't match the status filter.
                                if (tia.txStatusFilter == .mined && minedHeight == nil) || (tia.txStatusFilter == .mempool && minedHeight != nil) {
                                    continue
                                }

                                _ = try await rustBackend.decryptAndStoreTransaction(
                                    txBytes: rawTransaction.data.bytes,
                                    minedHeight: minedHeight
                                )
                            }
                            retry = false
                        }
                    } catch {
                        retries += 1
                        logger.error("could not enhance transactionDataRequest \(transactionDataRequest) - Error: \(error)")
                    }
                }
            }
        } catch {
            logger.error("error enhancing transactions! \(error)")
            throw error
        }
        
        if Task.isCancelled {
            logger.debug("Warning: compactBlockEnhancement on range \(range) cancelled")
        }

        return (try? await transactionRepository.find(in: range, limit: Int.max, kind: .all))
    }

    // MARK: - Private Enhancement Methods

    /// Legacy enhancement via GetTransaction RPC (leaks txid to server).
    private func enhanceViaGetTransaction(txId: Data) async throws {
        let response = try await blockDownloaderService.fetchTransaction(
            txId: txId,
            mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txId))
        )

        if response.status == .txidNotRecognized {
            try await rustBackend.setTransactionStatus(txId: txId, status: .txidNotRecognized)
        } else if let fetchedTransaction = response.tx {
            _ = try await rustBackend.decryptAndStoreTransaction(
                txBytes: fetchedTransaction.raw.bytes,
                minedHeight: fetchedTransaction.minedHeight
            )
        }
    }

    /// PIR-based enhancement (privacy-preserving).
    ///
    /// This method uses PIR to fetch transaction action data without revealing
    /// which transaction we're interested in to the server.
    ///
    /// Flow:
    /// 1. Get (block_height, tx_index) from wallet DB
    /// 2. TX Lookup PIR query → get (startIndex, actionCount)
    /// 3. Action Data PIR query → get encrypted action data
    /// 4. Fetch compact block via GetBlock (leaks only block_height, not txid)
    /// 5. Extract compact actions for this transaction
    /// 6. Pass PIR data + compact data to Rust for trial decryption
    private func enhanceViaPir(txId: Data, pirClient: TxidPirClient) async throws {
        // 1. Get transaction location from wallet DB
        let txOverview = try await transactionRepository.find(rawID: txId)

        guard let blockHeight = txOverview.minedHeight,
              let txIndex = txOverview.index else {
            logger.warn("PIR: Transaction \(txId.hexEncodedString()) missing location info, falling back")
            throw EnhanceError.missingTransactionLocation
        }

        logger.debug("PIR: Enhancing tx at block \(blockHeight), index \(txIndex)")

        // 2. TX Lookup PIR query → get (startIndex, actionCount)
        let lookupResult = try await pirClient.queryTxLookup(
            blockHeight: UInt32(blockHeight),
            txIndex: UInt16(txIndex)
        )

        guard let lookup = lookupResult.result else {
            // Transaction not in PIR DB (maybe too recent or outside DB range)
            logger.info("PIR: Transaction not found in PIR DB, falling back to GetTransaction")
            throw EnhanceError.transactionNotInPirDatabase
        }

        logger.debug("PIR: TX lookup returned startIndex=\(lookup.startIndex), actionCount=\(lookup.actionCount)")
        logger.debug("PIR: TX lookup timing - query=\(lookupResult.timing.queryGenMs)ms, network=\(lookupResult.timing.networkMs)ms, server=\(lookupResult.timing.serverMs)ms, decrypt=\(lookupResult.timing.decryptMs)ms")

        // 3. Action Data PIR query → get encrypted action data
        let actionResult = try await pirClient.queryActionData(
            startIndex: lookup.startIndex,
            actionCount: lookup.actionCount
        )

        logger.debug("PIR: Action data returned \(actionResult.actions.count) actions")
        logger.debug("PIR: Action data timing - query=\(actionResult.timing.queryGenMs)ms, network=\(actionResult.timing.networkMs)ms, server=\(actionResult.timing.serverMs)ms, decrypt=\(actionResult.timing.decryptMs)ms")

        // 4. Fetch compact block via GetBlock (leaks only block_height, not txid)
        let compactBlock = try await fetchCompactBlock(height: blockHeight)

        // 5. Extract compact actions for this transaction
        guard txIndex < compactBlock.vtx.count else {
            throw EnhanceError.invalidTransactionIndex
        }

        let compactTx = compactBlock.vtx[txIndex]
        let compactActions = compactTx.actions.map { action in
            CompactActionData(
                nullifier: action.nullifier,
                cmx: action.cmx,
                ephemeralKey: action.ephemeralKey,
                encCiphertextHead: action.ciphertext  // First 52 bytes
            )
        }

        logger.debug("PIR: Extracted \(compactActions.count) compact actions from block")

        // Verify action counts match
        guard compactActions.count == actionResult.actions.count else {
            logger.error("PIR: Action count mismatch - compact=\(compactActions.count), PIR=\(actionResult.actions.count)")
            throw EnhanceError.actionCountMismatch
        }

        // Convert PIR actions to the format expected by Rust FFI
        let pirActions = actionResult.actions.map { action in
            PirActionData(
                encCiphertextTail: action.encCiphertextTail,
                outCiphertext: action.outCiphertext,
                cv: action.cv
            )
        }

        // 6. Merge compact + PIR data into 788-byte actions for Rust FFI
        // Layout: nullifier(32) + cmx(32) + epk(32) + enc_ciphertext(580) + out_ciphertext(80) + cv(32) = 788
        var mergedActions: [Data] = []
        for (compact, pir) in zip(compactActions, pirActions) {
            var action = Data(capacity: 788)
            action.append(compact.nullifier)           // 32 bytes
            action.append(compact.cmx)                 // 32 bytes
            action.append(compact.ephemeralKey)        // 32 bytes
            action.append(compact.encCiphertextHead)   // 52 bytes
            action.append(pir.encCiphertextTail)       // 528 bytes
            action.append(pir.outCiphertext)           // 80 bytes
            action.append(pir.cv)                      // 32 bytes
            mergedActions.append(action)
        }

        logger.info("PIR: Successfully fetched data for \(mergedActions.count) actions via PIR")
        logger.info("PIR: Bandwidth - TX lookup: \(lookupResult.bandwidth.uploadBytes)↑ \(lookupResult.bandwidth.downloadBytes)↓ bytes")
        logger.info("PIR: Bandwidth - Action data: \(actionResult.bandwidth.uploadBytes)↑ \(actionResult.bandwidth.downloadBytes)↓ bytes")

        // 7. Call Rust FFI for trial decryption and storage
        let decryptedCount = try await rustBackend.decryptAndStorePirActions(
            txid: txId,
            minedHeight: UInt32(blockHeight),
            actions: mergedActions
        )

        logger.info("PIR: Decrypted and stored \(decryptedCount) notes via PIR enhancement")
    }

    /// Fetch a single compact block by height.
    private func fetchCompactBlock(height: BlockHeight) async throws -> CompactBlock {
        let stream = try service.blockRange(height...height, mode: .direct)

        for try await zcashCompactBlock in stream {
            // Parse the serialized data back to CompactBlock
            return try CompactBlock(serializedBytes: zcashCompactBlock.data)
        }

        throw EnhanceError.blockNotFound(height)
    }
}

// MARK: - Supporting Types

/// Compact action data from the compact block (public data).
struct CompactActionData {
    /// Nullifier (32 bytes).
    let nullifier: Data
    /// Note commitment x-coordinate (32 bytes).
    let cmx: Data
    /// Ephemeral public key (32 bytes).
    let ephemeralKey: Data
    /// First 52 bytes of enc_ciphertext.
    let encCiphertextHead: Data
}

/// PIR action data (private data from PIR server).
struct PirActionData {
    /// enc_ciphertext bytes 52-580 (528 bytes for Orchard).
    let encCiphertextTail: Data
    /// out_ciphertext (80 bytes).
    let outCiphertext: Data
    /// Value commitment cv (32 bytes).
    let cv: Data
}

/// Errors specific to the enhancement process.
enum EnhanceError: LocalizedError {
    case missingTransactionLocation
    case transactionNotInPirDatabase
    case invalidTransactionIndex
    case actionCountMismatch
    case blockNotFound(BlockHeight)

    var errorDescription: String? {
        switch self {
        case .missingTransactionLocation:
            return "Transaction is missing block height or index information"
        case .transactionNotInPirDatabase:
            return "Transaction not found in PIR database (may be too recent)"
        case .invalidTransactionIndex:
            return "Transaction index exceeds block transaction count"
        case .actionCountMismatch:
            return "Mismatch between compact block and PIR action counts"
        case .blockNotFound(let height):
            return "Block not found at height \(height)"
        }
    }
}
