import 'package:flutter/services.dart';

/// The keys that mean "press the player control that currently has focus".
///
/// A D-pad "OK" is not one key. A television remote sends
/// [LogicalKeyboardKey.select]; a keyboard sends [LogicalKeyboardKey.enter] or
/// [LogicalKeyboardKey.space]; and a game controller — including every Android
/// TV device whose HID layer reports DPAD_CENTER as BUTTON_A — sends
/// [LogicalKeyboardKey.gameButtonA]. All four have to activate.
///
/// Nothing rescues a miss further up the tree. WidgetsApp binds gameButtonA to
/// an ActivateIntent, but its default actions map ships no ActivateAction to
/// answer it, and where a `Focus` sits above an `InkWell` the InkWell's own
/// `Actions` map is a descendant of the focused node, so `Actions.invoke`
/// never walks down to find it.
///
/// Four explicit keys in one predicate rather than an `Actions` wrapper is
/// this codebase's idiom: a control is one focus stop with one key test, and
/// directional movement is left entirely to native traversal.
bool isPlayerActivation(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.space ||
    key == LogicalKeyboardKey.gameButtonA;
