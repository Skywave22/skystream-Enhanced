package com.lingjhf.vlc_player

import android.content.Context
import io.flutter.view.TextureRegistry
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * Where libVLC draws.
 *
 * Everything else about a player - audio focus, the becoming-noisy receiver,
 * event emission, track selection - is the same whichever way the frames reach
 * the screen, so the choice is a value the player is handed rather than a
 * second player class. Mirrors `VlcRenderTarget` in the Darwin plugins.
 */
internal sealed interface VlcRenderTarget {
    /**
     * A [VLCVideoLayout] inside a platform view.
     *
     * libVLC decodes into the layout's TextureView and Flutter then composites
     * that view as a texture of its own: two full-frame compositions per frame,
     * a frame of latency, and the platform view's input and focus plumbing.
     */
    class VideoLayout(context: Context) : VlcRenderTarget {
        val layout = VLCVideoLayout(context)
    }

    /**
     * A Flutter-owned surface, drawn as an ordinary `Texture` widget.
     *
     * The decoder writes straight into Flutter's buffer queue, so the video is
     * composited once, with everything else in the frame, and the widget tree
     * owns fit and clipping. Subtitles are blended into the video by libVLC
     * because there is no second surface to put them on.
     */
    class Texture(val producer: TextureRegistry.SurfaceProducer) : VlcRenderTarget
}
