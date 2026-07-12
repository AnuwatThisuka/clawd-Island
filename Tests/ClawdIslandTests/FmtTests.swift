import Testing
import Foundation
@testable import ClawdIsland

@Suite struct FmtTests {
    // Every tier string observed from oauthAccount.organizationRateLimitTier.
    @Test func planLabelKnownTiers() {
        #expect(Fmt.planLabel("default_claude_ai") == "Claude Free")
        #expect(Fmt.planLabel("default_claude_pro") == "Claude Pro")
        #expect(Fmt.planLabel("default_claude_max_5x") == "Claude Max 5x")
        #expect(Fmt.planLabel("default_claude_max_20x") == "Claude Max 20x")
        #expect(Fmt.planLabel("default_claude_team") == "Claude Team")
        #expect(Fmt.planLabel("default_claude_enterprise") == "Claude Enterprise")
    }

    // The bug this test guards: "default_claude_ai" must never render "Claude Ai".
    @Test func planLabelFreeTierNotMangled() {
        #expect(Fmt.planLabel("default_claude_ai") != "Claude Ai")
    }

    // Unknown/future tiers fall back to something sensible, not a raw token.
    @Test func planLabelUnknownFallback() {
        // Future Max multiplier keeps the "Claude Max Nx" shape.
        #expect(Fmt.planLabel("default_claude_max_50x") == "Claude Max 50x")
        // Generic unknown tier gets prefixed + capitalized.
        #expect(Fmt.planLabel("default_claude_startup") == "Claude Startup")
        // Bare token still reads as a plan name rather than garbage.
        let bare = Fmt.planLabel("scholar")
        #expect(bare == "Claude Scholar")
        #expect(!bare.isEmpty)
    }
}
