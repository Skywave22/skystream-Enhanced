/// The shape the side panel takes, and the glass it is drawn on.
///
/// Always a right-anchored, full-height drawer. A bottom sheet was the wrong
/// container for this content anywhere: on a 1080p television or a wide desktop
/// window it covers the picture it is describing and gives a forty-source list
/// four visible rows, and on the phone it was the one form factor where the
/// panel and the player's own bottom bar fought over the same edge. A drawer
/// leaves the video beside it on every screen and grows with the height of the
/// window. What follows the window is the drawer's *width*, not its anchor —
/// see [PlayerPanelShell.build].
///
/// GLASS. The surface is translucent and the video reads through it. It is
/// still not a [BackdropFilter]: a blur over a platform view is an effect layer
/// the size of the drawer, re-surfaced on every repaint, and the panel's own
/// compositing test caps effect layers at 40 % of the viewport — a television
/// drawer is 44 %. Everything here is paint into the layer the panel is already
/// in: a translucent fill, a gloss gradient and a hairline down the edge that
/// faces the video. The old panel stacked five real layers — a blur, two
/// gradients and two ShaderMasks — to arrive at the same picture.
///
/// OVERSCAN. Consumer sets clip roughly 5 % of the picture, and a
/// right-anchored drawer puts the close button and every row's badges exactly
/// there. [PlayerPanelMetrics.drawerEdgeInset] - the app's own
/// `HotstarPlayerStyle.tvEdgeInset` - is what keeps them out of that band.
///
/// It is applied to the drawer's *contents*, never to the drawer. Inset the
/// surface and the panel stops being attached to anything: it floats in the
/// middle of the picture with video down both sides of it, which is what a
/// television used to show. The surface reaches the edge and the reading
/// column sits inside it, which is how every ten-foot interface does this.
library;

import 'package:flutter/material.dart';

import 'player_panel_metrics.dart';
import 'player_panel_row.dart' show kPanelSurface;

/// The panel's surface, as opposed to the transparent box it is aligned in.
/// Public so a test can measure where the panel actually sits.
const Key kPlayerPanelSurfaceKey = Key('player-panel-surface');

/// Below this the drawer is sized as a fraction of the window rather than of
/// the room left beside it.
///
/// Width alone, not orientation or platform: a phone in landscape, a small
/// tablet and a half-width desktop window all want the same answer, and only
/// the width tells them apart.
const double kPanelCompactWidth = 620;

/// How far the panel travels on its way in. Always from the right, because the
/// drawer is always anchored there.
const Offset kPanelSlideFrom = Offset(1, 0);

/// How wide the drawer is in a window of [size], once [metrics] has said which
/// ramp it is on.
///
/// Two regimes, and the narrow one is why this is a function rather than one
/// expression. Above [kPanelCompactWidth] the drawer takes 34 % of the room
/// left beside it, floored and capped by the ramp, so a wide window keeps most
/// of its picture. Below it, 34 % of a 390 dp phone is 133 dp — narrower than
/// the floor, so every phone would pin to [PlayerPanelMetrics.drawerMinWidth]
/// and the clamp would be doing all the work with the proportion doing none.
/// A phone gets 80 % of its width instead, which is the shape the panel had
/// when it was drawn for one.
double playerPanelWidthFor(
  Size size,
  PlayerPanelMetrics metrics, {
  required double edgeInset,
}) {
  final available = size.width - edgeInset;
  if (size.width < kPanelCompactWidth) {
    // Floored below the ramp's own minimum on purpose: 260 dp is narrow for a
    // release name, and a 360 dp handset has no 360 dp to give.
    return (available * 0.8).clamp(260.0, 380.0);
  }
  return (available * 0.34).clamp(metrics.drawerMinWidth, metrics.drawerMaxWidth);
}

/// Positions and paints the panel surface. Nothing about tabs or content: this
/// is the container, so its shape can be tested without building any of them.
///
/// Deliberately no [Stack] and no magic-offset [Positioned] — an [Align] over
/// a sized box is the whole layout, and it stays right when the window resizes
/// mid-session, which a hard-coded offset does not.
class PlayerPanelShell extends StatelessWidget {
  const PlayerPanelShell({
    required this.metrics,
    required this.child,
    super.key,
  });

