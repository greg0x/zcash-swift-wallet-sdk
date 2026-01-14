//
//  BalanceVerificationResult.swift
//  ZcashLightClientKit
//
//  Created for PIR integration.
//

import Foundation

/// Result of a PIR-based balance verification.
///
/// Reports how many nullifiers were checked and whether any
/// unexpectedly spent notes were discovered.
public struct BalanceVerificationResult: Equatable, Sendable {
    /// Number of nullifiers that were checked via PIR.
    public let checkedCount: Int
    
    /// Number of notes that were discovered to be spent (but the wallet thought were unspent).
    public let newlySpentCount: Int
    
    /// Details about each newly discovered spent note.
    public let newlySpentNotes: [SpentInfo]
    
    public init(checkedCount: Int, newlySpentCount: Int, newlySpentNotes: [SpentInfo] = []) {
        self.checkedCount = checkedCount
        self.newlySpentCount = newlySpentCount
        self.newlySpentNotes = newlySpentNotes
    }
    
    /// Returns true if any notes were found to be unexpectedly spent.
    public var hasDiscrepancies: Bool {
        newlySpentCount > 0
    }
}
