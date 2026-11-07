import Foundation

public struct ActivityStats: Codable, Equatable, Sendable {
    public var approved = 0
    public var declined = 0
    public var continued = 0
    public var vscodeApproved = 0
    public var vscodeHeldForReview = 0
    public var vscodeContinued = 0
    public var vscodeModelSwitches = 0
    public var trackingSince = Date()
    public init() {}
}
