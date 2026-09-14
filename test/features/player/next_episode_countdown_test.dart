import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/next_episode_countdown.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/thumbnail_error_placeholder.dart';

/// Hosts the card the way the player does: an overlay layer in a [Stack] over
/// a (here, absent) video surface. [locale] and [textScale] are the two axes
/// its geometry has to hold across.
Widget _host(Widget child, {String locale = 'en', double textScale = 1.0}) {
  return MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(fit: StackFit.expand, children: [child]),
        ),
      ),
    ),
  );
}

/// Unmounts the tree so a still-running countdown ticker does not outlive the
/// test.
Future<void> _teardown(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

String? get _focusLabel => FocusManager.instance.primaryFocus?.debugLabel;

/// A 1080p television: 1920x1080 physical at devicePixelRatio 2 is 960x540
/// logical dp. [_sizeView] sets devicePixelRatio to 1, so the numbers below
/// are logical dp directly.
const Size _tv = Size(960, 540);

/// A phone held sideways, which is the only orientation the player runs in on
/// touch. Its shortest side is under 600 dp, so this is the compact branch.
const Size _phone = Size(844, 390);

/// A desktop window / tablet: shortest side at or over 600 dp, not a TV.
const Size _wide = Size(1280, 800);

/// The smallest viewport the stacked branch is reachable on: a shortest side
/// of exactly 600 dp.
const Size _smallTablet = Size(1000, 600);

/// The band the card holds clear of the scrubber wherever the bottom bar is
/// one flat control row - which is everywhere but a handset held upright.
///
/// `HotstarPlayerStyle.bottomChromeHeight + 12`. Measured through the real
/// [PlayerBottomBar]: 123 dp on touch, tablet and desktop and 137 on TV, so
/// 144 clears the taller of them by 7. Below
/// [PlayerBottomBar.narrowTouchWidth] of inner width the bar puts its action
/// strip on a run of its own and stands 171, and the card adds the same 48 dp
/// back.
const double _kClearance = 144;

/// Catalogue text longer than the card, which its height budget has to
/// survive.
const String _longTitle =
    'The One Where Everybody Finds Out That The Title Of This Episode Runs On';
const String _longSynopsis =
    'Buffy comes home to find her mother on the couch, and the hour that '
    'follows is told almost entirely without music, in long unbroken takes '
    'that refuse the audience any relief at all, right through to the end.';

/// The locales the card ships in. The ARB strings are owned elsewhere, so the
/// card cannot shorten a label to make it fit.
const List<String> _shippedLocales = ['en', 'hi', 'kn'];

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The card's own box - the [SizedBox] under the focus scope, not the
/// screen-filling [Align] that positions it.
Rect _cardRect(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(NextEpisodeCountdown),
        matching: find.byType(FocusTraversalGroup),
      )
      .first,
);

Rect _buttonRect(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(of: find.text(label), matching: find.byType(AnimatedContainer))
      .first,
);

/// What a label needs against what its slab hands it: `needs` is the
/// paragraph's `maxIntrinsicWidth` and `gets` is the box the layout gave it,
/// so the label is ellipsised exactly when `needs > gets`.
({double needs, double gets}) _label(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  return (
    needs: paragraph.getMaxIntrinsicWidth(double.infinity),
    gets: paragraph.size.width,
  );
}

Future<AppLocalizations> _l10n(String locale) =>
    AppLocalizations.delegate.load(Locale(locale));

