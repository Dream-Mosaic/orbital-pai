import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connection/app_connection.dart';
import '../deep_link.dart';
import '../phoenix/decoded_message.dart';
import '../phoenix/phoenix_channel.dart';

/// One (account, granted connector) pair, already derived for display.
///
/// Every field here is computed SERVER-SIDE, including the three booleans, and
/// the list arrives pre-sorted by {label, email}. Do not re-derive or re-sort
/// any of it: [onlyGrant] in particular is what decides whether Disconnect can
/// work at all, and a client that recomputes it from a stale payload is the
/// exact bug the channel's re-derivation defends against.
class Connection {
  const Connection({
    required this.accountId,
    required this.email,
    required this.connector,
    required this.label,
    required this.access,
    required this.isDefault,
    required this.showsDefault,
    required this.onlyGrant,
  });

  /// The google_accounts row id. The handle both writes push.
  final int accountId;
  final String email;

  /// "calendar" | "gmail" — the registry key as a string. Pushed back verbatim
  /// on disconnect and matched against the server's own allowlist there.
  final String connector;

  /// "Google Calendar" | "Gmail" — Connectors.label/1.
  final String label;

  /// "read" | "write". Never "none": a row only exists for a granted connector.
  final String access;

  /// This account is the user's write default.
  final bool isDefault;

  /// At least two accounts can reach this connector, so there is a choice to
  /// make and the default badge/button is worth showing. The web's
  /// connector_multi?/2.
  final bool showsDefault;

  /// This connector is the account's ONLY grant, so disconnecting it means
  /// deleting the account — which is pure DB and works natively. False means
  /// the reduction needs Google's consent page; see ConnectorsPanelView.
  final bool onlyGrant;

  static Connection fromJson(Map<String, dynamic> j) => Connection(
        accountId: (j['account_id'] as num).toInt(),
        email: j['email'] as String? ?? '',
        connector: j['connector'] as String,
        label: j['label'] as String? ?? '',
        access: j['access'] as String? ?? '',
        isDefault: j['is_default'] as bool? ?? false,
        showsDefault: j['shows_default'] as bool? ?? false,
        onlyGrant: j['only_grant'] as bool? ?? false,
      );
}

/// One option of a `"choice"` [FormField] — e.g. {"value": "read", "label":
/// "read"} for the access-level picker.
class FieldOption {
  const FieldOption({required this.value, this.label = ''});

  /// The wire value; pushed verbatim as part of `grant_url`'s `fields` map.
  final String value;
  final String label;

  static FieldOption fromJson(Map<String, dynamic> j) => FieldOption(
        value: j['value'] as String,
        label: j['label'] as String? ?? '',
      );
}

/// One field of a [ConnectorSpec]'s form, e.g. the account picker or the
/// access-level choice.
///
/// [type] is a free-form string the server can extend without a client
/// release — Home Assistant and CouchDB are queued providers whose forms will
/// need field types this client has never seen (see
/// `connectors_channel.ex`'s moduledoc). An unrecognized [type] MUST still
/// parse here: rendering it is Task 4's problem, and dropping the whole
/// connector over one unfamiliar field would hide a server capability behind
/// a client that simply hadn't caught up yet.
class FormField {
  const FormField({
    required this.name,
    this.label = '',
    this.type = '',
    this.required = false,
    this.options = const [],
    this.defaultValue,
  });

  /// The key this field's value is pushed under inside `grant_url`'s `fields`
  /// map. A field without one cannot be acted on, so the catalog parser drops
  /// the whole field rather than keep an unaddressable one.
  final String name;
  final String label;

  /// "account_select" | "choice" | anything a future provider adds. Never
  /// validated against a known set — see the class doc.
  final String type;
  final bool required;

  /// Only meaningful for a "choice"-shaped field; empty for anything else.
  final List<FieldOption> options;

