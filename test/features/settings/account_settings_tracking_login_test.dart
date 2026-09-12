import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/notification_service.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/settings/presentation/account_settings_screen.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/tracking/data/simkl_service.dart';
import 'package:skystream/features/tracking/data/trakt_service.dart';
import 'package:skystream/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Both device-code logins end in a `Future<bool>`. Master showed a toast for
/// `true` and nothing whatsoever for `false` or for a throw, so an expired
/// code, a denied authorisation and a five-minute timeout were all completely
/// silent. These tests pin the failure branch.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  Future<RecordingNotifications> pumpAccounts(
    WidgetTester tester, {
    SimklService? simkl,
    TraktService? trakt,
  }) async {
    final notifications = RecordingNotifications();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationServiceProvider.overrideWithValue(notifications),
          secureTokenStorageProvider.overrideWithValue(NoTokens()),
          settingsRepositoryProvider.overrideWithValue(QuietSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          trackingAuthProvider.overrideWith(SignedOutTrackers.new),
          if (simkl != null) simklServiceProvider.overrideWithValue(simkl),
          if (trakt != null) traktServiceProvider.overrideWithValue(trakt),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AccountSettingsScreen(isEmbedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return notifications;
  }

  testWidgets('a Simkl login that returns false says so', (tester) async {
    final notifications = await pumpAccounts(
      tester,
      simkl: FakeSimkl(result: false),
    );

    await tester.tap(find.text('Simkl'));
    await tester.pumpAndSettle();

    expect(notifications.shown.map((t) => '${t.title}: ${t.message}'), <String>[
      'Simkl: ${l10n.connectionFailed}',
    ]);
    expect(notifications.shown.single.type, ToastType.error);
  });

  testWidgets('a Simkl login that throws is caught and reported', (
    tester,
  ) async {
    final notifications = await pumpAccounts(
      tester,
      simkl: FakeSimkl(error: StateError('no client id')),
    );

    await tester.tap(find.text('Simkl'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(notifications.shown.map((t) => '${t.title}: ${t.message}'), <String>[
      'Simkl: ${l10n.connectionFailed}',
    ]);
  });

  testWidgets('a Trakt login that returns false says so', (tester) async {
    final notifications = await pumpAccounts(
      tester,
      trakt: FakeTrakt(result: false),
    );

    await tester.tap(find.text('Trakt'));
    await tester.pumpAndSettle();

    expect(notifications.shown.map((t) => '${t.title}: ${t.message}'), <String>[
      'Trakt: ${l10n.connectionFailed}',
    ]);
  });

  testWidgets('a Trakt login that throws is caught and reported', (
    tester,
  ) async {
    final notifications = await pumpAccounts(
      tester,
      trakt: FakeTrakt(error: StateError('no client id')),
    );

    await tester.tap(find.text('Trakt'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(notifications.shown.map((t) => '${t.title}: ${t.message}'), <String>[
      'Trakt: ${l10n.connectionFailed}',
    ]);
  });

  testWidgets('dismissing the device-code dialog is not a failure', (
    tester,
  ) async {
    // The dialog's own `.then` flips `isCancelled`, so the login returns false
    // through the same branch as a timeout. A viewer who backed out has not
    // been told anything went wrong and must not be.
    final notifications = await pumpAccounts(
      tester,
      simkl: FakeSimkl(result: false, offerDeviceCode: true),
    );

    await tester.tap(find.text('Simkl'));
    await tester.pump();
    await tester.pump();
    expect(find.text('ABCD-1234'), findsOneWidget);

    Navigator.of(tester.element(find.text('ABCD-1234'))).pop();
    await tester.pumpAndSettle();

    expect(notifications.shown, isEmpty);
  });

  testWidgets('a Simkl login that succeeds still only says so once', (
    tester,
  ) async {
    final notifications = await pumpAccounts(
      tester,
      simkl: FakeSimkl(result: true),
    );

    await tester.tap(find.text('Simkl'));
    await tester.pumpAndSettle();

    expect(notifications.shown.single.type, ToastType.success);
  });
}

/// The real service records toasts behind a dismiss [Timer]; a widget test
/// that ends while one is pending fails on the pending-timer check. This one
/// just remembers.
class RecordingNotifications extends NotificationService {
  final List<ToastItem> shown = <ToastItem>[];

  @override
  void showToast({
    String? title,
    required String message,
    ToastType type = ToastType.info,
    IconData? icon,
    Widget? leading,
    Duration duration = const Duration(milliseconds: 3000),
    VoidCallback? onAction,
    String? actionLabel,
  }) {
    shown.add(
      ToastItem(
        id: '${shown.length}',
        title: title,
        message: message,
        type: type,
        icon: icon,
      ),
    );
  }
}

/// Every tracking service reads its token on construction, and the real read
/// falls through to a Hive box that was never opened.
class NoTokens extends SecureTokenStorage {
  NoTokens() : super(StorageService());

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// `generalSettingsProvider` builds itself out of nine repository getters, all
/// of which reach the same unopened box.
class QuietSettings extends SettingsRepository {
  QuietSettings() : super(StorageService());

  @override
  bool isWatchHistoryEnabled() => true;

  @override
  String getDefaultHomeScreen() => '/home';

  @override
  bool isGithubProxyEnabled() => false;

  @override
  bool isAlwaysOnTop() => false;

  @override
  String getTitlePosition() => 'below';

  @override
  String? getDownloadDirectory() => null;

  @override
  int getDownloadConcurrency() => 3;

  @override
  int getDownloadChunks() => 1;

  @override
  String getTmdbApiKey() => '';

  @override
  bool isAnimeSkipIntegrationEnabled() => false;

  @override
  bool isIntroDbIntegrationEnabled() => false;
}

/// The four tiles read their connected state from here; nothing in these tests
/// is about a connected account.
class SignedOutTrackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => const <String, bool>{
    'simkl': false,
    'trakt': false,
    'mal': false,
    'anilist': false,
  };
}

class FakeSimkl extends SimklService {
  FakeSimkl({this.result = false, this.error, this.offerDeviceCode = false})
    : super(Dio(), NoTokens());

  final bool result;
  final Object? error;
  final bool offerDeviceCode;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    if (error != null) throw error!;
    if (offerDeviceCode) {
      await onDeviceCodeGenerated?.call('https://simkl.com/pin', 'ABCD-1234');
      // Poll the way the real one does, so the caller's `isCancelled` has a
      // chance to flip while the dialog is up.
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled?.call() ?? false) return false;
      }
    }
    return result;
  }
}

class FakeTrakt extends TraktService {
  FakeTrakt({this.result = false, this.error}) : super(Dio(), NoTokens());

  final bool result;
  final Object? error;

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    if (error != null) throw error!;
    return result;
  }
}
