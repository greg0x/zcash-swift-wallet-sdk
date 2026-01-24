//
//  PIRUsagePolicy.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

/// Policy for deciding when to use PIR vs trial decryption.
///
/// PIR (Private Information Retrieval) is useful for checking if notes have been
/// spent without revealing which notes are being queried. However, it has overhead
/// compared to trial decryption, so we only use it when beneficial.
///
/// ## Decision Criteria
///
/// Use PIR when:
/// 1. The PIR service is ready (`pirReady == true`)
/// 2. The wallet hasn't synced past the PIR cutoff height
/// 3. The gap between sync height and cutoff is large enough to justify PIR overhead
///
/// ## Scope
///
/// PIR is currently scoped to **known notes only** - notes the wallet already
/// knows about from previous syncs. For discovering new notes, trial decryption
/// is still required during sync.
public struct PIRUsagePolicy: Sendable {
    /// Minimum block gap required to use PIR.
    ///
    /// If the wallet is within this many blocks of the PIR cutoff height,
    /// it's faster to just trial decrypt the remaining blocks instead of
    /// incurring the PIR overhead (key precomputation, query generation, etc.).
    public static let minimumBlockGap: BlockHeight = 100
    
    /// Determine if PIR should be used for nullifier lookups.
    ///
    /// - Parameters:
    ///   - lastSyncHeight: The wallet's last synced block height
    ///   - pirCutoffHeight: The height below which PIR covers nullifiers
    ///   - pirReady: Whether the PIR service is ready
    /// - Returns: `true` if PIR should be used, `false` to use trial decryption
    public static func shouldUsePIR(
        lastSyncHeight: BlockHeight,
        pirCutoffHeight: BlockHeight,
        pirReady: Bool
    ) -> Bool {
        // PIR service must be ready
        guard pirReady else {
            return false
        }
        
        // Wallet must not have synced past the cutoff
        guard lastSyncHeight < pirCutoffHeight else {
            return false
        }
        
        // Gap must be large enough to justify PIR overhead
        let gap = pirCutoffHeight - lastSyncHeight
        guard gap >= minimumBlockGap else {
            return false
        }
        
        return true
    }
    
    /// Determine if PIR should be used, given PIR parameters response.
    ///
    /// - Parameters:
    ///   - lastSyncHeight: The wallet's last synced block height
    ///   - pirParams: The PIR parameters response from the server
    /// - Returns: `true` if PIR should be used, `false` to use trial decryption
    public static func shouldUsePIR(
        lastSyncHeight: BlockHeight,
        pirParams: PirParamsResponse
    ) -> Bool {
        return shouldUsePIR(
            lastSyncHeight: lastSyncHeight,
            pirCutoffHeight: BlockHeight(pirParams.pirCutoffHeight),
            pirReady: pirParams.pirReady
        )
    }
}

// MARK: - NullifierPIRClient Extension

extension NullifierPIRClient {
    /// Check if PIR should be used given the wallet's sync state.
    ///
    /// This is a convenience method that uses the cached PIR parameters.
    /// Returns `false` if the client hasn't been initialized yet.
    ///
    /// - Parameter lastSyncHeight: The wallet's last synced block height
    /// - Returns: `true` if PIR should be used for nullifier lookups
    public func shouldUsePIR(lastSyncHeight: BlockHeight) -> Bool {
        guard let cutoff = pirCutoffHeight else {
            return false
        }
        
        return PIRUsagePolicy.shouldUsePIR(
            lastSyncHeight: lastSyncHeight,
            pirCutoffHeight: cutoff,
            pirReady: isInitialized && keysReady
        )
    }
}

// MARK: - Usage Documentation

/*
 PIR Usage Scope (Phase 1)
 ========================
 
 PIR is currently designed for checking **known notes** - notes that the wallet
 already knows about from previous blockchain syncs. This is the primary use case:
 
 1. User has notes from previous sync
 2. Wallet hasn't synced in a while
 3. User wants to quickly check if any notes were spent
 4. PIR allows this check without revealing which notes are being queried
 
 PIR does NOT replace trial decryption for:
 - Discovering new incoming notes
 - Full blockchain sync
 - Notes received after the PIR cutoff height
 
 Example Integration:
 
 ```swift
 // Check if we should use PIR
 let lastSyncHeight = try await synchronizer.latestBlockHeight()
 
 if pirClient.shouldUsePIR(lastSyncHeight: lastSyncHeight) {
     // Use PIR for quick spend checks on known notes
     let nullifiers = try await getKnownNullifiers()
     for nf in nullifiers {
         if let spent = try await pirClient.checkNullifier(nf) {
             // Note was spent at block \(spent.blockHeight)
         }
     }
 } else {
     // Fall back to trial decryption (full sync)
     try await synchronizer.sync()
 }
 ```
 */
