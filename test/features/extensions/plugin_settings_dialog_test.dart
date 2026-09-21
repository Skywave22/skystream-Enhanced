import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/extensions/screens/plugin_settings_dialog.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Plugin settings used to be a pushed page. On a television that meant losing
/// the extensions list - and the gear the focus was on - to read three
/// switches. It is a dialog now, which only helps if a remote can still walk
/// it: every tile one stop of the D-pad, and Save reachable from the last one.
class _QuietSettings implements SettingsRepository {
  @override
  String? getCustomBaseUrl(String packageName) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _QuietExtensions implements ExtensionRepository {
  @override
  String? getExtensionData(String key) => null;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => const [
    PluginSettingDefinition(
      key: 'a',
      title: 'First toggle',
      type: PluginSettingType.toggle,
      defaultValue: 'true',
    ),
    PluginSettingDefinition(
      key: 'b',
      title: 'Second toggle',
      type: PluginSettingType.toggle,
      defaultValue: 'false',
    ),
    PluginSettingDefinition(
      key: 'c',
      title: 'Third toggle',
      type: PluginSettingType.toggle,
      defaultValue: 'false',
    ),
  ];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) =>
      const [];
}

final _plugin = ExtensionPlugin(
  name: 'Acme',
  packageName: 'com.acme',
  repositoryId: 'repo',
  sourceUrl: 'https://example.test/acme.js',
  version: 1,
  manifest: const {},
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _flush(tester);
}

Size _viewSize = const Size(960, 540);

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = _viewSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionManagerProvider.overrideWith(_FakeManager.new),
        settingsRepositoryProvider.overrideWithValue(_QuietSettings()),
        extensionRepositoryProvider.overrideWithValue(_QuietExtensions()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.createDarkTheme(null),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => PluginSettingsDialog.open(ctx, _plugin),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _flush(tester);
}

void main() {
  testWidgets('the panel wraps its content instead of filling the screen', (
    tester,
  ) async {
    // A tall phone, where the mistake showed worst: an unbounded ListView
    // takes every pixel its parent offers, so the panel ran the full height
    // of the display with a page of dead space under seven switches.
    _viewSize = const Size(1212, 2704);
    addTearDown(() => _viewSize = const Size(960, 540));
    await _open(tester);

    // The painted surface, not the AlertDialog widget - that one always
    // reports the whole screen, which is what makes this easy to get wrong.
    final panel = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(
      panel.height,
      lessThan(_viewSize.height / 2),
      reason: 'the dialog must size to its content, not to the display',
    );
    expect(panel.width, 560);

    // One save, and it is the action bar's. The page this replaced also had a
    // full-width "Save settings" at the foot of the form; keeping both gave
    // the dialog two.
    expect(find.text('Save settings'), findsNothing);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);

    // The dialog's title and the group titles under it share one gutter.
    // AlertDialog sets 24 for its own title; SettingsGroup insets itself by
    // 16, so the content carries the remaining 8 rather than a full inset -
    // which is what left the two 8 dp apart.
    final title = tester.getRect(find.text('Acme Settings'));
    final group = tester.getRect(find.text('Extension settings'));
    expect(title.left - panel.left, 24);
    expect(group.left - panel.left, 24);

    // 16 between them: the content's 4 plus the group's own 12. It was 36 -
    // a full 16 content inset, a leading 8 spacer, and that 12.
    expect(group.top - title.bottom, 16);
  });

  testWidgets('opens as a dialog, not a route', (tester) async {
    await _open(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    // The page it replaced brought its own Scaffold+AppBar over the list.
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('First toggle'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('a remote walks every tile, one press each', (tester) async {
    await _open(tester);

    Rect tileRect(String title) => tester.getRect(
      find
          .ancestor(of: find.text(title), matching: find.byType(SettingsTile))
          .first,
    );

    final seen = <Rect>{};
    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      final r = FocusManager.instance.primaryFocus?.rect;
      if (r != null) seen.add(r);
    }
    for (final title in ['First toggle', 'Second toggle', 'Third toggle']) {
      expect(
        seen.any((r) => r.overlaps(tileRect(title))),
        isTrue,
        reason: 'DOWN never reached "$title"',
      );
    }
  });

  testWidgets('Save and Close are reachable from the form', (tester) async {
    await _open(tester);
    final save = tester.getRect(find.text('Save'));
    final close = tester.getRect(find.text('Close'));

    // DOWN off the last tile lands in the action row...
    var onActions = false;
    for (var i = 0; i < 12; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      final r = FocusManager.instance.primaryFocus?.rect;
      if (r != null && (r.overlaps(close) || r.overlaps(save))) {
        onActions = true;
        break;
      }
    }
    expect(
      onActions,
      isTrue,
      reason: 'DOWN off the form must reach the dialog buttons',
    );

    // ...and the buttons are a horizontal row, so RIGHT walks to Save. DOWN
    // will not: it is the wrong axis, and pressing it repeatedly just sits on
    // Close.
    var onSave = FocusManager.instance.primaryFocus!.rect.overlaps(save);
    for (var i = 0; i < 4 && !onSave; i++) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
      onSave = FocusManager.instance.primaryFocus!.rect.overlaps(save);
    }
    expect(onSave, isTrue, reason: 'RIGHT must reach Save from Close');
  });
}
