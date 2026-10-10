import 'package:orbital_pai/notify/notifier.dart';

/// One notification as the fake saw it posted.
class FakeNotice {
  const FakeNotice(this.id, this.title, this.body, this.channel);
  final int id;
  final String title;
  final String body;
  final NoticeChannel channel;

  @override
  String toString() => 'FakeNotice($id, $title, $body, ${channel.id})';
}

/// Headless [Notifier]: records every call, and keeps the set of notifications
/// that would still be on screen (posted, not yet cancelled) the way Android
/// does — a second `show` with the same id REPLACES the first.
class FakeNotifier implements Notifier {
  /// Every `show`, in order — including ones that replaced an earlier id.
  final List<FakeNotice> shown = <FakeNotice>[];

  /// What is on screen right now, by id.
  final Map<int, FakeNotice> active = <int, FakeNotice>{};

  final List<int> cancelled = <int>[];
  int cancelAlls = 0;
  int permissionRequests = 0;
  bool permitted = true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NoticeChannel channel,
  }) async {
    final n = FakeNotice(id, title, body, channel);
    shown.add(n);
    active[id] = n;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    active.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAlls++;
    active.clear();
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permitted;
  }
}
