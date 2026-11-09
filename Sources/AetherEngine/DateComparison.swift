import Foundation

// Xcode 27.2's Foundation back-deploys `Date`'s `<=` and `>=`: on an OS that reports 27.2 or
// later it calls the system's own copy, which early 27.2 betas don't have, so the call jumps to
// address 0 (a crash on Vision Pro 24N5093f). These shadow Foundation's within this module, so
// every comparison uses this code instead. Each module needs its own copy. Remove once no device
// runs a 27.2 beta older than the release.
extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }

    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }
}
