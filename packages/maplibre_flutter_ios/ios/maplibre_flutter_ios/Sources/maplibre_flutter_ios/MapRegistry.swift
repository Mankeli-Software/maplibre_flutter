import Foundation

/// Maps the Dart-minted `mapId` to its [MapLibreController].
///
/// Dart mints a `mapId`, passes it via `creationParams`, and looks the
/// controller up here over swiftgen — control flows Dart → ObjC runtime →
/// controller with no data-path method channel (CLAUDE.md §10). Foundation-only
/// so swiftgen can compile it (see [MapLibreController]).
// Plain @objc: runtime name is module-qualified to match the generated bindings
// (see MapLibreController for why).
@objc public class MapRegistry: NSObject {
  private static var controllers: [Int: MapLibreController] = [:]
  private static let lock = NSLock()

  /// Create and register a controller for `mapId` (called from the view factory).
  @objc public static func register(_ mapId: Int) -> MapLibreController {
    let controller = MapLibreController()
    lock.lock()
    controllers[mapId] = controller
    lock.unlock()
    return controller
  }

  /// The controller for `mapId`, or nil if the view does not exist (yet).
  @objc public static func get(_ mapId: Int) -> MapLibreController? {
    lock.lock()
    defer { lock.unlock() }
    return controllers[mapId]
  }

  @objc public static func unregister(_ mapId: Int) {
    lock.lock()
    controllers.removeValue(forKey: mapId)
    lock.unlock()
  }
}
