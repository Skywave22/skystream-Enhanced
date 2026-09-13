import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/utils/layout_constants.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/details_screen.dart';
import 'package:skystream/features/details/presentation/downloaded_file_provider.dart';
import 'package:skystream/features/library/presentation/library_provider.dart';
import 'package:skystream/features/library/presentation/library_state.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const String _kUrl = 'https://fake.test/title';
const String _kBanner = 'https://fake.test/banner.jpg';

/// A large phone in portrait: 590x1200 logical at a raster scale of 3, which
/// is the mobile branch (`isTabletOrLarger` is false below 600 dp) with enough
/// room that the test font's wide glyphs do not overflow the metadata row.
/// The mobile SliverAppBar hero is the one this screen paints — a television
/// is `isTabletOrLarger` and takes the desktop hero instead.
const double _phoneDevicePixelRatio = 3.0;
const double _phoneLogicalWidth = 590;
const Size _phonePhysicalSize = Size(1770, 3600);

/// Every history getter goes through Hive-backed [StorageService]; answer
/// "never watched" and skip the boxes entirely.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  int getPosition(String url) => 0;
  @override
  int getDuration(String url) => 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

/// The real notifier hits path_provider through DownloadService on the
/// post-frame check; keep the map and drop the disk probe.
class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

/// The screen's own post-frame `loadDetails` would go to the network; the
/// state is handed to it already resolved instead.
class _FakeDetailsController extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncValue.data(_item()),
    isMovie: true,
    item: _item(),
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
    bool forceRefresh = false,
  }) async {}
}

/// The bookmark row, without Hive underneath it.
class _FakeLibrary extends Library {
  @override
  LibraryState build() => const LibraryEmpty();
}

MultimediaItem _item() => MultimediaItem(
  title: 'A Title',
  url: _kUrl,
  posterUrl: '',
  bannerUrl: _kBanner,
  contentType: MultimediaContentType.movie,
);

/// Stands in for any MediaQuery shim installed above this screen. `main.dart`
/// ships one: on television it rebuilds the whole app under
/// `devicePixelRatio: 1.0`. It cannot change the raster scale — that is read
/// off the FlutterView — so a decode sized from MediaQuery asks for a
/// fraction of the pixels the panel paints and is upscaled to fill.
class _DensityClamp extends StatelessWidget {
  const _DensityClamp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(devicePixelRatio: 1.0),
      child: child,
    );
  }
}

Future<void> _pumpDetails(WidgetTester tester, {bool clampDensity = false}) async {
  tester.view.devicePixelRatio = _phoneDevicePixelRatio;
  tester.view.physicalSize = _phonePhysicalSize;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(_NoHistory()),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider.overrideWith(_FakeDetailsController.new),
      libraryProvider.overrideWith(_FakeLibrary.new),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: clampDensity
            ? (context, child) => _DensityClamp(child: child!)
            : null,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DetailsScreen(item: _item()),
      ),
    ),
  );
  // Never settle: the artwork placeholders never resolve under test.
  await tester.pump();
}

CachedNetworkImage _hero(WidgetTester tester) => tester.widget<CachedNetworkImage>(
  find.byWidgetPredicate(
    (w) => w is CachedNetworkImage && w.imageUrl == _kBanner,
  ),
);

void main() {
  group('the details hero bounds its decode to what cover paints', () {
    testWidgets('at the sliver box, not at the window width', (tester) async {
      await _pumpDetails(tester);

      // A 16:9 backdrop behind a 590x400 dp hero is scaled by the HEIGHT and
      // cropped at the sides, so 590 dp of window width is not the width that
      // has to be sharp: 400 * 16/9 = 711.1 dp is, and at 3x that is 2133 px.
      const boxWidth = _phoneLogicalWidth;
      const boxHeight = LayoutConstants.detailsExpandedHeightMobile;
      const expected = 2133; // (400 * 16 / 9 * 3).round()

      expect(tester.getSize(find.byType(DetailsScreen)).width, boxWidth);
      expect(boxHeight, 400);
      expect(_hero(tester).memCacheWidth, expected);
      expect(
        _hero(tester).memCacheWidth,
        isNot((boxWidth * _phoneDevicePixelRatio).round()),
        reason: 'bounded to the window width, which cover crops away',
      );
    });

    testWidgets('at the raster scale, immune to a MediaQuery density shim', (
      tester,
    ) async {
      await _pumpDetails(tester, clampDensity: true);

      expect(_hero(tester).memCacheWidth, 2133);
      expect(
        _hero(tester).memCacheWidth,
        isNot(711),
        reason: 'took the shimmed devicePixelRatio of 1.0 off MediaQuery',
      );
    });
  });
}
