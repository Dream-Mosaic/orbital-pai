import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../meridian/orientation_lock.dart' show kPhoneShortestSide;

/// What this piece of hardware is for (spec 2026-10-23, wall tablet, phase 1).
///
/// A property of the DEVICE, not of whoever is signed in: it lives in a local
/// file, survives sign-out, and is never a server pref.
enum DeviceRole {
  /// A dedicated always-on household display: screen held on, no system
  /// bars, joins as `kiosk: true`, dims at night.
  wall,

  /// Someone's own phone or tablet: exactly the app's behaviour before wall
  /// mode existed.
  personal,
}

/// The role a device gets before anyone has chosen one: a wall when the
/// shortest side clears the phone line [orientation_lock.dart] already draws
/// (600 dp), a personal device otherwise. A stored choice always wins.
DeviceRole defaultRoleFor(Size logicalSize) =>
    logicalSize.shortestSide >= kPhoneShortestSide ? DeviceRole.wall : DeviceRole.personal;

/// This device's settings, as stored in `device.json`.
@immutable
class DeviceSettings {
  const DeviceSettings({required this.role, this.dimAtNight = true, bool shared = true})
      : _shared = shared;

  final DeviceRole role;

  /// Whether a wall dims between 22:00 and 07:00 once at rest. Meaningless on
  /// a personal device (which never dims), but kept so flipping back to wall
  /// restores the last choice.
  final bool dimAtNight;

  /// The "Shared household device" switch as last set, whatever the role:
  /// stored on a personal device for the same reason [dimAtNight] is. Read
  /// [shared], never this, for what the device IS.
  final bool _shared;

  /// Whether this device speaks for the household (spec 2026-10-23, wall
  /// tablet, phase 4): while the conversation is bound to it, "remind me"
  /// lands on the household, email is off, and the header says HOUSEHOLD.
  /// On by default for a wall. ALWAYS false on a personal device, whatever
  /// was stored — someone's own phone must never report itself shared.
  bool get shared => role == DeviceRole.wall && _shared;

  DeviceSettings copyWith({DeviceRole? role, bool? dimAtNight, bool? shared}) => DeviceSettings(
        role: role ?? this.role,
        dimAtNight: dimAtNight ?? this.dimAtNight,
        shared: shared ?? _shared,
      );

  Map<String, Object?> toJson() =>
      {'role': role.name, 'dim_at_night': dimAtNight, 'shared': _shared};

  /// Tolerant by design: a missing or unknown `role` falls back to
  /// [fallbackRole], and a missing or non-bool `dim_at_night` or `shared` to
  /// true, so a file written by an older or newer build never costs the
  /// device its defaults — a phase-1 wall, whose file has no `shared`, comes
  /// up shared.
  factory DeviceSettings.fromJson(Map<String, Object?> json, {required DeviceRole fallbackRole}) {
    final rawRole = json['role'];
    final role = DeviceRole.values.firstWhere(
      (r) => r.name == rawRole,
      orElse: () => fallbackRole,
    );
    final dim = json['dim_at_night'];
    final shared = json['shared'];
    return DeviceSettings(
      role: role,
      dimAtNight: dim is bool ? dim : true,
      shared: shared is bool ? shared : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceSettings &&
      other.role == role &&
      other.dimAtNight == dimAtNight &&
      other._shared == _shared;

  @override
  int get hashCode => Object.hash(role, dimAtNight, _shared);

  @override
  String toString() =>
      'DeviceSettings(role: ${role.name}, dimAtNight: $dimAtNight, shared: $_shared)';
}

/// Where [DeviceSettings] persist. A seam so the controller is testable
/// without a filesystem.
abstract interface class DeviceStore {
  /// The stored JSON object, or null when nothing has been stored yet. May
  /// throw on a corrupt file; [DeviceController.load] treats that as "nothing
  /// stored".
  Future<Map<String, Object?>?> read();

  Future<void> write(Map<String, Object?> json);
}

/// `<applicationSupportDirectory>/device.json`. Not the secure store: nothing
/// here is secret, and a keystore that misbehaves must not cost a wall its
/// role.
class FileDeviceStore implements DeviceStore {
  const FileDeviceStore();

  static const String fileName = 'device.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<Map<String, Object?>?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('device.json is not an object');
    return decoded.cast<String, Object?>();
  }

  @override
  Future<void> write(Map<String, Object?> json) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    // Write-then-rename, so a crash mid-write leaves the old file whole rather
    // than a truncated one the next launch has to fall back from.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }
}

/// An in-memory [DeviceStore] for tests.
class MemoryDeviceStore implements DeviceStore {
  MemoryDeviceStore([this.stored]);

  Map<String, Object?>? stored;

  /// How many times [write] ran, so a test can see a change was persisted.
  int writes = 0;

  @override
  Future<Map<String, Object?>?> read() async => stored;

  @override
  Future<void> write(Map<String, Object?> json) async {
    writes++;
    stored = Map<String, Object?>.of(json);
  }
}

/// This device's role and wall options, loaded once in `main()` before
/// `runApp` — so the very first `voice:henry` join after a cold start already
/// knows whether it is a wall — and changed from Settings ▸ This device.
class DeviceController extends ChangeNotifier {
  DeviceController._(this._settings, this._store);

  /// A controller that never persists: for tests, and for a [HenryHome] that
  /// was not handed one (a personal device, exactly as before wall mode).
  DeviceController.fixed(DeviceSettings settings) : this._(settings, null);

  /// Bound on the store read, so a wedged platform call costs the device its
  /// stored choice for this launch rather than the launch itself.
  static const Duration defaultReadTimeout = Duration(seconds: 2);

  /// Reads [store] and falls back to [defaultRoleFor] on anything short of a
  /// clean read: a missing file, corrupt JSON, a read that throws or hangs.
  /// Never throws — this runs before `runApp`, where a throw is a crash at
  /// startup.
  static Future<DeviceController> load({
    required DeviceStore store,
    required Size logicalSize,
    Duration readTimeout = defaultReadTimeout,
  }) async {
    final fallback = defaultRoleFor(logicalSize);
    var settings = DeviceSettings(role: fallback);
    try {
      final json = await store.read().timeout(readTimeout);
      if (json != null) settings = DeviceSettings.fromJson(json, fallbackRole: fallback);
    } catch (e) {
      debugPrint('[device] could not read device settings, using defaults: $e');
    }
    return DeviceController._(settings, store);
  }

  DeviceSettings _settings;
  final DeviceStore? _store;

  DeviceSettings get settings => _settings;
  bool get isWall => _settings.role == DeviceRole.wall;

  /// A wall marked "Shared household device" — see [DeviceSettings.shared].
  /// False on every personal device.
  bool get isShared => _settings.shared;

  Future<void> setWall(bool wall) =>
      _update(_settings.copyWith(role: wall ? DeviceRole.wall : DeviceRole.personal));

  Future<void> setDimAtNight(bool on) => _update(_settings.copyWith(dimAtNight: on));

  Future<void> setShared(bool on) => _update(_settings.copyWith(shared: on));

  /// Applies first and persists second, so the screen answers the switch at
  /// once; a failed write is logged and costs only the next launch's memory
  /// of the choice.
  Future<void> _update(DeviceSettings next) async {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    final store = _store;
    if (store == null) return;
    try {
      await store.write(next.toJson());
    } catch (e) {
      debugPrint('[device] could not save device settings: $e');
    }
  }
}