  /// The value this field should start on, chosen by the SERVER because the
  /// server owns the rule for what a safe/sensible starting point is — e.g.
  /// Access defaults to "read", not "none" (`connectors_channel.ex`'s
  /// `catalog/0`), because a generic client guessing `options.first` landed
  /// on "none" and produced a request the channel refuses; see the
  /// 2026-08-27 whole-branch review's HIGH finding. Generic like [options]:
  /// any field type may carry one (`account` does too, even though its
  /// options aren't server-sent at all — see [ConnectorSpec]'s
  /// `_accountSelectField` doc). A field without one, or an unrecognized
  /// [type], falls back to a kind-specific default the client picks itself
  /// — see `connectors_panel.dart`'s `_defaultsFor`. Untyped (`Object?`) for
  /// the same reason [FieldOption.value] is a bare `String`: this client
  /// never interprets it, only forwards it back verbatim.
  final Object? defaultValue;

  static FormField fromJson(Map<String, dynamic> j) => FormField(
        name: j['name'] as String,
        label: j['label'] as String? ?? '',
        type: j['type'] as String? ?? '',
        required: j['required'] == true,
        options: _options(j['options']),
        defaultValue: j['default'],
      );

  // A value-less option cannot be selected (there would be nothing to push),
  // so drop just that option — filtered, not cast, same discipline as every
  // list below.
  static List<FieldOption> _options(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['value'] is String)
          .map(FieldOption.fromJson)
          .toList(growable: false)
      : const [];
}

/// One entry of the connectors catalog: describes how to ADD or CHANGE a
/// connector, as opposed to [Connection] which describes one already granted.
///
/// `kind` says how the flow completes ("oauth_redirect" is the only one
/// implemented server-side today); `fields` is the form this client renders.
/// A new provider (Home Assistant, CouchDB — see `IDEAS.md`) is meant to show
/// up here with no Dart change, which is the whole reason the shape is
/// generic rather than baking in "account" and "level" by name.
class ConnectorSpec {
  const ConnectorSpec({
    required this.key,
    this.label = '',
    this.provider = '',
    this.kind = '',
    this.fields = const [],
  });

  /// "calendar" | "gmail" — the handle [ConnectorsClient.grantUrl] pushes.
  final String key;
  final String label;

  /// "google" today; the field that will distinguish Home Assistant/CouchDB
  /// entries once they exist.
  final String provider;

  /// "oauth_redirect" is the only flow this client knows how to complete
  /// (open the returned URL in the system browser). An unrecognized kind
  /// still parses — same reasoning as [FormField.type] — a future provider's
  /// flow just isn't renderable yet.
  final String kind;
  final List<FormField> fields;

  static ConnectorSpec fromJson(Map<String, dynamic> j) => ConnectorSpec(
        key: j['key'] as String,
        label: j['label'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        fields: _fields(j['fields']),
      );

  // name is the handle grant_url's `fields` map keys off of, so a field
  // without one cannot be rendered into anything actionable — drop just that
  // field, the rest of the form still lands.
  static List<FormField> _fields(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['name'] is String)
          .map(FormField.fromJson)
          .toList(growable: false)
      : const [];
}

/// The Connectors drawer's state, as the server rendered it.
class ConnectorsState {
  const ConnectorsState({required this.connections, this.catalog = const []});

  final List<Connection> connections;

  /// What CAN be added/changed, independent of [connections] (what already
  /// IS). Server-ordered (`Connectors.all/0`); never re-sort here.
  final List<ConnectorSpec> catalog;

  static ConnectorsState fromJson(Map<String, dynamic> j) => ConnectorsState(
        connections: _connections(j['connections']),
        catalog: _catalog(j['catalog']),
      );

  // account_id and connector are the two handles a write pushes, so a row
  // missing either cannot be acted on — drop just that row rather than letting
  // a cast throw inside the stream listener and blank an otherwise good
  // payload, the same tolerance memory_client.dart and voice_lock_client.dart
  // apply to their own list rows.
  static List<Connection> _connections(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['account_id'] is num && m['connector'] is String)
          .map(Connection.fromJson)
          .toList(growable: false)
      : const [];

