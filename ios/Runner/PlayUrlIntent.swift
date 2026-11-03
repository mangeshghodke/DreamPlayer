import AppIntents
import Foundation

/// Shortcuts action "Play URL in DreamPlayer": takes a video URL and hands it
/// to the app through the same `dreamplayer/intent` channel the share sheet
/// uses, so Dart plays it via the normal OpenIntent -> PlayerScreen flow.
///
/// The intent runs after the app opens (`openAppWhenRun`), but the Flutter
/// engine may not have registered its channels yet, so IntentBridge queues
/// the payload and flushes it when the channel is configured.
@available(iOS 16.0, *)
struct PlayUrlIntent: AppIntent {
    static var title: LocalizedStringResource = "Play URL in DreamPlayer"
    static var description = IntentDescription("Play a video URL in DreamPlayer")
    static var openAppWhenRun = true

    @Parameter(title: "Video URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(PlayUrlIntent.$url) in DreamPlayer")
    }

    func perform() async throws -> some IntentResult {
        IntentBridge.shared.handleOpenURL(url)
        return .result()
    }
}
