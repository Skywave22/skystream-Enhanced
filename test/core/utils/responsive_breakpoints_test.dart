import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/utils/layout_constants.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';

/// There were two answers to "is this a television" and they disagreed.
///
/// `DeviceProfile.isTv` reads `android.software.leanback` (or an Apple TV
/// `utsname`) - a hardware fact, and the authority. `ResponsiveContext.isTv`
/// inferred one from `Platform.isAndroid && aspectRatio > 1.0 &&
/// padding.top == 0`, and every call site OR-ed the two together, so the
/// inference could only ever promote a non-TV. It promoted an Android phone
/// held in landscape, and `player_settings_screen.dart` used the verdict to
/// hide the four gesture rows while the gestures kept firing.
///
/// The deleted clause cannot be pinned by pumping a widget: it asked `dart:io`
/// for the *host* operating system, so on a macOS or Linux test runner it was
/// false no matter what MediaQuery said. That is exactly why it survived. The
/// guard for it therefore has to read the source, and the widget tests below
/// pin what the getter is allowed to mean instead.
///
/// The second half of that collapse landed here too: `ResponsiveContext.isTv`
/// is gone entirely, along with the twelve call sites that spelled the
/// ten-foot layout with it. In its last form it forwarded to
/// [MediaQueryData.navigationMode], which nothing in this app declares, so it
/// was `false` on a real Android TV - every widescreen branch it guarded was
/// in fact being carried by the size breakpoint OR-ed beside it, and a
/// television clears all of those on its 960 dp width.
const String _source = 'lib/core/utils/responsive_breakpoints.dart';

/// The file with comments and doc comments stripped, so that a sentence
/// *describing* the deleted heuristic does not read as the heuristic.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

Future<BuildContext> _pump(
  WidgetTester tester, {
  required Size size,
  NavigationMode navigationMode = NavigationMode.traditional,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        padding: padding,
        navigationMode: navigationMode,
      ),
      child: Builder(
        builder: (BuildContext context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('the geometric helper no longer guesses at a device class', () {
    test('it does not reach for dart:io at all', () {
      expect(
        _code(_source),
        isNot(contains("import 'dart:io'")),
        reason:
            'the host operating system is not this device: dart:io reported '
            'the machine running the test, which is how the landscape-phone '
            'bug stayed invisible to the suite',
      );
    });

    test(
      'no window inset or aspect ratio decides what kind of device this is',
      () {
        final String code = _code(_source);
        for (final Pattern banned in <Pattern>[
          RegExp(r'padding\.top'),
          RegExp(r'viewPadding'),
          RegExp(r'aspectRatio'),
          RegExp(r'\bPlatform\.'),
        ]) {
          expect(
            code,
            isNot(contains(banned)),
            reason:
                'a device class inferred from insets, aspect ratio or the host '
                'OS is the bug this file just lost - size decisions use the '
                'breakpoints above, device decisions use DeviceProfile',
          );
        }
      },
    );

    test('nothing anywhere in lib infers a device from a zero top inset', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.contains('/l10n/')) continue;
        if (RegExp(r'padding\.top\s*==\s*0').hasMatch(_code(f.path))) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'the immersive player leaves the top inset at zero, so this '
            'reads as "television" on a phone mid-session',
      );
    });

    test('the extension does not answer "is this a television" at all', () {
      expect(
        _code(_source),
        isNot(contains('isTv')),
        reason:
            'the `isTv` alias is gone. It forwarded to the navigation mode, '
            'which nothing in this app ever declares, so it was false on a '
            'real television and true nowhere - a constant wearing the name '
            'of a device class. DeviceProfile.isTv is the authority',
      );
    });

    test('nothing in lib asks a BuildContext whether it is a television', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.contains('/l10n/')) continue;
        if (RegExp(r'\bcontext\.isTv\b').hasMatch(_code(f.path))) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a device class is a hardware fact (DeviceProfile.isTv) and a '
            'layout is a size (the breakpoints above); a BuildContext knows '
            'neither, and the getter that pretended otherwise is deleted',
      );
    });
  });

  group('what the helper does answer', () {
    testWidgets('directional navigation, and only when the host declares it', (
      WidgetTester tester,
    ) async {
      BuildContext context = await _pump(
        tester,
        size: const Size(960, 540),
        navigationMode: NavigationMode.directional,
      );
      expect(context.isDirectionalNavigation, isTrue);

      // A 1080p television's own metrics, minus the declaration. Landscape,
      // wide, no top inset: every ingredient of the deleted heuristic - and
      // the state a real Android TV is actually in, because no host in this
      // app ever sets NavigationMode.directional.
      context = await _pump(tester, size: const Size(960, 540));
      expect(context.isDirectionalNavigation, isFalse);
    });

    testWidgets('a phone in landscape with no top inset is not special', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await _pump(
        tester,
        size: const Size(800, 360),
      );
      expect(context.isDirectionalNavigation, isFalse);
      expect(context.isTabletOrLarger, isTrue, reason: '800 dp is wide');
      expect(context.isDesktop, isFalse, reason: 'but not 900 dp wide');
    });

    testWidgets('a 960x540 dp television clears every widescreen threshold '
        'the app has, with no device clause anywhere', (
      WidgetTester tester,
    ) async {
      // Why the eleven ten-foot call sites could drop their TV clause
      // outright rather than re-route it. Each one guards a wide layout
      // behind a size, and a television is 960 dp wide - past all of them.
      final BuildContext context = await _pump(
        tester,
        size: const Size(960, 540),
      );
      expect(
        context.isTabletOrLarger,
        isTrue,
        reason:
            'library, search, '
            'stream, both search delegates',
      );
      expect(context.isDesktop, isTrue, reason: 'the recommendations rail');
      expect(
        960 > LayoutConstants.exploreCarouselDesktopBreakpoint,
        isTrue,
        reason: 'the explore hero carousel',
      );
      expect(960 >= 720, isTrue, reason: 'the toast corner');

      // And the profile flag that used to be OR-ed beside them is subsumed
      // too: isLargeScreen is where home and explore read it.
      expect(const DeviceProfile(isTv: true).isLargeScreen, isTrue);
    });

    testWidgets('size branches stay keyed off size, whatever drives them', (
      WidgetTester tester,
    ) async {
      // A drawer-versus-sheet or sidebar-versus-bottom-nav decision is
      // geometric and stays that way: a D-pad does not change how wide the
      // window is.
      for (final NavigationMode mode in NavigationMode.values) {
        BuildContext context = await _pump(
          tester,
          size: const Size(599, 900),
          navigationMode: mode,
        );
        expect(context.deviceType, DeviceScreenType.mobile, reason: '$mode');
        expect(context.isTabletOrLarger, isFalse, reason: '$mode');

        context = await _pump(
          tester,
          size: const Size(600, 900),
          navigationMode: mode,
        );
        expect(context.deviceType, DeviceScreenType.tablet, reason: '$mode');
        expect(context.isTabletOrLarger, isTrue, reason: '$mode');

        context = await _pump(
          tester,
          size: const Size(900, 900),
          navigationMode: mode,
        );
        expect(context.deviceType, DeviceScreenType.desktop, reason: '$mode');
        expect(context.isDesktop, isTrue, reason: '$mode');
      }
    });
  });
}
