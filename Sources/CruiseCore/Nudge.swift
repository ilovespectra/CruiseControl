import Foundation

/// Builds the Ollama request for a "Needs you" nudge and cleans up what comes back.
public enum Nudge {
    public static let system = """
    You write the next chat message a user sends to their AI computer agent ("Clicky") after the agent stopped \
    and flagged that it needs the user. The user is away from the computer and wants the agent to persist.

    Read the transcript. Work out the original goal, what the agent tried, and exactly why it stopped. \
    The LATEST MESSAGES section matters most; earlier context explains the goal and what I already said is OK.
    Short lines at the end such as "Restart with updated Rippa … 2/4" are the agent's own checklist and progress; \
    it stopped on the first unfinished step.
    Then write ONE short message (2-4 sentences) that I, the user, send to the agent. Address the agent as "you"; \
    the agent does the work, so never write "I'll" or "let me" about doing the task. The message:
    - names the specific blocker and gives a concrete next step that gets past it, grounded in the transcript
    - if it couldn't test or verify something because the thing to test doesn't exist yet (no recording, no take, \
    no sample file, no test data, no build), tell it to create that itself first (e.g. record a short new test take, \
    make a sample file) and then run the test on it, using what I already said is fine to use
    - tells it to keep going without waiting for me since I'm away, make sensible assumptions instead of asking, \
    and report what it did when finished
    Never ask it to skip or bypass safety checks or permission prompts. Never invent facts that aren't in the transcript.
    Never claim I approved, allowed, granted, selected, clicked, typed or confirmed anything, and never answer \
    permission, password, keychain or security questions on my behalf. If it is truly blocked on one of those, \
    tell it to leave that step for me and carry on with everything else.
    Think it through before writing. Reply with JSON only, filling the fields in this order:
    {"goal": "what I originally asked for",
     "stopped_at": "the step it stopped on",
     "why": "why it stopped or couldn't finish that step",
     "missing": "anything that must exist for that step but doesn't yet (a fresh recording/take, file, data, build), or none",
     "ok_to_use": "anything I said it may use or change",
     "message": "the message to send"}
    """

    /// Collapses repeated lines and keeps the most recent part of the conversation. Lines that would steer the model
    /// toward faking consent (including Cruise Control's own rejected drafts) and `exclude`d boilerplate are dropped.
    public static func transcript(_ lines: [String], maxCharacters: Int = 6000, exclude: [String] = []) -> String {
        let excluded = Set(exclude.map(Matcher.normalize))
        var cleaned: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != cleaned.last, isSafe(line), !excluded.contains(Matcher.normalize(line)) else { continue }
            cleaned.append(line)
        }
        var kept: [String] = []
        var total = 0
        for line in cleaned.reversed() {
            total += line.count + 1
            if total > maxCharacters { break }
            kept.append(line)
        }
        return kept.reversed().joined(separator: "\n")
    }

    public static func prompt(task: String, transcript: String) -> String {
        """
        Task name: \(task.isEmpty ? "unknown" : task)
        HeyClicky marked this task as "Needs you".

        \(sections(transcript))

        Write the message now.
        """
    }

    /// Splits the transcript so the latest lines stand out to small models.
    static func sections(_ transcript: String, latestLines: Int = 10) -> String {
        guard !transcript.isEmpty else { return "Transcript: (unavailable)" }
        let lines = transcript.components(separatedBy: "\n")
        let latest = lines.suffix(latestLines).joined(separator: "\n")
        let earlier = lines.dropLast(latestLines).joined(separator: "\n")
        return (earlier.isEmpty ? "" : "EARLIER CONTEXT (oldest first):\n\(earlier)\n\n")
            + "LATEST MESSAGES (most recent last — this is where it stopped):\n\(latest)"
    }

    /// Pulls "message" out of the model's JSON answer (falls back to the raw text).
    public static func extractMessage(_ output: String) -> String {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else { return output }
        return message
    }

    /// Strips common model chatter. Returns nil when nothing usable is left.
    public static func sanitize(_ output: String, maxCharacters: Int = 700) -> String? {
        var text = extractMessage(output).replacingOccurrences(of: "\r", with: "")
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = ["message:", "here's the message:", "here is the message:", "user:", "reply:", "response:"]
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes = CharacterSet(charactersIn: "\"“”'‘’`")
        text = text.trimmingCharacters(in: quotes.union(.whitespacesAndNewlines))
        text = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if text.count > maxCharacters {
            let cut = text.prefix(maxCharacters)
            if let end = cut.lastIndex(where: { ".!?".contains($0) }) {
                text = String(cut[...end])
            } else {
                text = String(cut)
            }
        }
        return text.count >= 20 ? text : nil
    }
}

extension Nudge {
    private static let unsafePatterns: [NSRegularExpression] = [
        #"\b(assume|pretend|act as if|treat it as if|consider)\b[^.!?]{0,60}\b(i|i've|i have|i'd|user)\b[^.!?]{0,30}\b(selected|approved|allowed|granted|clicked|entered|typed|confirmed|accepted|authori[sz]ed|agreed)\b"#,
        #"\balways allow\b"#,
        #"\b(password|passcode|passphrase|2fa|one[- ]time code|verification code|api key|secret key)\b"#,
        #"\b(bypass|circumvent|disable|skip|ignore|override)\b[^.!?]{0,40}\b(permission|consent|safety|security|guardrail|confirmation|prompt|warning)s?\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// False when a draft fakes the user's consent or touches credentials/safety checks.
    public static func isSafe(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return !unsafePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    public static let saferRetryNote = """

    Your previous draft was rejected because it claimed I approved or granted something, or touched credentials \
    or safety checks. Write it again without doing that.
    """

    public static func stallNote(lastLine: String, minutes: Int) -> String {
        """

        Extra context: HeyClicky has been silent for about \(minutes) minutes. Its last message was: "\(lastLine.prefix(300))". \
        If that message asks me a question, answer it directly with the choice that keeps the work moving, preferring the \
        option that doesn't throw away work. Never agree to delete my files or data, spend money, message other people, \
        or enter credentials; for those, tell it to skip that part and continue with the rest. Then ask it to keep going.
        """
    }

    public static func relaunchNote(fromVersion: String, toVersion: String) -> String {
        let versions = toVersion.isEmpty ? "" : " (from \(fromVersion) to \(toVersion))"
        return """

        Extra context: HeyClicky was just updated\(versions) and relaunched, which interrupted it mid-task. \
        Write the message asking it to pick up exactly where it left off on this task and keep going.
        """
    }
}

/// Per-task nudge budget, so one stuck task can't loop forever.
public struct NudgeLimiter: Codable, Sendable {
    private var history: [String: [Date]] = [:]

    public init() {}

    public mutating func allow(task: String, now: Date, maxPerHour: Int) -> Bool {
        let key = Matcher.normalize(task)
        let recent = (history[key] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        history[key] = recent
        return recent.count < maxPerHour
    }

    public mutating func record(task: String, at date: Date) {
        history[Matcher.normalize(task), default: []].append(date)
    }
}
