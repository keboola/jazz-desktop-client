import Foundation

/// Pure decision logic for narration-upload idempotence — the bug this guards against is the
/// retry loop blindly re-`prepare`-ing a clip, which left duplicate/dangling Storage records.
///
/// The app target does the impure part (list files for a `label:<id>` tag, HEAD each one's
/// signed GCS URL to learn whether the object is actually present), then hands the results
/// here as ``Candidate`` values. This decides, deterministically and testably: which (if any)
/// complete copy to REUSE, and which dangling records to DELETE.
public enum NarrationDedup {
    /// One existing Storage file for a clip's label tag, with its GCS-presence probe result:
    /// `true` = object present (a COMPLETE upload), `false` = 404 (a DANGLING prepare-only
    /// record — file id minted, no bytes), `nil` = uncertain (network/other status — don't act).
    public struct Candidate: Equatable, Sendable {
        public let fileId: Int
        public let present: Bool?

        public init(fileId: Int, present: Bool?) {
            self.fileId = fileId
            self.present = present
        }
    }

    /// The outcome: reuse a single complete file id (nil → none exists, do a fresh upload), and
    /// delete the dangling records so retries never accumulate empties. Uncertain candidates are
    /// left untouched (never deleted on a guess), and SURPLUS complete copies are left alone too
    /// — deleting a record that has real bytes is destructive, so dedup only ever removes the
    /// provably-empty (404) ones.
    public struct Decision: Equatable, Sendable {
        public let reuseFileId: Int?
        public let danglingToDelete: [Int]

        public init(reuseFileId: Int?, danglingToDelete: [Int]) {
            self.reuseFileId = reuseFileId
            self.danglingToDelete = danglingToDelete
        }
    }

    /// Reuse the FIRST complete copy (caller passes candidates oldest-first, so the earliest
    /// good upload wins and stays stable across retries); mark every dangling (404) record for
    /// deletion; leave uncertain and surplus-complete records untouched.
    public static func decide(_ candidates: [Candidate]) -> Decision {
        var reuse: Int?
        var dangling: [Int] = []
        for candidate in candidates {
            switch candidate.present {
            case .some(true):
                if reuse == nil { reuse = candidate.fileId }  // keep the first complete copy
            case .some(false):
                dangling.append(candidate.fileId)  // provably empty — safe to clean up
            case .none:
                break  // uncertain — don't reuse or delete on a guess
            }
        }
        return Decision(reuseFileId: reuse, danglingToDelete: dangling)
    }
}
