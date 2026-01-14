//
//  SpentInfo.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

/// Information about a spent note returned from a PIR query.
///
/// When a nullifier lookup indicates a note has been spent, this struct
/// contains details about when and where the spend occurred.
public struct SpentInfo: Equatable, Sendable {
    /// The block height where the nullifier was revealed (note was spent).
    public let blockHeight: BlockHeight
    
    /// The transaction index within the block.
    public let txIndex: Int
    
    public init(blockHeight: BlockHeight, txIndex: Int) {
        self.blockHeight = blockHeight
        self.txIndex = txIndex
    }
}
