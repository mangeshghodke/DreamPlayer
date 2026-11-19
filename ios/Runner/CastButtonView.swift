import Flutter
import GoogleCast

/// Hosts the system's own `GCKCastButton` inside a Flutter platform view.
///
/// `GCKCastButton` has no programmatic "open the picker" API - the user has
/// to tap the control itself - so a method-channel call that opened a sheet
/// from Dart is not possible. Embedding the real control is the only honest
/// way to expose Cast, and it keeps Apple's route UI (and its active-route
/// tint) exactly as the system draws it.
///
/// View id: `dreamplayer/cast_button`.
final class CastButtonFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    CastButtonPlatformView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class CastButtonPlatformView: NSObject, FlutterPlatformView {
  private let container: CastButtonContainer

  init(frame: CGRect) {
    container = CastButtonContainer(frame: frame)
    super.init()
  }

  func view() -> UIView {
    container
  }
}

/// The Cast button pinned to the container's bounds.
///
/// Sized by Flutter (a 40x40 hole in the player's top bar), so no intrinsic
/// size is needed; the button's icon is drawn at its natural size and centred
/// by the system. When a Cast session is active the button is tinted by the
/// system to indicate the active route.
final class CastButtonContainer: UIView {
  private let button = GCKCastButton()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    button.tintColor = .white
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }
}
