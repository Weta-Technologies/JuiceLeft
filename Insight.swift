import AppKit

/// The plain-English line under the panel header. Facts in, one sentence out: a template always, and — when Apple
/// Intelligence is on (macOS 26+) — the on-device model rephrasing the same facts, checked so it never invents a
/// number. Regenerated only when the facts change in a way worth new words, never on every tick.
@MainActor final class Insight: ObservableObject {
    struct Facts: Equatable {
        var percent: Int
        var onAC: Bool
        var charging: Bool
        var full: Bool
        var minutesLeft: Int?
        var ratePerHour: Double?     // positive
        var typicalRate: Double?     // the learned prior for this time of day, positive
        var topApps: [String]
        var target = 100             // charging: the level it stops at — Apple's charge limit, else 100
    }

    @Published private(set) var text = ""
    @Published private(set) var fromAI = false
    private var signature = ""
    private var generation = 0
    private var lastFacts: Facts?

    /// Apple Intelligence was turned on since the last sentence: phrase the current facts with it now.
    func retryAI(ai: Bool) {
        guard ai, !fromAI, let f = lastFacts, AppleIntelligence.available else { return }
        signature = ""
        update(f, ai: true)
    }

    func update(_ f: Facts, ai: Bool) {
        lastFacts = f
        let signature = Self.signature(f, ai: ai)
        guard signature != self.signature else { return }
        self.signature = signature
        text = Self.template(f)
        fromAI = false
        guard ai, AppleIntelligence.available else { return }
        generation += 1
        let g = generation
        Task { [weak self] in
            guard let sentence = await AppleIntelligence.phrase(f), let self, g == self.generation else { return }
            self.text = sentence
            self.fromAI = true
        }
    }

    /// Faster / slower / about the usual pace: the drain against the learned prior, with 20 % of slack.
    static func pace(_ f: Facts) -> String? {
        guard let rate = f.ratePerHour, let typical = f.typicalRate, typical > 0 else { return nil }
        if rate > typical * 1.2 { return "faster" }
        if rate < typical * 0.8 { return "slower" }
        return "usual"
    }

    /// What the sentence hangs on; when this changes, new words. The wording switch too: turning it on phrases
    /// the line now, turning it off puts the template straight back.
    static func signature(_ f: Facts, ai: Bool) -> String {
        [f.onAC ? "ac" : "batt", f.charging ? "chg" : "", f.full ? "full" : "", pace(f) ?? "-",
         f.minutesLeft.map { "\($0 / 30)" } ?? "?", f.ratePerHour.map { "\(Int($0))" } ?? "?", f.topApps.joined(separator: ","), ai ? "ai" : ""].joined(separator: "|")
    }

    static func template(_ f: Facts) -> String {
        let apps = f.topApps.isEmpty ? "" : " \(f.topApps.joined(separator: " and ")) \(f.topApps.count == 1 ? "is" : "are") using the most power."
        if f.onAC {
            if f.full { return "Fully charged. Letting it sit at 100% all day is the one thing batteries dislike." + apps }
            if f.charging, let rate = f.ratePerHour { return String(format: "Charging at about %.0f%% an hour.", rate) + apps }
            return "On power with the battery resting at \(f.percent)%." + apps
        }
        guard let rate = f.ratePerHour else { return "Watching the battery to work out how fast it's draining." + apps }
        let drain = String(format: "Draining at %.0f%% an hour", rate)
        switch pace(f) {
        case "faster": return drain + String(format: ", faster than your usual %.0f%% for this time of day.", f.typicalRate!) + apps
        case "slower": return drain + String(format: ", easier than your usual %.0f%% for this time of day.", f.typicalRate!) + apps
        case "usual": return drain + ", about your usual pace for this time of day." + apps
        default: return drain + ". JuiceLeft learns your usual pace as it goes." + apps
        }
    }
}

/// The on-device model, reached only on macOS 26+ with Apple Intelligence turned on; everywhere else these are no-ops
/// and the template sentence stands. FoundationModels is weak-linked (see build.sh).
enum AppleIntelligence {
    /// What the system model says: on, off on a Mac that could run it, a Mac that can't, still downloading, or no
    /// FoundationModels at all (macOS 13–15).
    enum Status: Equatable { case available, notEnabled, notEligible, notReady, unsupported }

    static var available: Bool { status == .available }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return Bridge.status }
        #endif
        return .unsupported
    }

    /// The first-launch line asking to turn Apple Intelligence on: only when this Mac could run it but hasn't, and
    /// not once dismissed. Pure, for --selftest.
    static func offersNudge(status: Status, dismissed: Bool) -> Bool { status == .notEnabled && !dismissed }

    /// System Settings › Apple Intelligence & Siri (macOS 26's pane id), or System Settings itself if that link fails.
    static func openSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    static func phrase(_ f: Insight.Facts) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return await Bridge.phrase(f) }
        #endif
        return nil
    }

    /// Every number in the model's sentence must already be in the facts it was given.
    static func keepsNumbers(_ sentence: String, facts: String) -> Bool {
        let numbers = { (s: String) in Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init)) }
        return numbers(sentence).isSubset(of: numbers(facts))
    }

    static func factsLine(_ f: Insight.Facts) -> String {
        var parts = ["Battery \(f.percent)%."]
        if f.onAC { parts.append(f.full ? "Fully charged." : f.charging ? "Charging." : "On power, not charging.") }
        if let m = f.minutesLeft { parts.append(f.onAC ? "\(f.target < 100 ? "\(f.target)%" : "Full") in \(Format.duration(m))." : "Flat in \(Format.duration(m)).") }
        if let r = f.ratePerHour { parts.append(String(format: f.onAC ? "Charging at %.0f%% per hour." : "Draining at %.0f%% per hour.", r)) }
        if let t = f.typicalRate, !f.onAC { parts.append(String(format: "Usual drain at this time of day: %.0f%% per hour.", t)) }
        if !f.topApps.isEmpty { parts.append("Apps using the most power: \(f.topApps.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
enum Bridge {
    @Generable struct Line {
        @Guide(description: "One friendly sentence for a Mac user, at most 25 words, using only numbers that appear in the facts")
        var sentence: String
    }

    static var available: Bool { SystemLanguageModel.default.availability == .available }

    static var status: AppleIntelligence.Status {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .deviceNotEligible: return .notEligible
            default: return .notReady   // the model is still on its way down
            }
        }
    }

    static func phrase(_ f: Insight.Facts) async -> String? {
        guard available else { return nil }
        let facts = AppleIntelligence.factsLine(f)
        let session = LanguageModelSession(instructions:
            "You write the one-line status for JuiceLeft, a Mac battery app. Rephrase the facts you are given as one plain, friendly sentence of at most 25 words. Use only numbers that appear in the facts; never add, round or invent numbers. No preamble, no advice beyond what the facts support.")
        guard let response = try? await session.respond(to: "Facts: \(facts)", generating: Line.self) else { return nil }
        let sentence = response.content.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 10 && AppleIntelligence.keepsNumbers(sentence, facts: facts) ? sentence : nil
    }
}
#endif