void main() {
  group('NextEpisodeCountdown', () {
    testWidgets('advances on its own when the countdown runs out', (
      tester,
    ) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );

      expect(find.text('15'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('10'), findsOneWidget);
      expect(played, 0);

      await tester.pump(const Duration(seconds: 10));
      expect(find.text('0'), findsOneWidget);
      // An AnimationController's simulation is done only past its duration,
      // so the advance lands on the frame after zero rather than on it.
      await tester.pump(const Duration(milliseconds: 16));
      expect(played, 1);
      expect(cancelled, 0);

      // The clock is stopped, not merely past its end: no second advance.
      await tester.pump(const Duration(seconds: 30));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('holds while playback is paused and resumes with it', (
      tester,
    ) async {
      var played = 0;

      Widget build({required bool paused}) => _host(
        NextEpisodeCountdown(
          title: 'The Body',
          countdown: const Duration(seconds: 15),
          paused: paused,
          onPlayNext: () => played++,
          onCancel: () {},
        ),
      );

      await tester.pumpWidget(build(paused: true));
      await tester.pump(const Duration(seconds: 30));
      expect(played, 0, reason: 'a paused episode must not auto-advance');
      expect(find.text('15'), findsOneWidget);

      await tester.pumpWidget(build(paused: false));
      await tester.pump(const Duration(seconds: 16));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('Play now advances immediately and only once', (tester) async {
      var played = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () {},
          ),
        ),
      );

      await tester.tap(find.text('Play Now'));
      expect(played, 1);

      // Pressing it again, or letting the original deadline pass, must not
      // advance a second time and skip an episode.
      await tester.tap(find.text('Play Now'));
      await tester.pump(const Duration(seconds: 30));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('Cancel stops the countdown for good', (tester) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );

      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);
      expect(played, 0);

      await tester.pump(const Duration(minutes: 1));
      expect(played, 0, reason: 'cancel must not leave a live deadline');
      expect(cancelled, 1);

      await _teardown(tester);
    });

    testWidgets('D-pad reaches both controls and activates them', (
      tester,
    ) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            isTv: true,
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      expect(
        _focusLabel,
        kPlayNextFocusLabel,
        reason: 'the remote should land on the action the timeout will take',
      );

      // Down, not Right: the two actions are stacked so each can hold a label
      // the row could not.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusLabel, kCancelFocusLabel);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusLabel, kPlayNextFocusLabel);

      // Select on the focused control, not a tap.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(cancelled, 1);
      expect(played, 0);

      await _teardown(tester);
    });

    testWidgets('Back while focused inside the card cancels', (tester) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            isTv: true,
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 1);
      expect(played, 0);

      await _teardown(tester);
    });

    testWidgets('renders the metadata it is given and skips what it is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            season: 2,
            episode: 5,
            rating: 8.14,
            runtime: const Duration(minutes: 42),
            description: 'Buffy comes home to find her mother on the couch.',
            countdown: const Duration(seconds: 15),
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('The Body'), findsOneWidget);
      expect(find.textContaining('S2 E5'), findsOneWidget);
      expect(find.textContaining('42m'), findsOneWidget);
      expect(find.textContaining('8.1'), findsOneWidget);
      expect(find.textContaining('on the couch'), findsOneWidget);

      await _teardown(tester);
    });

    testWidgets('omits the whole metadata line when nothing is known', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            // A sub-minute runtime is metadata noise, not a runtime.
            runtime: const Duration(seconds: 12),
            rating: 0,
            countdown: const Duration(seconds: 15),
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.textContaining('·'), findsNothing);
      expect(find.textContaining('★'), findsNothing);

      await _teardown(tester);
    });
  });

  group('NextEpisodeCountdown composition', () {
    /// On 960x540 the card is held between the top bar's band (0..92, measured
    /// through the real screen in tv_overlay_focus_test) and the scrubber
    /// (132 + 12 dp of clearance, so its last pixel is 396), which is 304 dp:
    /// 226 for the panel's text and the 78 that are left for the still.
    testWidgets('on a 960x540 television the still leads at full width', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            rating: 8.14,
            runtime: const Duration(minutes: 42),
            description: _longSynopsis,
            isTv: true,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      final card = _cardRect(tester);
      expect(
        card,
        const Rect.fromLTRB(612, 92, 912, 396),
        reason:
            'bottom on 540 - (132 chrome + 12), top on the 92 dp the top bar '
            'occupies, right on the 48 dp overscan inset, and 300 dp wide - '
            'the width the longest action label needs, not a height solve',
      );
      // There is no chrome in this host and the card still tops out on 92:
      // the clearance over the running title is unconditional, not a reaction
      // to the bars being visible.
      expect(find.byType(NextEpisodeCountdown), findsOneWidget);
      expect(
        card.bottom,
        540 - (132 + 12),
        reason: 'the card still clears the bottom bar it is anchored above',
      );

      // The still: full card width, flush to three edges, and on top of the
      // text rather than beside it.
      final still = tester.getRect(find.byType(CachedNetworkImage));
      expect(
        still.width,
        card.width,
        reason: 'full-bleed, not a thumbnail in a row',
      );
      expect(
        still.height,
        78,
        reason:
            'the still is the column\'s one Flexible child, so it takes what '
            'the panel leaves rather than forcing the card past its box: 304 '
            '- 226 of panel. Below its 16:9 ideal of 168.75, so BoxFit.cover '
            'crops it',
      );
      expect(
        still.height,
        lessThan(card.width * 9 / 16),
        reason: 'cropped, which is the whole point of the flexible slot',
      );
      expect(still.topLeft, card.topLeft, reason: 'flush to the card edge');
      expect(still.right, card.right);
      expect(
        still.bottom,
        lessThanOrEqualTo(tester.getRect(find.textContaining('S1 E2')).top),
        reason: 'the pill, the title and the synopsis sit under the still',
      );
      expect(
        tester.getRect(find.textContaining('S1 E2')).bottom,
        lessThanOrEqualTo(tester.getRect(find.text(_longTitle)).top),
      );
      expect(
        tester.getRect(find.text(_longTitle)).bottom,
        lessThanOrEqualTo(tester.getRect(find.text(_longSynopsis)).top),
      );

      // The countdown ring rides the UP NEXT badge over the still's corner.
      final ring = tester.getRect(find.text('15'));
      expect(still.contains(ring.center), isTrue);
      expect(
        tester.getRect(find.text('UP NEXT')).right,
        lessThan(ring.left),
        reason: 'the label and the ring are one badge',
      );

      // A still that is offered and fails to load still fills its box from
      // the device rather than from the network.
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(
        image.errorWidget!(
          tester.element(find.byType(CachedNetworkImage)),
          'https://example.com/still.jpg',
          Exception('404'),
        ),
        isA<ThumbnailErrorPlaceholder>(),
      );

      await _teardown(tester);
    });

    testWidgets('the two actions are stacked and each takes the whole card', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            posterUrl: 'https://example.com/still.jpg',
            isTv: true,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      final card = _cardRect(tester);
      final play = _buttonRect(tester, 'Play Now');
      final cancel = _buttonRect(tester, 'Cancel');

      expect(
        play.width,
        cancel.width,
        reason: 'two actions of equal prominence, not a primary and a scrap',
      );
      expect(
        play.width,
        card.width - 28,
        reason:
            'each slab spans the card between its 14 dp side paddings - 272 '
            'dp, against the 117 the side-by-side row left them',
      );
      expect(cancel.left, play.left);
      expect(
        cancel.top,
        play.bottom + 8,
        reason: 'Cancel is under Play now, one 8 dp gap down',
      );
      expect(play.height, 44);
      expect(cancel.height, 44);
      expect(play.left, card.left + 14);
      expect(cancel.right, card.right - 14);

      await _teardown(tester);
    });

    /// Side by side, each slab left 97 dp of label against measured
    /// intrinsics of 130.0 (English), 146.3 (Hindi) and 227.5 (Kannada), so
    /// all three ellipsised the primary action of a destructive auto-advance.
    for (final locale in _shippedLocales) {
      testWidgets('no action label is clipped on a television in $locale', (
        tester,
      ) async {
        _sizeView(tester, _tv);
        final l10n = await _l10n(locale);
        await tester.pumpWidget(
          _host(
            NextEpisodeCountdown(
              title: _longTitle,
              posterUrl: 'https://example.com/still.jpg',
              season: 1,
              episode: 2,
              rating: 8.14,
              runtime: const Duration(minutes: 42),
              description: _longSynopsis,
              isTv: true,
              onPlayNext: () {},
              onCancel: () {},
            ),
            locale: locale,
          ),
        );

        for (final label in [l10n.playNow, l10n.cancel]) {
          final measured = _label(tester, label);
          expect(
            measured.needs,
            lessThanOrEqualTo(measured.gets),
            reason:
                '"$label" wants ${measured.needs} dp and the slab hands it '
                '${measured.gets}; anything over ellipsises the action',
          );
        }

        await _teardown(tester);
      });

      testWidgets('nor on the compact phone card in $locale', (tester) async {
        _sizeView(tester, _phone);
        final l10n = await _l10n(locale);
        await tester.pumpWidget(
          _host(
            NextEpisodeCountdown(
              title: _longTitle,
              posterUrl: 'https://example.com/still.jpg',
              season: 1,
              episode: 2,
              onPlayNext: () {},
              onCancel: () {},
            ),
            locale: locale,
          ),
        );

        for (final label in [l10n.playNow, l10n.cancel]) {
          final measured = _label(tester, label);
          expect(measured.needs, lessThanOrEqualTo(measured.gets));
        }

        await _teardown(tester);
      });
    }

    testWidgets('a phone in landscape keeps the row, with stacked actions', (
      tester,
    ) async {
      _sizeView(tester, _phone);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            isTv: false,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      final card = _cardRect(tester);
      final still = tester.getRect(find.byType(CachedNetworkImage));
      expect(
        still.width,
        96,
        reason:
            'the stacked shape does not fit here: forced down that branch at '
            '300 dp the card lays out at 356 dp against the 318 dp a 390 dp '
            'phone leaves above the chrome, a 38 dp RenderFlex overflow',
      );
      expect(
        still.right,
        lessThan(tester.getRect(find.text(_longTitle)).left),
        reason: 'thumbnail beside the text, which is what compact means',
      );
      expect(
        card.height,
        lessThanOrEqualTo(390 - _kClearance),
        reason: 'the card fits in the height a landscape phone has left',
      );
      expect(
        card.bottom,
        390 - _kClearance,
        reason:
            'the same clearance the ten-foot card gets, because the bar it is '
            'held above is the same bar: 123 dp on touch, 137 on TV',
      );

      // The actions are stacked here too: a 300 dp card split in half leaves
      // 113 dp for a Kannada label that wants 185.5.
      final play = _buttonRect(tester, 'Play Now');
      final cancel = _buttonRect(tester, 'Cancel');
      expect(
        play.width,
        card.width - 24,
        reason: 'full width inside the compact 12 dp padding, not half of it',
      );
      expect(cancel.width, play.width);
      expect(cancel.top, play.bottom + 8);
      expect(
        card.height,
        218,
        reason:
            'measured: badge 30 + 8 + row 54 + 10 + 44 + 8 + 44 + 24 of '
            'padding, and 218 clears the 226 the phone leaves between the '
            'top bar and the chrome',
      );

      await _teardown(tester);
    });

    testWidgets('a desktop card is the stacked shape, widened', (tester) async {
      _sizeView(tester, _wide);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            description: _longSynopsis,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      final card = _cardRect(tester);
      expect(card.width, 400, reason: 'widened from 380 toward a third');
      final still = tester.getRect(find.byType(CachedNetworkImage));
      expect(still.width, card.width);
      expect(still.topLeft, card.topLeft);
      expect(
        still.height,
        card.width * 9 / 16,
        reason:
            'a 1280x800 window has the height for the full 16:9 frame, so the '
            'flexible slot is capped by the aspect ratio rather than by space',
      );

      await _teardown(tester);
    });

    testWidgets('no still leaves no hole, and the badge moves into the panel', (
      tester,
    ) async {
      _sizeView(tester, _tv);

      Widget build(String? posterUrl) => _host(
        NextEpisodeCountdown(
          title: _longTitle,
          posterUrl: posterUrl,
          season: 1,
          episode: 2,
          description: _longSynopsis,
          isTv: true,
          onPlayNext: () {},
          onCancel: () {},
        ),
      );

      await tester.pumpWidget(build('https://example.com/still.jpg'));
      final withStill = _cardRect(tester);

      await tester.pumpWidget(build(null));
      final without = _cardRect(tester);

      expect(
        find.byType(CachedNetworkImage),
        findsNothing,
        reason: 'there is no still to fetch',
      );
      expect(
        find.byType(ThumbnailErrorPlaceholder),
        findsNothing,
        reason:
            'a 300x169 dp box with a broken-image glyph in it is a hole, not '
            'a placeholder; the card gives the height back instead',
      );
      expect(
        withStill.height - without.height,
        78 - 40,
        reason:
            'the 78 dp still is gone and the 40 dp badge row it used to carry '
            'has arrived in the panel - nothing else moved',
      );
      expect(
        tester.getRect(find.text('UP NEXT')).top,
        greaterThanOrEqualTo(without.top),
        reason: 'the badge is inside the panel now that it has no still',
      );
      expect(find.text('15'), findsOneWidget, reason: 'the ring survives');

      await _teardown(tester);
    });

    testWidgets('long title and synopsis are capped, not overflowed', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            description: _longSynopsis,
            isTv: true,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      // One line of title and two of synopsis, at the line heights the panel's
      // 226 dp assumes: 18/1.2 and 14/1.3.
      expect(
        tester.getRect(find.text(_longTitle)).height,
        closeTo(18 * 1.2, 1),
        reason: 'the ten-foot title is capped at one line, as the reference is',
      );
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, 1);
      expect(
        tester.getRect(find.text(_longSynopsis)).height,
        closeTo(2 * 14 * 1.3, 1),
        reason: 'the synopsis is capped at two lines',
      );
      expect(tester.widget<Text>(find.text(_longSynopsis)).maxLines, 2);
      for (final text in [_longTitle, _longSynopsis]) {
        expect(
          tester.widget<Text>(find.text(text)).overflow,
          TextOverflow.ellipsis,
        );
      }
      expect(
        _cardRect(tester).height,
        304,
        reason: 'catalogue text of any length leaves the card its budget',
      );

      await _teardown(tester);
    });

    /// The ten-foot type floor is 14 sp (vlc/panel/player_panel_metrics.dart).
    /// Exactly one string on this card is under it: the ring's digits at 13.
    testWidgets('every informational string clears the ten-foot floor', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            rating: 8.14,
            runtime: const Duration(minutes: 42),
            description: _longSynopsis,
            isTv: true,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      double sizeOf(Finder finder) =>
          tester.renderObject<RenderParagraph>(finder).text.style!.fontSize!;

      expect(sizeOf(find.textContaining('S1 E2')), 14);
      expect(sizeOf(find.textContaining('42m')), 14);
      expect(sizeOf(find.text(_longTitle)), 18);
      expect(sizeOf(find.text(_longSynopsis)), 14);
      expect(sizeOf(find.text('Play Now')), 16);
      expect(sizeOf(find.text('Cancel')), 16);

      expect(sizeOf(find.text('UP NEXT')), 14);

      // The one declared exception: two digits at 14 sp do not fit a 30 dp
      // ring.
      expect(sizeOf(find.text('15')), 13);

      await _teardown(tester);
    });

    /// Accessibility scaling, on the branch that can reach it: TV is immune
    /// because main.dart pins `TextScaler.noScaling` there.
    for (final scale in [1.0, 1.3, 1.5, 1.75, 2.0]) {
      testWidgets('the stacked card holds at text scale $scale', (
        tester,
      ) async {
        _sizeView(tester, _smallTablet);
        await tester.pumpWidget(
          _host(
            NextEpisodeCountdown(
              title: _longTitle,
              posterUrl: 'https://example.com/still.jpg',
              season: 1,
              episode: 2,
              rating: 8.14,
              runtime: const Duration(minutes: 42),
              description: _longSynopsis,
              onPlayNext: () {},
              onCancel: () {},
            ),
            locale: 'kn',
            textScale: scale,
          ),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'a RenderFlex overflow is an exception, and there is none',
        );
        final card = _cardRect(tester);
        expect(
          card.height,
          lessThanOrEqualTo(600 - (132 + 12) - 92),
          reason:
              'the card stays inside the band between the top bar and the '
              'scrubber at every scale it honours',
        );
        expect(
          card.bottom,
          600 - (132 + 12),
          reason: 'and stays anchored where it was',
        );

        // The ring is the only thing saying the advance is automatic, so the
        // still may shrink but may never shrink out from under the badge.
        final still = tester.getRect(find.byType(CachedNetworkImage));
        expect(
          still.height,
          greaterThanOrEqualTo(56),
          reason: 'the badge is 38 dp at a 10 dp offset inside the still',
        );
        expect(still.contains(tester.getRect(find.text('15')).center), isTrue);

        // Past 1.3 - the top of Android's Display font-size range - the card
        // holds its type rather than clipping the primary action.
        final l10n = await _l10n('kn');
        final measured = _label(tester, l10n.playNow);
        expect(measured.needs, lessThanOrEqualTo(measured.gets));

        await _teardown(tester);
      });
    }

    /// The compact branch has no flexible child to give - its thumbnail is a
    /// fixed 96x54 - so the clamp is all that stands between it and an
    /// overflow.
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('the compact card holds at text scale $scale', (
        tester,
      ) async {
        _sizeView(tester, _phone);
        await tester.pumpWidget(
          _host(
            NextEpisodeCountdown(
              title: _longTitle,
              posterUrl: 'https://example.com/still.jpg',
              season: 1,
              episode: 2,
              rating: 8.14,
              runtime: const Duration(minutes: 42),
              description: _longSynopsis,
              onPlayNext: () {},
              onCancel: () {},
            ),
            locale: 'kn',
            textScale: scale,
          ),
        );

        expect(tester.takeException(), isNull);
        final card = _cardRect(tester);
        expect(
          card.height,
          218,
          reason:
              'the row is the 54 dp thumbnail\'s height, not the text\'s, so '
              'the compact card does not move at all across the range it '
              'honours',
        );
        expect(card.height, lessThanOrEqualTo(390 - _kClearance));
        final l10n = await _l10n('kn');
        for (final label in [l10n.playNow, l10n.cancel]) {
          final measured = _label(tester, label);
          expect(measured.needs, lessThanOrEqualTo(measured.gets));
        }

        await _teardown(tester);
      });
    }

    /// Both clearances are preferences, and the order they are given up in is
    /// the point. Held sideways a 360 dp phone leaves
    /// `360 - 144 chrome - 92 title` = 124 dp for a compact card that measures
    /// 218. The clearance over the running title goes first; only once that is
    /// spent does the clearance over the scrubber start giving, a dp at a time.
    for (final height in [360.0, 340.0, 320.0]) {
      testWidgets('a ${height.toInt()} dp phone gets the card, not a break', (
        tester,
      ) async {
        _sizeView(tester, Size(height * 2.1, height));
        await tester.pumpWidget(
          _host(
            NextEpisodeCountdown(
              title: _longTitle,
              posterUrl: 'https://example.com/still.jpg',
              season: 1,
              episode: 2,
              description: _longSynopsis,
              onPlayNext: () {},
              onCancel: () {},
            ),
            locale: 'kn',
          ),
        );

        expect(tester.takeException(), isNull);
        final card = _cardRect(tester);
        expect(
          card.height,
          218,
          reason: 'the card is whole; what gives is the clearance around it',
        );
        // 224 is [_kMinCardHeight]: the clearance is measured back from that
        // floor, so the card is never handed less room than it needs.
        expect(
          card.bottom,
          height == 360.0 ? height - 136 : 224,
          reason:
              'the scrubber clearance is capped at what is left after the '
              'card floor is reserved, so it is 136 at 360 dp and whatever '
              'the viewport can spare below that',
        );

        await _teardown(tester);
      });
    }

    testWidgets('the card is outlined over the still, not under it', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            posterUrl: 'https://example.com/still.jpg',
            isTv: true,
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      // The still is flush to the card's top and both sides, so a border at
      // the default DecorationPosition.background is painted and then covered
      // by the image.
      final outline = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(NextEpisodeCountdown),
              matching: find.byType(DecoratedBox),
            ),
          )
          .where((box) {
            final decoration = box.decoration as BoxDecoration;
            // The card's radius, so the two 10 dp action slabs - which carry
            // borders of their own - are not counted.
            return decoration.border != null &&
                decoration.borderRadius == BorderRadius.circular(14);
          })
          .toList();
      expect(outline, hasLength(1), reason: 'one outline, and it is the card');
      expect(outline.single.position, DecorationPosition.foreground);

      final still = tester.getRect(find.byType(CachedNetworkImage));
      final card = _cardRect(tester);
      expect(
        still.top,
        card.top,
        reason: 'flush, which is why the border has to paint in front',
      );

      // The image is clipped to the radius inside the line rather than to the
      // card's outer 14, where its corner would sit proud of the border.
      final clip = tester.widget<ClipRRect>(
        find
            .ancestor(
              of: find.byType(CachedNetworkImage),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(
        clip.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(13)),
      );

      await _teardown(tester);
    });

    testWidgets('the remote walks Play now then Cancel, and Back declines', (
      tester,
    ) async {
      _sizeView(tester, _tv);
      var played = 0;
      var cancelled = 0;
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: _longTitle,
            posterUrl: 'https://example.com/still.jpg',
            season: 1,
            episode: 2,
            description: _longSynopsis,
            isTv: true,
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      // One autofocus, on the action the timeout will take, and Cancel one
      // step down: the actions are a column, not a row.
      expect(_focusLabel, kPlayNextFocusLabel);
      final play = _buttonRect(tester, 'Play Now');
      final cancel = _buttonRect(tester, 'Cancel');
      expect(cancel.top, greaterThanOrEqualTo(play.bottom));
      expect(cancel.left, play.left);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        _focusLabel,
        kPlayNextFocusLabel,
        reason: 'there is nothing to the right of Play now any more',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusLabel, kCancelFocusLabel);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusLabel, kPlayNextFocusLabel);

      // Back out of the card is "no", not "leave the player".
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        platform: 'android',
        physicalKey: PhysicalKeyboardKey.escape,
      );
      expect(cancelled, 1);
      expect(played, 0);

      await _teardown(tester);
    });
  });

  /// The card's height budget, measured against the widget it is a budget of.
  ///
  /// A real [PlayerBottomBar] stands in the same [Stack], in the order the
  /// player composes them - controls first, card second - so the card paints
  /// and hit-tests in front of the bar and any part of the scrubber it covers
  /// cannot be dragged.
  ///
  /// The bar is built here rather than driven through `VlcPlayerControls`
  /// because the controls pick their touch layout off `Platform.isAndroid ||
  /// Platform.isIOS`, which on a macOS or Linux test host is always false: a
  /// test that went through them would measure the desktop bar. `isTouch: true`
  /// here is the phone branch, and the leading group carries the 40 dp
  /// play/pause glyph that sets the transport row's height, so the bar lays
  /// out at the 123 dp a phone actually gets.
  group('NextEpisodeCountdown clears the real PlayerBottomBar', () {
    Widget withBar(Widget card, {required bool isTv}) {
      return ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // The chrome, first — exactly as vlc_player_screen.dart puts
                // VlcPlayerControls before the up-next card.
                Align(
                  alignment: Alignment.bottomCenter,
                  child: PlayerBottomBar(
                    isTv: isTv,
                    isTouch: !isTv,
                    progressBar: PlayerScrubber(
                      position: const Duration(minutes: 38),
                      duration: const Duration(minutes: 42),
                      bufferRatio: 0,
                      canSeek: true,
                      isTv: isTv,
                      onChanged: (_) {},
                      onChangeStart: (_) {},
                      onChangeEnd: (_) {},
                    ),
                    leading: [
                      PlayerIconButton(
                        icon: Icons.replay_10,
                        tooltip: 'back',
                        isTv: isTv,
                        onPressed: () {},
                      ),
                      // The tallest thing in the transport row, and so the
                      // thing that sets the bar's height.
                      PlayerIconButton(
                        icon: Icons.pause_rounded,
                        tooltip: 'pause',
                        isTv: isTv,
                        iconSize: 40,
                        onPressed: () {},
                      ),
                      PlayerIconButton(
                        icon: Icons.forward_10,
                        tooltip: 'forward',
                        isTv: isTv,
                        onPressed: () {},
                      ),
                    ],
                    actions: [
                      for (var i = 0; i < 10; i++)
                        PlayerIconButton(
                          icon: Icons.subtitles,
                          tooltip: 'action $i',
                          isTv: isTv,
                          onPressed: () {},
                        ),
                    ],
                  ),
                ),
                // The card, second.
                card,
              ],
            ),
          ),
        ),
      );
    }

    NextEpisodeCountdown cardFor({required bool isTv}) => NextEpisodeCountdown(
      title: _longTitle,
      posterUrl: 'https://example.com/still.jpg',
      season: 5,
      episode: 17,
      rating: 9.1,
      runtime: const Duration(minutes: 44),
      description: _longSynopsis,
      // Held, so the countdown cannot fire mid-assertion.
      paused: true,
      isTv: isTv,
      onPlayNext: () {},
      onCancel: () {},
    );

    /// Every render object under [of], so a hit-test path can be asked
    /// whether the pointer actually landed inside that widget.
    Set<RenderObject> subtree(WidgetTester tester, Finder of) {
      final found = <RenderObject>{};
      void walk(RenderObject node) {
        found.add(node);
        node.visitChildren(walk);
      }

      walk(tester.renderObject(of));
      return found;
    }

    for (final entry in <(String, Size, bool)>[
      ('a 1080p television', _tv, true),
      ('a phone in landscape', _phone, false),
      ('a phone in portrait', const Size(400, 700), false),
      ('a 360 dp phone in landscape', const Size(756, 360), false),
      ('a small tablet', _smallTablet, false),
    ]) {
      final (name, size, isTv) = entry;

      testWidgets('the card never covers the scrubber on $name', (
        tester,
      ) async {
        _sizeView(tester, size);
        await tester.pumpWidget(withBar(cardFor(isTv: isTv), isTv: isTv));
        // The touch strip reports its scroll metrics in a microtask after
        // layout and re-runs the narrow/flat decision on the frame after that,
        // so an unsettled tree measures the flat bar even where the shipped
        // one is two rows. Settle before reading anything.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        // The right-hand end of the seek bar - the end a viewer reaches for
        // to scrub back into the scene - still receives the pointer.
        final seek = tester.getRect(find.byType(PlayerSeekBar));
        // Inside the seek bar's own rectangle by construction, and at the end
        // of it the right-anchored card hangs over.
        final target = Offset(seek.right - 8, seek.center.dy);
        expect(seek.contains(target), isTrue);

        final path = tester.hitTestOnBinding(target).path.toList();
        final scrubber = subtree(tester, find.byType(PlayerSeekBar));
        final owned = subtree(tester, find.byType(NextEpisodeCountdown));
        final eaten = path.where((e) => owned.contains(e.target));
        expect(
          path.where((e) => scrubber.contains(e.target)),
          isNotEmpty,
          reason: eaten.isEmpty
              ? 'a finger put down inside the seek bar at $target never '
                    'reaches it'
              : 'a finger put down inside the seek bar at $target never '
                    'reaches it: the up-next card is in front and swallows '
                    'the drag',
        );
        expect(
          eaten,
          isEmpty,
          reason:
              'nothing the card owns may be in the hit path of a point on '
              'the scrubber',
        );

        // Then the geometry that guarantees it for the whole bar, not just
        // the one point probed above.
        final bar = tester.getRect(find.byType(PlayerBottomBar));
        final card = _cardRect(tester);
        expect(
          card.bottom,
          lessThanOrEqualTo(bar.top),
          reason:
              'the card is later in the Stack, so every dp of the '
              '${bar.height} dp bar it hangs over is a dp of chrome the '
              'viewer cannot touch',
        );
      });
    }
  });
}