  // key is the handle grant_url pushes, so an entry without one cannot be
  // acted on — drop just that entry, its siblings still land. This is the
  // ONLY filter here: everything else (label, provider, kind, fields, and any
  // field's type) is free-form and must survive even when unfamiliar — see
  // ConnectorSpec's and FormField's class docs.
  static List<ConnectorSpec> _catalog(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['key'] is String)
          .map(ConnectorSpec.fromJson)
          .toList(growable: false)
      : const [];
}

/// Joined only while the Connectors drawer is on screen.
/// Server-authoritative: a control pushes and the UI re-renders from the next
/// `state`.
class ConnectorsClient extends ChangeNotifier {
  ConnectorsClient({required AppConnection connection})
      : _connection = connection;

  static const String topic = 'panel:connectors:henry';

  final AppConnection _connection;

  PhoenixChannel? _channel;
  StreamSubscription<DecodedMessage>? _sub;
  ConnectorsState? _state;
  bool _open = false;
  bool _disposed = false;

  // ---- reply correlation ----
  //
  // PhoenixChannel.push (phoenix_channel.dart) returns void. The real per-push
  // ref lives one layer down, in PhoenixSocket's `_pendingRefs` — it is what
  // routes each phx_reply back to the channel that sent the matching push —
  // but that ref never crosses back out through `push`'s void return, so a
  // caller at this level has no ref to key a Future (or a map of Futures) by.
  // A queue keyed by ref is therefore not buildable from here without
  // widening PhoenixChannel's API, which is out of scope for this change.
  //
  // What IS true, and enough on its own: this topic's handlers
  // (`set_default`/`disconnect`/`grant_url` in connectors_channel.ex) all
  // reply synchronously and inline from `handle_in`, so replies land on the
  // wire in the same order the requests were sent. A SINGLE slot recording
  // which request is outstanding is therefore a correct correlation
  // mechanism, on one condition: at most one request may be in flight at a
  // time. That is exactly what the UI already guarantees by construction (a
  // form submit or a Disconnect tap, never both at once) — but trusting that
  // from the outside would make correlation correct by accident. So `_push`
  // ENFORCES it instead of assuming it: a second push while `_pending` is
  // still set is dropped, the same way a push before the join reply is
  // dropped. With that guard in place, a reply can only ever be interpreted
  // as the answer to the one request that could have produced it — a `url`
  // meant for `grant_url` can never be read as the answer to a `disconnect`,
  // or vice versa, because the second request is never sent while the first
  // is still outstanding. See the "a second push while one is pending is
  // dropped" test for the failure mode this closes off.
  String? _pending;

  /// The URL the server just replied with for a `grant_url` push, or for a
  /// `disconnect` that deferred a reduction to Google's consent screen (see
  /// `ConnectorsChannel.handle_in("disconnect", ...)`). The native client's
  /// job is to open this in the system browser; nothing local changes until
  /// that flow completes server-side.
  String? _oauthUrl;

  /// A message for the most recent request THIS client sent that the server
  /// rejected, or null. Client-local UI state, same idiom as
  /// `VoiceLockClient.enrollError`: nothing else on this channel explains a
  /// rejected `set_default`/`disconnect`/`grant_url` — every one of those
  /// handlers replies the same `{:error, %{reason: "bad_request"}}`
  /// (`connectors_channel.ex`), so without this a form submit (or a row
  /// tap) that gets refused does nothing visible at all. That silence was
  /// half of the 2026-08-27 whole-branch review's HIGH finding — the OTHER
  /// half being a default that guaranteed the very first submit would be
  /// one of these. One reason ever comes back, so this is one generic
  /// message, not a reason-keyed catalog: keep it that way unless the
  /// server starts sending a real reason to render.
  String? _requestError;

