import Flutter
import UIKit

/// Alternate launcher icon switch (issue #23).
///
/// Uses `UIApplication.setAlternateIconName()`, which is first-class and
/// supported — no component gymnastics needed, unlike Android. The system
/// applies the new icon itself and persists the choice, so there is nothing to
/// restore on launch.
///
/// Since 0.5.7 the PRIMARY icon (`ASSETCATALOG_COMPILER_APPICON_NAME`) is
/// `AppIconMark` — the logo only — and the original logo + "DreamPlayer"
/// wordmark (`AppIcon`) is one of the alternates. So `nil`
/// (no alternate selected) means the mark, and the wordmark is reached via
/// `setAlternateIconName("AppIcon")`.
enum AppIconVariant: String {
    case wordmark = "AppIcon"
    case mark = "AppIconMark"
    case red = "AppIconRed"
    case green = "AppIconGreen"
    case cyan = "AppIconCyan"
}

final class IconSwitcher {

    static let channelName = "dreamplayer/appicon"

    static func configure(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "currentVariant":
                // The system already knows; asking it avoids a second source
                // of truth that could drift from what is actually on screen.
                let name = UIApplication.shared.alternateIconName
                switch name {
                case AppIconVariant.wordmark.rawValue: result("default")
                case AppIconVariant.mark.rawValue: result("mark")
                case AppIconVariant.red.rawValue: result("red")
                case AppIconVariant.green.rawValue: result("green")
                case AppIconVariant.cyan.rawValue: result("cyan")
                // nil (primary) is the mark since 0.5.7.
                default: result("mark")
                }
            case "applyVariant":
                guard let args = call.arguments as? [String: Any],
                      let variant = args["variant"] as? String else {
                    result(FlutterError(code: "bad_args",
                                        message: "variant is required", details: nil))
                    return
                }
                let target: String?
                switch variant {
                case "default": target = AppIconVariant.wordmark.rawValue
                // The primary icon IS the mark — nil restores it.
                case "mark": target = nil
                case "red": target = AppIconVariant.red.rawValue
                case "green": target = AppIconVariant.green.rawValue
                case "cyan": target = AppIconVariant.cyan.rawValue
                default:
                    result(FlutterError(code: "bad_variant",
                                        message: "Unknown icon variant: \(variant)",
                                        details: nil))
                    return
                }
                UIApplication.shared.setAlternateIconName(target) { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            result(FlutterError(code: "icon_failed",
                                                message: error.localizedDescription,
                                                details: nil))
                        } else {
                            result(true)
                        }
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}