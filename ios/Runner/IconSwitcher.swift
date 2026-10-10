import Flutter
import UIKit

/// Alternate launcher icon switch (issue #23).
///
/// Uses `UIApplication.setAlternateIconName()`, which is first-class and
/// supported — no component gymnastics needed, unlike Android. The system
/// applies the new icon itself and persists the choice, so there is nothing to
/// restore on launch.
enum AppIconVariant: String {
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
                case AppIconVariant.mark.rawValue: result("mark")
                case AppIconVariant.red.rawValue: result("red")
                case AppIconVariant.green.rawValue: result("green")
                case AppIconVariant.cyan.rawValue: result("cyan")
                default: result("default")
                }
            case "applyVariant":
                guard let args = call.arguments as? [String: Any],
                      let variant = args["variant"] as? String else {
                    result(FlutterError(code: "bad_args",
                                        message: "variant is required", details: nil))
                    return
                }
                let target: String? = {
                    switch variant {
                    case "mark": return AppIconVariant.mark.rawValue
                    case "red": return AppIconVariant.red.rawValue
                    case "green": return AppIconVariant.green.rawValue
                    case "cyan": return AppIconVariant.cyan.rawValue
                    default: return nil
                    }
                }()
                guard target != nil || variant == "default" else {
                    result(FlutterError(code: "bad_variant",
                                        message: "Unknown icon variant: \(variant)",
                                        details: nil))
                    return
                }
                // nil restores the primary icon.
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