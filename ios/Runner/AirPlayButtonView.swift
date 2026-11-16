import AVKit
import Flutter
import UIKit

/// Hosts the system's own `AVRoutePickerView` inside a Flutter platform view.
///
/// `AVRoutePickerView` has no public "present the picker" API - the user has
/// to tap the control itself - so a method-channel call that opened a sheet
/// from Dart is not possible. Embedding the real control is the only honest
/// way to expose AirPlay, and it keeps Apple's route UI (and its active-route
/// tint) exactly as the system draws it.
///
/// View id: `dreamplayer/airplay`.
final class AirPlayButtonFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AirPlayButtonPlatformView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class AirPlayButtonPlatformView: NSObject, FlutterPlatformView {
  private let container: AirPlayButtonContainer

  init(frame: CGRect) {
    container = AirPlayButtonContainer(frame: frame)
    super.init()
  }

  func view() -> UIView {
    container
  }
}

/// The picker pinned to the container's bounds.
///
/// Sized by Flutter (a 40x40 hole in the player's top bar), so no intrinsic
/// size is needed; the picker's icon is drawn at its natural size and centred
/// by the system.
final class AirPlayButtonContainer: UIView {
  private let picker = AVRoutePickerView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    picker.backgroundColor = .clear
    picker.tintColor = .white
    picker.activeTintColor = .white
    // The player is showing video: prefer receivers that can take the picture,
    // so an audio-only HomePod is not offered before an Apple TV.
    picker.prioritizesVideoDevices = true
    picker.translatesAutoresizingMaskIntoConstraints = false
    addSubview(picker)
    NSLayoutConstraint.activate([
      picker.leadingAnchor.constraint(equalTo: leadingAnchor),
      picker.trailingAnchor.constraint(equalTo: trailingAnchor),
      picker.topAnchor.constraint(equalTo: topAnchor),
      picker.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }
}
