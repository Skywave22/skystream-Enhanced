import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('vlc_player');
  final eventChannels = <EventChannel>[];

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in eventChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(channel, null);
    }
    eventChannels.clear();
  });

  Future<void> runAsPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> runAsWindows(Future<void> Function() body) async {
    await runAsPlatform(TargetPlatform.windows, body);
  }

  void mockEventChannel(int viewId) {
    final channel = EventChannel('vlc_player/events/$viewId');
    eventChannels.add(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          channel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {},
            onCancel: (arguments) {},
          ),
        );
  }

  List<MethodCall> recordPluginCalls() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return null;
        });
    return calls;
  }

  testWidgets('platform views never take focus', (WidgetTester tester) async {
    // Flutter wraps every platform view in a Focus node (platform_view.dart
    // declares _focusNode, builds Focus(...), and installs an onFocus callback
    // that calls requestFocus). On a TV that node is a full-screen focusable
    // candidate: when the host hides its controls, the video surface becomes
    // the only thing left to focus, so the remote's Play/Pause stops working
    // and focus goes invisible. ExcludeFocus removes it from traversal.
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      await runAsPlatform(platform, () async {
        recordPluginCalls();
        _PlatformViewsRecorder(onCreate: mockEventChannel).install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 320,
              height: 180,
              child: VlcPlayer(
                controller: controller,
                // This test is about the PLATFORM VIEW. Every platform here
                // defaults to the texture since 2026-09-06, so ask for the
                // view explicitly on each.
                darwinRenderer: VlcDarwinRenderer.platformView,
                androidRenderer: VlcAndroidRenderer.platformView,
              ),
            ),
          ),
        );
        await tester.pump();

        final excludes = find.ancestor(
          of: find.byType(switch (platform) {
            TargetPlatform.android => AndroidView,
            TargetPlatform.iOS => UiKitView,
            TargetPlatform.macOS => AppKitView,
            _ => throw StateError('Unexpected platform $platform.'),
          }),
          matching: find.byType(ExcludeFocus),
        );
        expect(
          excludes,
          findsOneWidget,
          reason: 'the $platform platform view must be wrapped in ExcludeFocus',
        );

        // Nothing under the player may be reachable by directional traversal.
        final scope = FocusScope.of(tester.element(find.byType(VlcPlayer)));
        expect(scope.traversalDescendants, isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    }
  });

  testWidgets('creates platform views with player options and fit', (
    WidgetTester tester,
  ) async {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      await runAsPlatform(platform, () async {
        recordPluginCalls();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController(
          options: const <String>['--network-caching=300'],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 320,
              height: 180,
              child: VlcPlayer(
                controller: controller,
                fit: VlcVideoFit.fill,
                // This test is about the PLATFORM VIEW. Every platform here
                // defaults to the texture since 2026-09-06, so ask for the
                // view explicitly on each.
                darwinRenderer: VlcDarwinRenderer.platformView,
                androidRenderer: VlcAndroidRenderer.platformView,
              ),
            ),
          ),
        );
        await tester.pump();

        final view = platformViews.createdViews.single;
        expect(view.viewType, 'plugins.lingjhf.com/vlc_player/view');
        expect(view.creationParams?['options'], <String>[
          '--network-caching=300',
        ]);
        expect(view.creationParams?['fit'], 'fill');
        expect(
          find.byType(switch (platform) {
            TargetPlatform.android => AndroidView,
            TargetPlatform.iOS => UiKitView,
            TargetPlatform.macOS => AppKitView,
            _ => throw StateError('Unexpected platform $platform.'),
          }),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    }
  });

  testWidgets('shows an unsupported platform fallback', (
    WidgetTester tester,
  ) async {
    await runAsPlatform(TargetPlatform.fuchsia, () async {
      final controller = VlcPlayerController();

      await tester.pumpWidget(
        MaterialApp(home: VlcPlayer(controller: controller)),
      );

      expect(find.textContaining('currently supports'), findsOneWidget);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('replacing a texture controller attaches a new player', (
    WidgetTester tester,
  ) async {
    await runAsWindows(() async {
      var nextViewId = 70;
      var nextTextureId = 170;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            calls.add(call);
            if (call.method == 'create') {
              final viewId = nextViewId++;
              mockEventChannel(viewId);
              return <String, Object?>{
                'viewId': viewId,
                'textureId': nextTextureId++,
              };
            }
            return null;
          });
      final first = VlcPlayerController();
      final second = VlcPlayerController();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: VlcPlayer(controller: first),
        ),
      );
      await tester.pump();
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 170);
      expect(first.isAttached, isTrue);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: VlcPlayer(controller: second),
        ),
      );
      await tester.pump();

      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 171);
      expect(first.isAttached, isFalse);
      expect(second.isAttached, isTrue);
      expect(calls.map((call) => call.method), <String>['create', 'create']);

      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      second.dispose();
    });
  });

  testWidgets('shows a loading indicator while a texture is created', (
    WidgetTester tester,
  ) async {
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      final createCompleter = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              return createCompleter.future;
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(home: VlcPlayer(controller: controller)),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('shows texture creation errors', (WidgetTester tester) async {
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              throw PlatformException(code: 'create_failed', message: 'failed');
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(home: VlcPlayer(controller: controller)),
      );
      await tester.pump();

      expect(find.textContaining('VlcPlayerException'), findsOneWidget);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('shows the texture after native player creation succeeds', (
    WidgetTester tester,
  ) async {
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(7);
              return <String, Object?>{'viewId': 7, 'textureId': 42};
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(home: VlcPlayer(controller: controller)),
      );
      await tester.pump();

      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 42);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('scales a picture smaller than the viewport up to fill it', (
    WidgetTester tester,
  ) async {
    // Before the fix this was Center -> FittedBox, and under loose
    // constraints a FittedBox takes its child's natural size. A 1080p picture
    // therefore sat at 1:1 in the middle of a larger window - only 4K filled
    // it, and only because it had to shrink. Here the texture is 160x90 in a
    // 320x180 viewport: it must come out 320x180, not 160x90.
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(9);
              return <String, Object?>{'viewId': 9, 'textureId': 44};
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: VlcPlayer(
                controller: controller,
                fit: VlcVideoFit.contain,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const channel = EventChannel('vlc_player/events/9');
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeSuccessEnvelope(<String, Object?>{
              'state': 'playing',
              'videoSize': <String, Object?>{'width': 160, 'height': 90},
            }),
            null,
          );
      await tester.pump();

      // getRect follows FittedBox's paint transform, so this is the size the
      // viewer sees. 160x90 here is the old bug.
      expect(tester.getRect(find.byType(Texture)).size, const Size(320, 180));
      // No coded size was reported, so nothing is clipped.
      expect(find.byType(ClipRect), findsNothing);

      controller.dispose();
    });
  });

  testWidgets('clips the decoder padding off a texture-backed picture', (
    WidgetTester tester,
  ) async {
    // Decoders pad height to a multiple of 16, so 180 visible rows arrive in a
    // 192-row buffer whose last twelve rows are never written - and unwritten
    // NV12 is green. The widget must lay the texture out at the coded size and
    // clip it to the visible one, anchored top-left where the real rows are.
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(10);
              return <String, Object?>{'viewId': 10, 'textureId': 45};
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: VlcPlayer(
                controller: controller,
                fit: VlcVideoFit.contain,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const channel = EventChannel('vlc_player/events/10');
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeSuccessEnvelope(<String, Object?>{
              'state': 'playing',
              'videoSize': <String, Object?>{'width': 320, 'height': 180},
              'codedSize': <String, Object?>{'width': 320, 'height': 192},
            }),
            null,
          );
      await tester.pump();

      expect(controller.value.codedVideoSize, const Size(320, 192));
      expect(find.byType(ClipRect), findsOneWidget);

      final align = tester.widget<Align>(
        find.ancestor(of: find.byType(Texture), matching: find.byType(Align)),
      );
      expect(align.alignment, Alignment.topLeft);
      expect(align.widthFactor, 1.0);
      // 179, not 180: the clip stops one source row short of the padding so
      // bilinear sampling cannot reach it. See the sampling-guard test below.
      expect(align.heightFactor, closeTo(179 / 192, 1e-9));

      // The texture itself is the whole buffer; the clip is what hides the
      // padding. Laid out at 192 rows, shown as 180.
      final textureBox = tester.widget<SizedBox>(
        find
            .ancestor(of: find.byType(Texture), matching: find.byType(SizedBox))
            .first,
      );
      expect(textureBox.height, 192);

      controller.dispose();
    });
  });

  testWidgets('fits texture players with the configured video fit', (
    WidgetTester tester,
  ) async {
    await runAsWindows(() async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(8);
              return <String, Object?>{'viewId': 8, 'textureId': 43};
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 180,
            child: VlcPlayer(controller: controller, fit: VlcVideoFit.cover),
          ),
        ),
      );
      await tester.pump();

      const channel = EventChannel('vlc_player/events/8');
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeSuccessEnvelope(<String, Object?>{
              'state': 'playing',
              'videoSize': <String, Object?>{'width': 640, 'height': 360},
            }),
            null,
          );
      await tester.pump();

      final fittedBox = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fittedBox.fit, BoxFit.cover);
      expect(find.byType(Texture), findsOneWidget);

      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('holds the clip a source row clear of the decoder padding', (
    WidgetTester tester,
  ) async {
    // The coloured line along the bottom edge. Clipping at the exact boundary
    // between the written rows and the padding is not enough: the compositor
    // samples the texture bilinearly, so the destination row that lands on the
    // boundary blends the last written row with the first unwritten one, and
    // unwritten NV12 reads green. The clip therefore has to stop one whole
    // source row short - a whole row rather than half a texel because NV12
    // carries chroma at half height, so half a luma row is only a quarter of a
    // chroma texel of margin.
    //
    // macOS because that is where the NV12 buffer is: it and iOS render
    // through the shared CVPixelBuffer sink. Windows and Linux take the same
    // Dart path with an RGBA buffer, where a half texel would do and a whole
    // one is still correct. Android's default is a platform view, which never
    // reaches this code.
    await runAsPlatform(TargetPlatform.macOS, () async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(11);
              return <String, Object?>{'viewId': 11, 'textureId': 46};
            }
            return null;
          });

      // Deliberately upscaling: 180 visible rows into 360 logical ones. That
      // is the direction that bleeds - the destination row on the boundary
      // maps to a source coordinate less than half a texel inside it, so its
      // filter footprint crosses into the padding.
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 640,
              height: 360,
              child: VlcPlayer(
                controller: controller,
                fit: VlcVideoFit.contain,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const channel = EventChannel('vlc_player/events/11');
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeSuccessEnvelope(<String, Object?>{
              'state': 'playing',
              'videoSize': <String, Object?>{'width': 320, 'height': 180},
              'codedSize': <String, Object?>{'width': 320, 'height': 192},
            }),
            null,
          );
      await tester.pump();

      // The whole 192-row buffer, laid out and scaled by the FittedBox.
      final buffer = tester.getRect(find.byType(Texture));
      // What survives the clip.
      final shown = tester.getRect(
        find.ancestor(of: find.byType(Texture), matching: find.byType(Align)),
      );
      final sourceRow = buffer.height / 192;
      final paddingStart = buffer.top + 180 * sourceRow;

      // A full source row of margin, and no more than that: over-insetting
      // would throw away picture the viewer paid for.
      expect(shown.bottom, lessThan(paddingStart - sourceRow + 1e-6));
      expect(shown.bottom, greaterThan(paddingStart - 2 * sourceRow));
      // 320 is already a multiple of 16, so the width carries no padding and
      // must not be inset.
      expect(shown.left, closeTo(buffer.left, 1e-6));
      expect(shown.right, closeTo(buffer.right, 1e-6));

      controller.dispose();
    });
  });

  testWidgets(
    'clips with a hard edge, which the one-row sampling guard depends on',
    (WidgetTester tester) async {
      // The guard above buys exactly one source row and no slack, and it is
      // enough only while the clip boundary rounds to a whole device pixel.
      // Clip.hardEdge draws the last device row centred at round(D) - 0.5,
      // never past the boundary D, so the bilinear tap stops at source row
      // `shown` - the last written one. Clip.antiAlias draws the boundary
      // pixel at partial coverage and still samples it at its own centre, so
      // the tap reaches shown + 0.5/m, where m is device rows per source row.
      // Below m = 0.5 - a 1080p picture in fewer than 540 device rows, which
      // is picture-in-picture or a small window on a 1x display - that is more
      // than one source row and the coloured band is back.
      //
      // Nothing else in this file would notice: every other assertion here
      // measures geometry, and antialiasing changes none of it. This is the
      // only thing standing between a future `clipBehavior:` - added for
      // smoother corners, say - and a silent return of the defect.
      await runAsPlatform(TargetPlatform.macOS, () async {
        final controller = VlcPlayerController();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (call) async {
              if (call.method == 'create') {
                mockEventChannel(13);
                return <String, Object?>{'viewId': 13, 'textureId': 48};
              }
              return null;
            });

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: VlcPlayer(
                  controller: controller,
                  fit: VlcVideoFit.contain,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        const channel = EventChannel('vlc_player/events/13');
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeSuccessEnvelope(<String, Object?>{
                'state': 'playing',
                'videoSize': <String, Object?>{'width': 320, 'height': 180},
                'codedSize': <String, Object?>{'width': 320, 'height': 192},
              }),
              null,
            );
        await tester.pump();

        final clip = tester.widget<ClipRect>(
          find
              .ancestor(
                of: find.byType(Texture),
                matching: find.byType(ClipRect),
              )
              .first,
        );
        expect(
          clip.clipBehavior,
          Clip.hardEdge,
          reason:
              'the padding clip is inset by one source row, which only clears '
              'the bilinear tap while the boundary rounds to a device pixel',
        );

        controller.dispose();
      });
    },
  );

  testWidgets('pressing zoom as the coded size goes stale never shrinks it', (
    WidgetTester tester,
  ) async {
    // The owner's words were that zoom REDUCES the size, and the stale-size
    // mechanism on its own does not say that: while the window is open the
    // picture is small in every fit mode, and cover is still larger than
    // contain. This is the one press that does match the words. The stale
    // window opens on its own - a rendition change mid-play re-declares the
    // track before the vout renegotiates its buffer - so a press that lands in
    // the same frame takes the picture from a healthy contain straight to a
    // stale cover, and before the clamp that was 711x400 down to 267x153.
    //
    // Nothing about pressing a button opens the window; the two just coincide.
    // The assertion is therefore the invariant, not the mechanism: no change
    // of fit may leave the picture smaller than it was on either axis.
    await runAsPlatform(TargetPlatform.macOS, () async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(14);
              return <String, Object?>{'viewId': 14, 'textureId': 49};
            }
            return null;
          });

      Widget player(VlcVideoFit fit) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 400,
            child: VlcPlayer(controller: controller, fit: fit),
          ),
        ),
      );

      const channel = EventChannel('vlc_player/events/14');
      Future<void> report(Size visible, Size coded) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeSuccessEnvelope(<String, Object?>{
                'state': 'playing',
                'videoSize': <String, Object?>{
                  'width': visible.width.toInt(),
                  'height': visible.height.toInt(),
                },
                'codedSize': <String, Object?>{
                  'width': coded.width.toInt(),
                  'height': coded.height.toInt(),
                },
              }),
              null,
            );
      }

      // How much picture the viewer actually gets: the part of the texture
      // that survives the clip. Neither rect alone answers it. The texture
      // rect includes the padding the clip hides, and the clip rect is the
      // Align box, which is the thing that inflates past the texture when the
      // sizes fall out of step - measuring that would report a large empty
      // box as a large picture, which is the very bug in question.
      Size picture() {
        final texture = tester.getRect(find.byType(Texture));
        if (find.byType(ClipRect).evaluate().isEmpty) {
          return texture.size;
        }
        final shown = tester.getRect(
          find
              .ancestor(of: find.byType(Texture), matching: find.byType(Align))
              .first,
        );
        return texture.intersect(shown).size;
      }

      // Playing normally: track info and buffer agree, bar the 8 padding rows.
      await tester.pumpWidget(player(VlcVideoFit.contain));
      await tester.pump();
      await report(const Size(1920, 1080), const Size(1920, 1088));
      await tester.pump();
      final before = picture();
      expect(before.height, closeTo(400, 0.5));

      // The same frame: the viewer presses zoom, and the new rendition's track
      // info arrives against the outgoing vout's buffer.
      await tester.pumpWidget(player(VlcVideoFit.cover));
      await report(const Size(1920, 1080), const Size(640, 368));
      await tester.pump();
      final after = picture();

      expect(
        after.width,
        greaterThanOrEqualTo(before.width),
        reason: 'zoom must not make the picture narrower',
      );
      expect(
        after.height,
        greaterThanOrEqualTo(before.height),
        reason: 'zoom must not make the picture shorter',
      );

      controller.dispose();
    });
  });

  testWidgets('never shrinks the picture when the coded size lags behind', (
    WidgetTester tester,
  ) async {
    // "Zoom made the video smaller." The visible size and the coded size are
    // separate measurements that nothing keeps in step: the visible size is the
    // media's video track as the demuxer declared it (libvlc_video_get_size
    // reads the track info, not the video output), while the coded size is the
    // buffer the current vout negotiated with the sink, and the Darwin renderer
    // holds the previous one until the new vout's setup callback runs. Change
    // media to something larger and, for that window, the visible size exceeds
    // the texture.
    //
    // A ratio above 1 is not a clip. Align grows past its child and pins the
    // picture top-left, so the FittedBox scales a box bigger than the picture
    // and the video is drawn small inside dead space.
    await runAsPlatform(TargetPlatform.macOS, () async {
      final controller = VlcPlayerController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'create') {
              mockEventChannel(12);
              return <String, Object?>{'viewId': 12, 'textureId': 47};
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 800,
              height: 400,
              child: VlcPlayer(
                controller: controller,
                fit: VlcVideoFit.contain,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const channel = EventChannel('vlc_player/events/12');
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeSuccessEnvelope(<String, Object?>{
              'state': 'playing',
              // The new media's track info...
              'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
              // ...against the outgoing vout's buffer.
              'codedSize': <String, Object?>{'width': 640, 'height': 368},
            }),
            null,
          );
      await tester.pump();

      // Contain in a 800x400 box, so the picture is 400 tall and 640/368 of
      // that wide. Before the fix the Align box was 1920x1080 with the texture
      // pinned in its top-left corner, and the picture came out 237x136.
      final picture = tester.getRect(find.byType(Texture));
      expect(picture.height, closeTo(400, 0.01));
      expect(picture.width, closeTo(400 * 640 / 368, 0.01));
      // Nothing to clip: the texture holds no more than is being shown.
      expect(find.byType(ClipRect), findsNothing);

      controller.dispose();
    });
  });
}

