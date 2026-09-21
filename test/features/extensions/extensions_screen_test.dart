import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/focus/app_focus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/features/extensions/screens/extensions_screen.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class MockExtensionsController extends ExtensionsController {
  final ExtensionsState initialState;
  MockExtensionsController(this.initialState);

  @override
  ExtensionsState build() => initialState;

  @override
  Future<void> ensureInitialized() async {}
}

class MockExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => [];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) => [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

void main() {
  testWidgets(
    'ExtensionsScreen displays 2 tabs and guided empty state when no plugins installed',
    (WidgetTester tester) async {
      final emptyState = ExtensionsSuccess(
        repositories: [
          ExtensionRepository(
            name: 'Test Repo',
            url: 'https://example.com/repo.json',
            pluginLists: [],
          ),
        ],
        installedPlugins: [],
        availablePlugins: {},
        availableUpdates: {},
        installingPlugins: {},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionsControllerProvider.overrideWith(
              () => MockExtensionsController(emptyState),
            ),
            extensionManagerProvider.overrideWith(() => MockExtensionManager()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ExtensionsScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // TabBar should be present with 2 tabs by default
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);
      expect(find.text('Repositories'), findsOneWidget);

      // Installed tab should present guided empty state
      expect(find.text('No Extensions Installed'), findsOneWidget);
      expect(find.text('Browse Repositories'), findsOneWidget);

      // Tapping 'Browse Repositories' button switches to Repositories tab
      await tester.tap(find.text('Browse Repositories'));
      await tester.pumpAndSettle();

      // Repositories content should now be visible
      expect(find.text('Test Repo'), findsOneWidget);
    },
  );

  testWidgets(
    'ExtensionsScreen displays Installed plugin list when extensions installed',
    (WidgetTester tester) async {
      final installedState = ExtensionsSuccess(
        repositories: [
          ExtensionRepository(
            name: 'Test Repo',
            url: 'https://example.com/repo.json',
            pluginLists: [],
          ),
        ],
        installedPlugins: [
          ExtensionPlugin(
            name: 'Installed Plugin',
            version: 1,
            packageName: 'com.example.plugin',
            repositoryId: 'test_repo',
            sourceUrl: 'https://example.com/plugin.js',
          ),
        ],
        availablePlugins: {},
        availableUpdates: {},
        installingPlugins: {},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionsControllerProvider.overrideWith(
              () => MockExtensionsController(installedState),
            ),
            extensionManagerProvider.overrideWith(() => MockExtensionManager()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ExtensionsScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // TabBar should be present with 2 tabs
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Installed'), findsOneWidget);
      expect(find.text('Repositories'), findsOneWidget);

      // Installed plugin list should display the installed plugin exactly once
      expect(find.text('Installed Plugin'), findsOneWidget);
    },
  );

  group('plugin row focus affordance', _focusAffordanceTests);
}

// ---------------------------------------------------------------------------
// Focus affordance: the ROW the user is on, not the card that contains it.
// ---------------------------------------------------------------------------

/// The two decoration layers a focused plugin row is supposed to draw around
/// itself: the accent glow (a BoxShadow, painted behind) and the accent ring
/// plus tint (a border and a fill, painted behind the row's text).
///
/// Both are looked up by walking the Container ancestors of the row's own
/// title, so the assertions are about the row, never about the section card —
/// the card is an AnimatedContainer, a different type, and it is deliberately
/// not matched here.
({BoxDecoration? glow, BoxDecoration? ring}) _rowLayers(
  WidgetTester tester,
  Finder rowTitle,
) {
  BoxDecoration? ring;
  BoxDecoration? glow;
  for (final container in tester.widgetList<Container>(
    find.ancestor(of: rowTitle, matching: find.byType(Container)),
  )) {
    final decoration = container.decoration;
    if (decoration is! BoxDecoration) continue;
    // Matched on the recipe's own signature, not on position in the tree: an
    // AnimatedContainer builds a plain Container, so the section card itself
    // turns up in this walk and must not be mistaken for the row. Only the
    // row strokes its border outside the box, and the two shadows differ in
    // spread (the card's is not zero).
    final border = decoration.border;
    if (border is Border &&
        border.top.strokeAlign == BorderSide.strokeAlignOutside) {
      ring ??= decoration;
    }
    final shadow = decoration.boxShadow;
    if (shadow != null &&
        shadow.length == 1 &&
        shadow.single.spreadRadius == 0) {
      glow ??= decoration;
    }
  }
  return (glow: glow, ring: ring);
}

/// The section/repository card that encloses [inner].
BoxDecoration _cardDecoration(
  WidgetTester tester,
  Finder inner,
  Color surface,
) {
  final cards = tester
      .widgetList<AnimatedContainer>(
        find.ancestor(of: inner, matching: find.byType(AnimatedContainer)),
      )
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color == surface)
      .toList();
  expect(
    cards,
    hasLength(1),
    reason: 'expected exactly one _FocusableCard above $inner',
  );
  return cards.single;
}

/// Moves real focus onto the control [finder] points at, the way a D-pad
/// would, by asking for the nearest enclosing focus node.
Future<void> _focusOn(WidgetTester tester, Finder finder) async {
  final node = Focus.maybeOf(
    tester.element(finder),
    createDependency: false,
  );
  expect(node, isNotNull, reason: 'nothing focusable at $finder');
  node!.requestFocus();
  // Two frames: FocusManager applies the change in a microtask, so the first
  // pump is what delivers onFocusChange and the second is what paints it.
  await tester.pump();
  await tester.pump();
}

ExtensionsSuccess _twoInstalled() => ExtensionsSuccess(
  repositories: const [],
  installedPlugins: [
    ExtensionPlugin(
      name: 'Plugin A',
      version: 1,
      packageName: 'com.example.a',
      repositoryId: 'test_repo',
      sourceUrl: 'https://example.com/a.js',
    ),
    ExtensionPlugin(
      name: 'Plugin B',
      version: 1,
      packageName: 'com.example.b',
      repositoryId: 'test_repo',
      sourceUrl: 'https://example.com/b.js',
    ),
  ],
  availablePlugins: const {},
  availableUpdates: const {},
  installingPlugins: const {},
);

Widget _app(ExtensionsState state) => ProviderScope(
  overrides: [
    extensionsControllerProvider.overrideWith(
      () => MockExtensionsController(state),
    ),
    extensionManagerProvider.overrideWith(() => MockExtensionManager()),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ExtensionsScreen(),
  ),
);

void _focusAffordanceTests() {
  // The affordance is input-aware: it is drawn for a remote or a keyboard and
  // not for a finger, so a test that means to see it has to say which input
  // it is standing in for. Without this the default on Android resolves to
  // `touch` and every assertion below would be measuring nothing.
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets(
    'focusing one plugin row rings that row and leaves its neighbour plain',
    (WidgetTester tester) async {
      await tester.pumpWidget(_app(_twoInstalled()));
      await tester.pumpAndSettle();

      final scheme = Theme.of(
        tester.element(find.text('Plugin A')),
      ).colorScheme;

      // Nothing focused yet: neither row draws anything.
      expect(_rowLayers(tester, find.text('Plugin A')).ring, isNull);
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNull);

      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.delete)),
      );

      final focused = _rowLayers(tester, find.text('Plugin B'));

      // Ring: neutral, the shared width, stroked outside so the row keeps its
      // full content width.
      final ring = focused.ring;
      expect(ring, isNotNull, reason: 'focused row drew no ring');
      final side = (ring!.border! as Border).top;
      expect(
        side.color,
        scheme.onSurface,
        reason: 'a focus ring is neutral; the accent belongs to selection',
      );
      expect(side.width, CardFocusAffordance.ringWidth);
      expect(side.strokeAlign, BorderSide.strokeAlignOutside);

      // Nothing else on that layer: the accent wash that used to sit here
      // recoloured the label the ring is pointing at.
      expect(ring.color, isNull);

      // The lift, on its own layer behind the row, and a plain shadow rather
      // than an accent glow.
      final glow = focused.glow;
      expect(glow, isNotNull, reason: 'focused row drew no lift');
      expect(glow!.boxShadow!.single.color, AppFocus.shadows(focused: true)!.single.color);

      // The neighbour is untouched — this is the whole complaint: from three
      // metres you must be able to tell the fifth row from the fourth.
      expect(_rowLayers(tester, find.text('Plugin A')).ring, isNull);
      expect(_rowLayers(tester, find.text('Plugin A')).glow, isNull);
    },
  );

  testWidgets(
    'the section card stays quiet while a row inside it holds the focus',
    (WidgetTester tester) async {
      await tester.pumpWidget(_app(_twoInstalled()));
      await tester.pumpAndSettle();

      final surface = Theme.of(
        tester.element(find.text('Plugin A')),
      ).colorScheme.surface;

      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.delete)),
      );

      final card = _cardDecoration(tester, find.text('Plugin B'), surface);
      expect(
        card.boxShadow,
        isNull,
        reason: 'the card around all the plugins glowed for one row of them',
      );
      expect(
        (card.border! as Border).top.width,
        1.0,
        reason: 'the card around all the plugins thickened for one row of them',
      );
    },
  );

  testWidgets(
    'a repository card still lights for its own header, then hands over',
    (WidgetTester tester) async {
      final state = ExtensionsSuccess(
        repositories: [
          ExtensionRepository(
            name: 'Test Repo',
            url: 'https://example.com/repo.json',
            pluginLists: const [],
          ),
        ],
        installedPlugins: const [],
        availablePlugins: {
          'https://example.com/repo.json': [
            ExtensionPlugin(
              name: 'Plugin B',
              version: 1,
              packageName: 'com.example.b',
              repositoryId: 'test_repo',
              sourceUrl: 'https://example.com/b.js',
            ),
          ],
        },
        availableUpdates: const {},
        installingPlugins: const {},
      );

      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repositories'));
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.text('Test Repo')));
      final surface = theme.colorScheme.surface;
      final primary = theme.colorScheme.primary;

      // Expand the repository so its plugin rows exist.
      await tester.tap(find.text('Test Repo'));
      await tester.pumpAndSettle();

      // The header belongs to the card, so the card is what lights up.
      await _focusOn(tester, find.text('Test Repo'));
      var card = _cardDecoration(tester, find.text('Test Repo'), surface);
      expect((card.border! as Border).top.color, primary);
      expect((card.border! as Border).top.width, 2.0);
      expect(card.boxShadow, isNotNull);

      // Walk down onto a row and the card must hand the affordance over.
      final rowB = find.ancestor(
        of: find.text('Plugin B'),
        matching: find.byType(ListTile),
      );
      await _focusOn(
        tester,
        find.descendant(of: rowB, matching: find.byIcon(Icons.download)),
      );

      card = _cardDecoration(tester, find.text('Plugin B'), surface);
      expect(
        card.boxShadow,
        isNull,
        reason: 'the repository card kept glowing for a row inside it',
      );
      expect((card.border! as Border).top.width, 1.0);
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNotNull);

      // And back up to the header: the card takes it back.
      await _focusOn(tester, find.text('Test Repo'));
      card = _cardDecoration(tester, find.text('Test Repo'), surface);
      expect(
        card.boxShadow,
        isNotNull,
        reason: 'the card never recovered after a row had the focus',
      );
      expect(_rowLayers(tester, find.text('Plugin B')).ring, isNull);
    },
  );
}
