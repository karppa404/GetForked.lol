import Foundation

public struct RebuildProfile: Decodable, Hashable, Sendable {
    public struct Platform: Decodable, Hashable, Sendable {
        public var value: String
        public var status: String
        public var limitations: String
    }
    public struct Component: Decodable, Hashable, Sendable {
        public var name: String
        public var layer: String
        public var basis: String
    }
    public struct LegacyStack: Decodable, Hashable, Sendable {
        public var status: String
        public var components: [Component]
        public var limitations: String
    }
    public struct Alternative: Decodable, Hashable, Sendable {
        public var name: String
        public var target: String
        public var rationale: String
        public var tradeoff: String
    }
    public struct Goal: Decodable, Hashable, Sendable {
        public var metric: String
        public var target: Int
        public var unit: String
        public var validation: String
    }
    public struct Timing: Decodable, Hashable, Sendable {
        public var status: String
        public var sampleCount: Int
        public var p50Ms: Int?
        public var p95Ms: Int?
        public var limitations: String
        enum CodingKeys: String, CodingKey { case status, limitations, sampleCount = "sample_count", p50Ms = "p50_ms", p95Ms = "p95_ms" }
    }
    public var targetPlatform: Platform
    public var legacyStack: LegacyStack
    public var modernAlternatives: [Alternative]
    public var performanceGoals: [Goal]
    public var observedTiming: Timing
    enum CodingKeys: String, CodingKey {
        case targetPlatform = "target_platform", legacyStack = "legacy_stack", modernAlternatives = "modern_alternatives"
        case performanceGoals = "performance_goals", observedTiming = "observed_timing"
    }
}