  /// How the last connector flow that went out to the system browser came back, or null.
  ///
  /// Distinct from [_requestError] on purpose, even though both end up as a line of text in the
  /// panel: that one is about a push THIS client sent and the server refused, and is cleared
  /// by the next push. This one is about a flow that completed somewhere else entirely — in the
  /// browser, minutes ago, with the app backgrounded — and arrives back through a deep link
  /// ([noteOauthResult]), not through this channel at all. Folding them together would mean a
  /// browser result got wiped by an unrelated row tap, or a stale refusal outlived the flow it
  /// described.
  ConnectorsOauthResult? _oauthResult;

  ConnectorsState? get state => _state;
  bool get isOpen => _open;

  /// See [_pending]'s doc for why this is surfaced as a plain nullable field
  /// rather than a Future: there is nothing here to await against per-call,
  /// only "the most recent reply that carried a url".
  String? get oauthUrl => _oauthUrl;

  /// See [_requestError]. Cleared the moment ANY new request goes out (a
  /// retry deserves a clean slate, not yesterday's message), so this is
  /// always about the single most recent request, same as [oauthUrl].
  String? get requestError => _requestError;

  /// See [_oauthResult].
  ConnectorsOauthResult? get oauthResult => _oauthResult;

  /// Record how a browser flow came back, from a deep link the OS delivered.
  ///
  /// Deliberately does NOT clear on the resume refetch that lands alongside it: the refetch is
  /// how the panel learns what actually changed, and wiping the result at the same moment would
  /// leave a failed flow — where by definition nothing changed — with nothing at all to show
  /// for it. It clears on [close], and when a new request goes out.
  void noteOauthResult(ConnectorsOauthResult result) {
    _oauthResult = result;
    _notify();
  }

  /// The view calls this once it has opened [oauthUrl] in the system browser,
  /// so a later rebuild does not reopen it.
  void ackOauthUrl() {
    if (_oauthUrl == null) return;
    _oauthUrl = null;
    _notify();
  }

  void open() {
    if (_open) return;
    _open = true;
    _connection.openChannel(topic, onChannel: _adopt);
  }

  void close() {
    if (!_open) return;
    _open = false;
    _leaveChannel();
    _state = null;
    _oauthUrl = null;
    _requestError = null;
    _oauthResult = null;
    _notify();
  }

  /// Ask the server for a fresh `state` by leaving and rejoining the topic.
  /// There is no separate "give me state again" event to push: the server
  /// sends `state` straight behind every join reply (see [_adopt]'s doc), so
  /// a rejoin IS the refetch.
  ///
  /// The native client's own trigger is app resume (`connectors_panel.dart`'s
  /// `WidgetsBindingObserver`): the OAuth flow that sent the user to the
  /// system browser runs entirely server-side, and this socket has no other
  /// way to learn it finished (or didn't) while the app was backgrounded.
  ///
  /// Guarded on [_open] on purpose, not just as an optimization: a caller
  /// this method exists to protect against is a LEAKED resume observer that
  /// outlives its panel (see the moduledoc there) — without this guard, that
  /// leak would silently reopen a topic this client already tore down in
  /// [close]. The stale `_state`/[_oauthUrl] are left as-is rather than
  /// nulled first, so a resume-triggered refetch does not flash the drawer
  /// back to empty while the rejoin is in flight.
  void refetch() {
    if (!_open) return;
    _leaveChannel();
    _connection.openChannel(topic, onChannel: _adopt);
  }

  void _leaveChannel() {
    _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
    _pending = null;
  }

  void setDefault(int accountId) => _push('set_default', {'account_id': accountId});

  /// Push a disconnect. The payload carries NO `only_grant`: the server
  /// re-derives it, and a client that volunteers one is only offering a stale
  /// answer to a question it cannot answer.
  ///
  /// The reply is either a bare `:ok` (the account was deleted; a fresh
  /// `state` follows) or `{:ok, %{url: ...}}` (this account holds more than
  /// just [connector], so the reduction needs Google's consent screen — see
  /// [oauthUrl]).
  void disconnect({required int accountId, required String connector}) =>
      _push('disconnect', {'account_id': accountId, 'connector': connector});

