import 'package:flutter/services.dart';

/// The Android notification channel a notice posts to. Both are created by
/// `HenryNotifier.kt` at startup; the user can mute either one separately in
/// the system's app-notification settings, which is the reason there are two.
enum NoticeChannel {
  /// Timers going off, reminders, calendar heads-ups.
  alerts('henry_alerts'),

  /// Household messages relayed by Henry ("Message from David").
  messages('henry_messages');

  const NoticeChannel(this.id);

  /// The Android channel id. Must match `HenryNotifier.kt`.
  final String id;
}

/// Local notifications: the seam between "something happened while nobody was
/// looking at the app" ([BackgroundNotices]) and the platform that can tell
/// them. A seam so that decision logic is testable headless.
///
/// Nothing here may throw: a notification that cannot be posted must never
/// take the voice screen down with it.
abstract interface class Notifier {
  /// Post (or, for an [id] already on screen, replace) one notification.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NoticeChannel channel,
  });

  Future<void> cancel(int id);

  /// Cancel every notification this app has posted.
  Future<void> cancelAll();

  /// Ask for the notification permission (Android 13+'s POST_NOTIFICATIONS),
  /// at most once per install — the platform side remembers it asked. True
  /// when notifications can be posted.
  Future<bool> requestPermission();
}

/// Android: `MethodChannel('henry/notify')` → `HenryNotifier.kt`. Like the
/// alarm (`henry/alarm`), it is a small hand-written channel rather than a
/// plugin, and it never touches audio — mode, route and focus belong to
/// `AudioRouteOwner.kt`.
///
/// Platforms without the channel (desktop for now) get nothing: a missing
/// plugin is a silent no-op, and a permission request answers false.
class PlatformNotifier implements Notifier {
  static const MethodChannel _ch = MethodChannel('henry/notify');

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NoticeChannel channel,
  }) =>
      _call('show', {'id': id, 'title': title, 'body': body, 'channel': channel.id});

  @override
  Future<void> cancel(int id) => _call('cancel', {'id': id});

  @override
  Future<void> cancelAll() => _call('cancelAll');

  @override
  Future<bool> requestPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } catch (_) {}
  }
}
