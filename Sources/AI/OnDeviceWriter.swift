import Foundation
import FoundationModels

/// The no-login fallback: macOS's on-device model.
///
/// Worse at this than Claude and given a much smaller slice of the diff, but it
/// works with no account, no network and nothing leaving the machine — which is
/// the whole reason it is here rather than an error message.
nonisolated enum OnDeviceWriter {

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model cannot be used, in words worth showing someone.
    static var unavailableReason: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else {
            return nil
        }
        switch reason {
        case .deviceNotEligible: return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
        case .modelNotReady: return "The on-device model is still downloading"
        @unknown default: return "The on-device model is unavailable"
        }
    }

    static func write(
        statistics: String, diff: String, convention: CommitConvention
    ) async throws -> GeneratedCommitMessage {
        let (body, truncated) = CommitMessagePrompt.body(
            statistics: statistics, diff: diff, limit: CommitMessagePrompt.onDeviceDiffLimit,
            convention: convention, subjectLimit: CommitMessagePrompt.onDeviceSubjectLimit)

        let session = LanguageModelSession(instructions: CommitMessagePrompt.instructions)
        do {
            let response = try await session.respond(to: body)
            let text = CommitMessagePrompt.clean(response.content)
            guard !text.isEmpty else { throw CommitMessageError.emptyResponse }
            return GeneratedCommitMessage(text: text, source: .onDevice, wasTruncated: truncated)
        } catch let error as CommitMessageError {
            throw error
        } catch {
            throw CommitMessageError.providerFailed("\(error)")
        }
    }
}
