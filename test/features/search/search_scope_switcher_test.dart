import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/explore/presentation/widgets/hover_border_gradient.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/widgets/search_header_bar.dart';

void main() {
  Widget host(Widget child, {required MediaQueryData media}) {
    return MaterialApp(
      home: MediaQuery(
        data: media,
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('SearchScopeSwitcher under text scaling', () {
    /// The pill is a hard-coded 310 x 38 box, so each half gets ~150 dp for a
    /// label. The labels used to be bare `Text`s inside a `Row`, which asks
    /// for its intrinsic width and overflows the moment the user turns text
    /// size up - the accessibility setting that is supposed to make the app
    /// more readable was the one that broke the control.
    for (final scale in [1.0, 1.3, 1.6, 2.0]) {
      testWidgets('lays out with no overflow at text scale $scale', (
        tester,
      ) async {
        final movies = FocusNode();
        final live = FocusNode();
        addTearDown(movies.dispose);
        addTearDown(live.dispose);

        await tester.pumpWidget(
          host(
            SearchScopeSwitcher(
              value: SearchFilter.content,
              moviesShowsFocusNode: movies,
              liveTvFocusNode: live,
              onChanged: (_) {},
            ),
            media: MediaQueryData(textScaler: TextScaler.linear(scale)),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: 'the scope pill overflowed at text scale $scale',
        );
        // Ellipsised is fine; gone is not.
        expect(find.text('Movies & Shows'), findsOneWidget);
        expect(find.text('Live TV'), findsOneWidget);
      });
    }
  });

  /// Four controllers in the app called `repeat()` and never stopped. The
  /// framework shortens *implicit* animations to 1% of their duration when
  /// 'Remove animations' is on, but it cannot do anything about a loop that
  /// drives itself, so these four were the only motion in the app that
  /// ignored the setting outright.
  group('OS remove-animations setting', () {
    testWidgets('the live-TV equalizer stops looping when motion is off', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const WaveformEqualizer(isActive: true),
          media: const MediaQueryData(),
        ),
      );
      await tester.pump();
      expect(
        tester.hasRunningAnimations,
        isTrue,
        reason: 'with motion allowed the bars should be moving',
      );

      await tester.pumpWidget(
        host(
          const WaveformEqualizer(isActive: true),
          media: const MediaQueryData(disableAnimations: true),
        ),
      );
      await tester.pump();
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason:
            'the OS asked for no animation; a repeat() loop has to answer for '
            'itself because the framework cannot shorten it',
      );
    });

    testWidgets('the hover border stops sweeping when motion is off', (
      tester,
    ) async {
      Widget subject() => HoverBorderGradient(
        onTap: () {},
        child: const SizedBox(width: 40, height: 20),
      );

      await tester.pumpWidget(
        host(subject(), media: const MediaQueryData()),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pumpWidget(
        host(subject(), media: const MediaQueryData(disableAnimations: true)),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