  /// The ramp the drawer is sized on. Passed rather than read from the tree so
  /// this widget has exactly one idea of which form factor it is on — the same
  /// instance `PlayerPanel` installs in the [PlayerPanelMetricsScope] below it.
  final PlayerPanelMetrics metrics;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    // Overscan. Zero on touch and desktop, 48 dp on a television, where the
    // outer ~5 % of the panel is clipped by the set: without this the close
    // button and every row's right-hand badges are the first things to go.
    final edge = metrics.drawerEdgeInset;
    final verticalEdge = metrics.drawerVerticalInset;

    // The surface reaches the edges of the screen; the overscan inset is
    // applied to its *contents* instead. A drawer held off the edge is a
    // drawer floating in the middle of the picture - which is what the inset
    // used to produce on a television, because it was applied to the whole
    // panel rather than to the things inside it that a set would clip.
    //
    // So the surface is the content's width plus the band it has to keep
    // clear, and the reading column is exactly as wide as it was.
    final content = playerPanelWidthFor(size, metrics, edgeInset: edge);

    return Align(
      alignment: Alignment.centerRight,
      // Tight across the drawer's own axis - it is exactly this wide - and
      // unbounded down it, so the drawer is as tall as the window allows.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: content + edge,
          maxWidth: content + edge,
        ),
        child: _PanelSurface(
          // Zero on every ramp but the television's, so this is a layout
          // no-op on a phone, a tablet and a desktop window.
          contentPadding: EdgeInsets.only(
            right: edge,
            top: verticalEdge,
            bottom: verticalEdge,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Translucent glass, with an edge to lift it off the video.
///
/// Every effect here is paint into the layer the panel is already in — a fill,
/// a gradient and a border — so nothing is composited separately over the
/// platform view. See this file's header for why that rules the blur out.
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.contentPadding, required this.child});

  /// The band the surface keeps clear inside itself, so a set that clips the
  /// outer few per cent of the picture takes paint rather than the close
  /// button and every row's right-hand badges. See [PlayerPanelShell.build].
  final EdgeInsets contentPadding;

  final Widget child;

  /// Gloss down the face of the glass: a cool highlight at the top-left corner
  /// falling away to nothing by the middle. The old panel spent a full-size
  /// gradient layer and a radial one on this; as a gradient on the fill it is
  /// free.
  static const LinearGradient _gloss = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0x0AFFFFFF), Color(0x03FFFFFF), Color(0x00FFFFFF)],
    stops: <double>[0.0, 0.4, 1.0],
  );

  /// The drawer's left edge is the one that faces the video, so the rim
  /// highlight goes there. The old panel put it on the right, against the
  /// screen edge, where nothing could see it.
  static const Border _rim = Border(
    left: BorderSide(color: Color(0x1FFFFFFF), width: 0.5),
  );

  /// Only the leading corners round. The other side is flush against the
  /// screen, and a rounded corner there would be a sliver of video in the
  /// corner of a surface that is meant to be attached to the edge.
  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(14),
    bottomLeft: Radius.circular(14),
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: kPlayerPanelSurfaceKey,
      decoration: const BoxDecoration(
        borderRadius: _radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 32,
            offset: Offset(-6, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: _radius,
        // Two decorations rather than one: a [BoxDecoration] carrying both a
        // colour and a gradient paints only the gradient, because the shader
        // replaces the paint's colour outright. Both are paint into the layer
        // this subtree is already in, so the second costs a draw call and no
        // compositing.
        child: DecoratedBox(
          decoration: const BoxDecoration(color: kPanelSurface, border: _rim),
          child: DecoratedBox(
            decoration: const BoxDecoration(gradient: _gloss),
            // Material for the ink the rows and buttons splash into, but
            // transparent: the fill above is the surface, and a second opaque
            // one here would undo the glass.
            child: Material(
              type: MaterialType.transparency,
              // The device's own cutout inset on the far side would
              // phantom-indent a right-anchored drawer, so left is off.
              child: SafeArea(
                left: false,
                top: true,
                child: Padding(padding: contentPadding, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