class _PlatformViewsRecorder {
  _PlatformViewsRecorder({required this.onCreate});

  final void Function(int viewId) onCreate;
  final List<_RecordedPlatformView> createdViews = <_RecordedPlatformView>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, _handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'create':
        final arguments = (call.arguments as Map).cast<String, Object?>();
        final id = arguments['id']! as int;
        onCreate(id);
        createdViews.add(
          _RecordedPlatformView(
            id: id,
            viewType: arguments['viewType']! as String,
            creationParams: _decodeCreationParams(arguments['params']),
          ),
        );
        return arguments.containsKey('direction') ? 0 : null;
      case 'resize':
        final arguments = (call.arguments as Map).cast<String, Object?>();
        return <String, Object?>{
          'width': arguments['width'],
          'height': arguments['height'],
        };
      default:
        return null;
    }
  }

  Map<Object?, Object?>? _decodeCreationParams(Object? value) {
    if (value is! Uint8List) {
      return null;
    }
    final decoded = const StandardMessageCodec().decodeMessage(
      ByteData.sublistView(value),
    );
    return (decoded as Map).cast<Object?, Object?>();
  }
}

class _RecordedPlatformView {
  const _RecordedPlatformView({
    required this.id,
    required this.viewType,
    required this.creationParams,
  });

  final int id;
  final String viewType;
  final Map<Object?, Object?>? creationParams;
}
