import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The desktop texture teardown, pinned as source order.
///
/// Neither of these plugins is built by any CI machine, and the bug they
/// carried - freeing the pixel buffers before retiring the texture, so the
/// compositor read a freed block and the app vanished as the user pressed
/// Back - is invisible to every Dart-level test in this package: it lives
/// entirely in the order of four statements. So the order is what is asserted
/// here, in the two functions that own it.
void main() {
  group('Windows plugin teardown', () {
    late String disposeCore;
    late String releaseTextureMemory;
    late String copyPixelBuffer;

    setUpAll(() {
      final source = _fileText('windows/vlc_player_plugin.cpp');
      disposeCore = _functionBody(source, 'void DisposeCore()');
      releaseTextureMemory = _functionBody(source, 'void ReleaseTextureMemory()');
      copyPixelBuffer = _functionBody(
        source,
        'const FlutterDesktopPixelBuffer *CopyPixelBuffer(size_t width,',
      );
    });

    test('stops libVLC before it retires the texture', () {
      expect(
        disposeCore.indexOf('core_->Dispose()'),
        lessThan(disposeCore.indexOf('UnregisterTexture')),
        reason: 'The blocking stop must not run on the raster thread, which '
            'is where the unregister completion callback lands.',
      );
    });

    test('never frees the core in the dispose itself', () {
      // The free belongs to the unregister completion callback, which the
      // registrar runs on the raster thread once no populate can be in
      // flight. A core_.reset() here is the use-after-free coming back.
      expect(disposeCore, isNot(contains('core_.reset()')));
      expect(disposeCore, isNot(contains('texture_.reset()')));
    });

    test('retires the texture before it releases the memory the texture reads',
        () {
      final unregisterWithCallback = disposeCore.indexOf(
        'texture_registrar_->UnregisterTexture(\n'
        '          texture_id, [self] { self->ReleaseTextureMemory(); });',
      );
      expect(
        unregisterWithCallback,
        isNonNegative,
        reason: 'The completion-callback overload is the only signal that the '
            'engine has finished with the buffer CopyPixelBuffer handed out.',
      );
      // The fallback path - no shared owner, i.e. engine teardown - still has
      // to unregister before it frees.
      final lastUnregister = disposeCore.lastIndexOf('UnregisterTexture');
      final release = disposeCore.lastIndexOf('ReleaseTextureMemory()');
      expect(lastUnregister, lessThan(release));
    });

    test('frees the core under the frame lock', () {
      expect(
        releaseTextureMemory.indexOf('lock(frame_mutex_)'),
        lessThan(releaseTextureMemory.indexOf('core_.reset()')),
      );
      expect(releaseTextureMemory, contains('texture_.reset()'));
    });

    test('reads the core under the frame lock, and takes no other lock there',
        () {
      expect(
        copyPixelBuffer.indexOf('lock(frame_mutex_)'),
        lessThan(copyPixelBuffer.indexOf('core_->CopyPixels')),
      );
      // lifecycle_mutex_ is held across libVLC's stop; taking it here would
      // stall the raster thread for the whole shutdown.
      expect(copyPixelBuffer, isNot(contains('lifecycle_mutex_')));
    });
  });

  group('Linux plugin teardown', () {
    late String dispose;
    late String copyPixels;

    setUpAll(() {
      final source = _fileText('linux/vlc_player_plugin.cc');
      dispose = _functionBody(source, 'void Dispose()');
      copyPixels = _functionBody(
        source,
        'gboolean vlc_pixel_buffer_texture_copy_pixels(FlPixelBufferTexture* '
        'texture,',
      );
    });

    test('stops libVLC, retires the texture, closes the read path, then frees',
        () {
      final stop = dispose.indexOf('core_->Dispose()');
      final unregister =
          dispose.indexOf('fl_texture_registrar_unregister_texture');
      final closeReadPath = dispose.indexOf('texture_->player = nullptr');
      final free = dispose.indexOf('core_.reset()');

      expect(stop, isNonNegative);
      expect(unregister, greaterThan(stop));
      expect(closeReadPath, greaterThan(unregister));
      expect(free, greaterThan(closeReadPath));
    });

    test('clears the texture player under its mutex', () {
      final lock = dispose.indexOf('g_mutex_lock(&texture_->player_mutex)');
      final clear = dispose.indexOf('texture_->player = nullptr');
      final unlock = dispose.indexOf('g_mutex_unlock(&texture_->player_mutex)');

      expect(lock, isNonNegative);
      expect(clear, greaterThan(lock));
      expect(unlock, greaterThan(clear));
      expect(
        dispose.indexOf('g_clear_object(&texture_)'),
        greaterThan(unlock),
      );
    });

    test('holds the texture mutex across the whole read, not just the load',
        () {
      final lock = copyPixels.indexOf('g_mutex_lock(&self->player_mutex)');
      final read = copyPixels.indexOf('self->player->CopyPixels(');
      final unlock = copyPixels.indexOf('g_mutex_unlock(&self->player_mutex)');

      expect(lock, isNonNegative);
      expect(read, greaterThan(lock));
      expect(unlock, greaterThan(read));
    });
  });
}

String _fileText(String path) => File(path).readAsStringSync();

/// The body of the function whose declaration starts with [signature],
/// brace-matched so a nested lambda cannot end it early.
String _functionBody(String source, String signature) {
  final declaration = source.indexOf(signature);
  if (declaration == -1) {
    fail('Could not find $signature.');
  }
  final start = source.indexOf('{', declaration);
  if (start == -1) {
    fail('Could not find the opening brace of $signature.');
  }

  var depth = 0;
  for (var index = start; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (char == 0x7b) {
      depth += 1;
    } else if (char == 0x7d) {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, index + 1);
      }
    }
  }

  fail('Could not find the closing brace of $signature.');
}