  /// Ask the server for the URL that starts (or changes) a connector grant.
  /// [fields] mirrors the catalog entry's [ConnectorSpec.fields] by name —
  /// today that is `{"account": <id>|"new", "level": "none"|"read"|"write"}`
  /// for Google, but this method does not know that shape; it only forwards
  /// whatever the caller built from the catalog. [oauthUrl] carries the
  /// reply.
  void grantUrl({
    required String connector,
    required Map<String, Object?> fields,
  }) =>
      _push('grant_url', {'connector': connector, 'fields': fields});

  /// Push a full account removal — the Accounts section's control
  /// (`connectors_panel.dart`), distinct from a per-row [disconnect]. The
  /// server attempts to revoke the account's Google token and deletes the
  /// local record regardless of whether that revoke succeeded; the reply is
  /// a bare `:ok` (a fresh `state` follows) or `{:error, %{reason: ...}}` for
  /// an id this client does not own.
  void removeAccount(int accountId) =>
      _push('remove_account', {'account_id': accountId});

  bool _push(String event, Map<String, dynamic> payload) {
    final ch = _channel;
    // Phoenix answers a frame on a topic it has not joined with "unmatched
    // topic", so a write between open() and the join reply is silently lost.
    if (ch == null || !ch.isJoined) return false;
    // See the "reply correlation" doc above _pending: at most one request may
    // be outstanding on this topic, or a later reply could be misread as the
    // answer to an earlier request. Enforced here, not merely assumed.
    if (_pending != null) return false;
    _pending = event;
    // A retry deserves a clean slate: whatever this NEW request's reply
    // says, it shouldn't have to fight a message left over from the last
    // one. Cleared unconditionally, not only when about to show a fresh
    // error, so a form the user is about to resubmit correctly doesn't
    // still show the last attempt's error while the new one is in flight.
    if (_requestError != null || _oauthResult != null) {
      _requestError = null;
      _oauthResult = null;
      _notify();
    }
    ch.push(event, payload);
    return true;
  }

  /// Delivery is at channel CREATION, not join: the server pushes `state`
  /// straight behind its join reply and `messages` is unbuffered.
  void _adopt(PhoenixChannel ch) {
    _channel = ch;
    // A fresh channel means any request pending on the OLD one will never see
    // its reply (that stream is gone) — holding the slot open would wedge
    // every future push behind a reply that can no longer arrive.
    _pending = null;
    unawaited(_sub?.cancel());
    _sub = ch.messages.listen(_onMessage);
  }

  void _onMessage(DecodedMessage m) {
    if (m.event == 'state') {
      _state = ConnectorsState.fromJson(m.json ?? const <String, dynamic>{});
      _notify();
      return;
    }
    if (m.event != 'phx_reply') return;
    // Whatever this reply answers, it resolves the one outstanding request —
    // see the correlation doc above _pending.
    final answered = _pending;
    _pending = null;
    if (m.replyStatus != 'ok') {
      // See [_requestError]'s doc: this is the ONLY place a rejected
      // request becomes visible at all. `answered` is deliberately not
      // consulted here (unlike the url extraction below) — every handler
      // on this topic can be rejected, so there is no handler this message
      // should be withheld from.
      _requestError =
          "That didn't go through — check your selections and try again.";
      _notify();
      return;
    }
    // Only these two handlers can ever produce a url (connectors_channel.ex);
    // guarding on `answered` means an :ok `set_default` reply — which echoes
    // no url — cannot accidentally pick one up from a stray payload shape.
    if (answered != 'disconnect' && answered != 'grant_url') return;
    final resp = m.json?['response'];
    final url = resp is Map ? resp['url'] : null;
    if (url is String) {
      _oauthUrl = url;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_open) _connection.closeChannel(topic);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
