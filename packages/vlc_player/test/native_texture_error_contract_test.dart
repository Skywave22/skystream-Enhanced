import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Linux texture's answer to "give me pixels", pinned as source text.
///
/// The GTK embedder does not tolerate a refusal. Its frame callback
/// (fl_engine.cc, fl_engine_gl_external_texture_frame_callback) declares
/// `g_autoptr(GError) error = nullptr`, calls populate, and on FALSE does
/// `g_warning("%s", error->message)` without ever checking whether populate
/// set the error. A copy_pixels that returns FALSE with `error` untouched is
/// therefore a null dereference on the raster thread, and it takes the process
/// down rather than the frame.
///
/// That refusal used to be certain rather than rare: the embedder resolves an
/// external texture on its first paint (EmbedderExternalTextureGL::Paint,
/// `if (last_image_ == nullptr)`) whether or not a frame was ever committed,
/// and the sink has nothing until libVLC decodes one - so on Linux the app
/// died the moment any content started playing, whatever the content was.
///
/// No CI machine runs this plugin and no Dart-level test can reach it, so the
/// contract is asserted where it lives: in the text of the two functions that
/// hold it, plus the Windows pair that shows the asymmetry is deliberate.
void main() {
  group('Linux pixel-buffer texture', () {
    late String copyPixels;

    setUpAll(() {
      copyPixels = _functionBody(
        _fileText('linux/vlc_player_plugin.cc'),
        'gboolean vlc_pixel_buffer_texture_copy_pixels(',
      );
    });

    test('cannot return anything but true without setting the GError', () {
      // Deliberately stricter than "contains no `return false`". The original
      // bug returned a *variable* - `return copied;` - which no literal-only
      // check would have caught. So the invariant asserted is that every exit
      // is unconditionally truthy: anything else is a refusal in waiting.
      final returns = _returnedExpressions(copyPixels).toList();
      expect(returns, isNotEmpty, reason: 'Failed to parse the function body.');
      final refusals =
          returns.where((expression) => !_isAlwaysTrue(expression)).toList();
      if (refusals.isEmpty) {
        return;
      }
      expect(
        copyPixels,
        contains('g_set_error'),
        reason:
            'copy_pixels can return ${refusals.join(', ')}, which the GTK '
            'embedder reads as an error before dereferencing a GError nobody '
            'set. Either return a placeholder instead of refusing, or call '
            'g_set_error on every path that can refuse.',
      );
    });

    test('hands the engine a real pointer and size when it has no frame', () {
      // A truthy return with the out-parameters left alone is worse than a
      // refusal: the engine uploads whatever the caller's stack happened to
      // hold. Whatever stands in for the picture has to be pointed at.
      expect(copyPixels, contains('*buffer = '));
      expect(copyPixels, contains('*width = '));
      expect(copyPixels, contains('*height = '));
    });

    test('the placeholder outlives the upload', () {
      // The engine reads through this pointer inside populate. A buffer with
      // automatic storage would be gone by then; the fallback has to point at
      // something with static lifetime.
      final source = _fileText('linux/vlc_player_plugin.cc');
      expect(
        copyPixels,
        contains('*buffer = kBlankPixel;'),
        reason: 'The fallback should point at the file-scope placeholder.',
      );
      expect(
        source,
        contains('const uint8_t kBlankPixel[4]'),
        reason: 'kBlankPixel must be a file-scope constant, not a local.',
      );
    });
  });

  group('Windows pixel-buffer texture', () {
    test('may refuse, because its embedder checks before dereferencing', () {
      // external_texture_pixelbuffer.cc: `if (!pixel_buffer ||
      // !pixel_buffer->buffer) { return false; }`. Windows is allowed the
      // honest answer Linux is not, and this test records why the two
      // platforms differ rather than leaving it looking like an oversight.
      final copyPixelBuffer = _functionBody(
        _fileText('windows/vlc_player_plugin.cpp'),
        'const FlutterDesktopPixelBuffer *CopyPixelBuffer(size_t width,',
      );
      expect(copyPixelBuffer, contains('return nullptr;'));
    });
  });
}

String _fileText(String path) => File(path).readAsStringSync();

/// Every expression returned by [body], with comments stripped first so that
/// prose about `return FALSE` does not read as code that does it.
Iterable<String> _returnedExpressions(String body) {
  final code = body
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');
  return RegExp(r'\breturn\s+([^;]+);')
      .allMatches(code)
      .map((match) => match.group(1)!.trim());
}

bool _isAlwaysTrue(String expression) =>
    expression == 'true' || expression == 'TRUE' || expression == '1';

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
