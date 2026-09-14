package com.lingjhf.vlc_player

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.Surface
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.MediaPlayer.ScaleType
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.interfaces.IVLCVout
import org.videolan.libvlc.util.VLCVideoLayout

/**
 * One libVLC player and everything that hangs off it.
 *
 * Implements [PlatformView] for the [VlcRenderTarget.VideoLayout] target; a
 * [VlcRenderTarget.Texture] player is never registered as a platform view and
 * the engine never asks it for one. The name predates the texture target and
 * is kept so the Darwin plugins and this one read the same.
 */
internal class VlcPlayerPlatformView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewIdentifier: Long,
    options: ArrayList<String>,
    fit: String,
    private val target: VlcRenderTarget,
    private val onDispose: (Long, VlcPlayerPlatformView) -> Unit,
) : PlatformView, MediaPlayer.EventListener {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val videoLayout: VLCVideoLayout? = (target as? VlcRenderTarget.VideoLayout)?.layout
    private val libVLC = LibVLC(context, options)
    private val mediaPlayer = MediaPlayer(libVLC)
    private var videoScale = scaleTypeFor(fit)
    private val eventChannel = EventChannel(messenger, "vlc_player/events/$viewIdentifier")
    private val streamHandler = StreamHandler()
    private val viewId = viewIdentifier
    private val attachStateListener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) {
            scheduleAttachViews()
        }

        override fun onViewDetachedFromWindow(view: View) {
            releaseViews()
        }
    }
    private val layoutChangeListener = object : View.OnLayoutChangeListener {
        override fun onLayoutChange(
            view: View,
            left: Int,
            top: Int,
            right: Int,
            bottom: Int,
            oldLeft: Int,
            oldTop: Int,
            oldRight: Int,
            oldBottom: Int,
        ) {
            if (
                left != oldLeft ||
                top != oldTop ||
                right != oldRight ||
                bottom != oldBottom
            ) {
                scheduleAttachViews()
            }
        }
    }
    private val surfaceCallback = object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
            // The engine has rebuilt the ImageReader behind the texture, so the
            // surface libVLC last drew into is gone for good; getSurface() now
            // hands out the replacement.
            attachViewsIfNeeded()
        }

        override fun onSurfaceCleanup() {
            // Synchronous on purpose: the engine closes the ImageReader the
            // moment this returns, and a decoder still queueing into it would
            // start failing dequeues.
            releaseViews()
        }
    }
    private val videoLayoutListener = IVLCVout.OnNewVideoLayoutListener {
        _, width, height, visibleWidth, visibleHeight, _, _ ->
        onNewVideoLayout(
            if (visibleWidth > 0) visibleWidth else width,
            if (visibleHeight > 0) visibleHeight else height,
        )
    }
    private val voutCallback = object : IVLCVout.Callback {
        override fun onSurfacesCreated(vlcVout: IVLCVout) {
            if (disposed) {
                return
            }
            viewsAttached = true
            mediaPlayer.setVideoScale(videoScale)
            sendSnapshot()
        }

        override fun onSurfacesDestroyed(vlcVout: IVLCVout) {
            viewsAttached = false
            if (disposed || detachingViews) {
                return
            }
            mainHandler.post {
                if (!disposed) {
                    releaseViews()
                    scheduleAttachViews()
                }
            }
        }
    }

    private val audioFocusListener = object : VlcAudioFocusManager.Listener {
        override fun onAudioFocusPause(transient: Boolean) {
            interruptPlayback(
                if (transient) INTERRUPTION_FOCUS_LOST_TRANSIENT else INTERRUPTION_FOCUS_LOST,
            )
        }

        override fun onAudioFocusDuck() {
            if (disposed || !mediaPlayer.isPlaying) {
                return
            }
            // Ducking beats pausing for a navigation prompt: the film keeps
            // running and the prompt is audible over it. The viewer's own
            // volume is left alone and the attenuation applied underneath, so
            // a volume slider does not jump while the prompt speaks.
            duckFactor = DUCK_FACTOR
            applyVolume()
            interruption = INTERRUPTION_DUCKED
            sendSnapshot()
        }

        override fun onAudioFocusGain() {
            if (disposed || interruption == INTERRUPTION_NONE) {
                return
            }
            restoreDuckedVolume()
            interruption = INTERRUPTION_NONE
            // Reported, not acted on. Whether playback should resume depends on
            // the app lifecycle and the background policy, and both of those
            // live in Dart; resuming from here would start a film in an app
            // the viewer walked away from ten minutes ago.
            sendSnapshot()
        }

        override fun onBecomingNoisy() {
            interruptPlayback(INTERRUPTION_BECAME_NOISY)
        }
    }
    private val audioFocus = VlcAudioFocusManager(context, audioFocusListener)

    private var state = STATE_IDLE
    private var volume = 100
    private var duckFactor = 1.0f
    private var interruption = INTERRUPTION_NONE
    private var playbackSpeed = 1.0f
    private var bufferingProgress: Double? = null
    private var errorCode: String? = null
    private var errorDescription: String? = null
    private var lastSentEvent: Map<String, Any?>? = null
    /// Bumped on every audio or subtitle ESAdded / ESDeleted so a consumer
    /// caching the track lists knows to refetch. Monotonic for the life of
    /// this player.
    private var trackRevision = 0
    private var viewsAttached = false
    private var detachingViews = false
    private var attachViewsPosted = false
    private var disposed = false

    /// The surface libVLC is drawing into on the texture target, and so the
    /// one a snapshot copies from. Null whenever the vout is detached.
    private var attachedSurface: Surface? = null
    private var videoLayoutWidth = 0
    private var videoLayoutHeight = 0

    init {
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                target.layout.setBackgroundColor(Color.BLACK)
                target.layout.addOnAttachStateChangeListener(attachStateListener)
                target.layout.addOnLayoutChangeListener(layoutChangeListener)
            }
            is VlcRenderTarget.Texture -> target.producer.setCallback(surfaceCallback)
        }
        mediaPlayer.setEventListener(this)
        mediaPlayer.vlcVout.addCallback(voutCallback)
        // The view target waits for its layout to reach a window; the texture's
        // surface exists now, and Dart's setSource follows create on the very
        // next message, so the vout has to be in place before that lands.
        if (target is VlcRenderTarget.Texture) {
            attachViewsIfNeeded()
        } else {
            scheduleAttachViews()
        }
        eventChannel.setStreamHandler(streamHandler)
    }

    override fun getView(): View? = videoLayout

    fun setSource(
        uri: String,
        httpHeaders: Map<String, String>,
        mediaOptions: List<String>,
        startPosition: Long,
        autoPlay: Boolean,
        result: MethodChannel.Result,
    ) {
        if (!ensureActive(result)) {
            return
        }

        try {
            val media = Media(libVLC, Uri.parse(uri))
            // HTTP headers are translated to libVLC options in Dart
            // (vlc_http_headers.dart). libVLC 3.x can transmit only
            // User-Agent and Referer; there is no `http-header` option, and
            // emitting one here silently dropped every header.
            mediaOptions.forEach { option ->
                media.addOption(option)
            }
            if (startPosition > 0L) {
                media.addOption(":start-time=${startPosition / 1000.0}")
            }
            mediaPlayer.media = media
            media.release()
            errorCode = null
            errorDescription = null
            lastSentEvent = null
            clearInterruption()
            updateState(STATE_OPENING)
            if (autoPlay && requestAudioFocusToPlay()) {
                mediaPlayer.play()
            }
            result.success(null)
        } catch (error: RuntimeException) {
            errorCode = ERROR_SET_SOURCE_FAILED
            errorDescription = error.message
            updateState(STATE_ERROR)
            result.error(ERROR_SET_SOURCE_FAILED, error.message, null)
        }
    }

    private fun isValidHeader(name: String, value: String): Boolean {
        return name.isNotBlank() &&
            !name.contains('\r') &&
            !name.contains('\n') &&
            !value.contains('\r') &&
            !value.contains('\n')
    }

    fun play(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        clearInterruption()
        if (requestAudioFocusToPlay()) {
            mediaPlayer.play()
        }
        result.success(null)
    }

    fun pause(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        // Focus is kept over a pause on purpose. A viewer who pauses for a
        // moment expects the next press of play to be instant, and handing
        // audio back only to snatch it again interrupts whatever took it.
        clearInterruption()
        mediaPlayer.pause()
        result.success(null)
    }

    fun stop(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        audioFocus.abandon()
        clearInterruption()
        mediaPlayer.stop()
        updateState(STATE_STOPPED)
        result.success(null)
    }

    fun seekTo(milliseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        mediaPlayer.time = milliseconds.coerceAtLeast(0L)
        sendSnapshot()
        result.success(null)
    }

    fun setVolume(volume: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        this.volume = volume.coerceIn(0, 200)
        applyVolume()
        sendSnapshot()
        result.success(null)
    }

    fun setPlaybackSpeed(speed: Float, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!speed.isFinite() || speed <= 0.0f) {
            result.error("invalid_args", "A finite positive playback speed is required.", null)
            return
        }
        playbackSpeed = speed
        mediaPlayer.rate = playbackSpeed
        sendSnapshot()
        result.success(null)
    }

    fun setAudioDelay(microseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setAudioDelay(microseconds)) {
            result.error("vlc_error", "VLC failed to set audio delay.", null)
            return
        }
        sendSnapshot()
        result.success(null)
    }

    fun setSubtitleDelay(microseconds: Long, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setSpuDelay(microseconds)) {
            result.error("vlc_error", "VLC failed to set subtitle delay.", null)
            return
        }
        sendSnapshot()
        result.success(null)
    }

    fun takeSnapshot(width: Int, height: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        when (target) {
            is VlcRenderTarget.VideoLayout -> snapshotWindow(target.layout, width, height, result)
            is VlcRenderTarget.Texture -> snapshotSurface(width, height, result)
        }
    }

    private fun snapshotWindow(
        videoLayout: VLCVideoLayout,
        width: Int,
        height: Int,
        result: MethodChannel.Result,
    ) {
        val activity = activityFrom(context)
        if (activity == null) {
            result.error("snapshot_failed", "Unable to locate the Android activity window.", null)
            return
        }
        if (videoLayout.width <= 0 || videoLayout.height <= 0) {
            result.error("snapshot_failed", "The video view has no rendered size.", null)
            return
        }

        val location = IntArray(2)
        videoLayout.getLocationInWindow(location)
        val sourceRect = Rect(
            location[0],
            location[1],
            location[0] + videoLayout.width,
            location[1] + videoLayout.height,
        )
        val snapshotWidth = if (width > 0) width else videoLayout.width
        val snapshotHeight = if (height > 0) height else videoLayout.height
        val bitmap = Bitmap.createBitmap(snapshotWidth, snapshotHeight, Bitmap.Config.ARGB_8888)

        PixelCopy.request(activity.window, sourceRect, bitmap, { copyResult ->
            deliverSnapshot(copyResult, bitmap, result)
        }, mainHandler)
    }

    /// Copies the last buffer libVLC queued to the texture's surface.
    ///
    /// There is no window region to copy on this target: the frame belongs to
    /// Flutter's compositor, not to a View. Reading the surface's last queued
    /// buffer also means the copy is the decoder's output as libVLC left it -
    /// the widget's fit is not applied and nothing drawn over the video is in
    /// it, which is the better snapshot anyway.
    private fun snapshotSurface(width: Int, height: Int, result: MethodChannel.Result) {
        val surface = attachedSurface
        val track = mediaPlayer.currentVideoTrack
        if (surface == null || !surface.isValid || track == null || track.width <= 0 || track.height <= 0) {
            result.error("snapshot_failed", "The video has no rendered frame.", null)
            return
        }
        val snapshotWidth = if (width > 0) width else track.width
        val snapshotHeight = if (height > 0) height else track.height
        val bitmap = Bitmap.createBitmap(snapshotWidth, snapshotHeight, Bitmap.Config.ARGB_8888)

        PixelCopy.request(surface, bitmap, { copyResult ->
            deliverSnapshot(copyResult, bitmap, result)
        }, mainHandler)
    }

    private fun deliverSnapshot(copyResult: Int, bitmap: Bitmap, result: MethodChannel.Result) {
        if (copyResult != PixelCopy.SUCCESS) {
            bitmap.recycle()
            result.error("snapshot_failed", "Android PixelCopy failed with code $copyResult.", null)
            return
        }
        val output = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
            bitmap.recycle()
            result.error("snapshot_failed", "Android failed to encode the snapshot PNG.", null)
            return
        }
        bitmap.recycle()
        result.success(output.toByteArray())
    }

    fun getAudioTracks(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        result.success(trackDescriptions(mediaPlayer.audioTracks))
    }

    fun setAudioTrack(id: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setAudioTrack(id)) {
            result.error("track_not_found", "Audio track $id was not found.", null)
            return
        }
        // ESSelected will follow, but the caller is waiting on this value now.
        sendSnapshot(force = true)
        result.success(null)
    }

    fun getSubtitleTracks(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        result.success(trackDescriptions(mediaPlayer.spuTracks))
    }

    fun setSubtitleTrack(id: Int, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.setSpuTrack(id)) {
            result.error("track_not_found", "Subtitle track $id was not found.", null)
            return
        }
        sendSnapshot(force = true)
        result.success(null)
    }

    fun disableSubtitle(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        mediaPlayer.setSpuTrack(-1)
        sendSnapshot(force = true)
        result.success(null)
    }

    fun addSubtitle(uri: String, result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }
        if (!mediaPlayer.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(uri), true)) {
            result.error("add_subtitle_failed", "Failed to add subtitle: $uri", null)
            return
        }
        // Unlike setAudioTrack / setSpuTrack above, this one cannot report its
        // own result: libVLC 3 posts an added slave to the input thread, so
        // addSlave returning true only means it was accepted and this snapshot
        // still carries the pre-add spuTracks. It is forced to keep the rest of
        // the payload fresh, not to announce the subtitle. The text-stream
        // MediaPlayer.Event.ESAdded is what bumps trackRevision once the track
        // really exists, and that revision - not this result - is the signal a
        // caller has to wait on.
        sendSnapshot(force = true)
        result.success(null)
    }

    fun getMediaInfo(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }

        val media = mediaPlayer.media
        if (media == null) {
            result.success(emptyMediaInfo())
            return
        }
        result.success(mediaInfo(media, mediaPlayer.length))
    }

    fun getMediaStats(result: MethodChannel.Result) {
        if (!ensureActive(result)) {
            return
        }

        result.success(mediaStats(mediaPlayer.media?.getStats()))
    }

    private fun mediaInfo(media: IMedia, playerLength: Long): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["title"] = media.getMeta(IMedia.Meta.Title)
        info["artist"] = media.getMeta(IMedia.Meta.Artist)
        info["album"] = media.getMeta(IMedia.Meta.Album)
        info["duration"] = maxOf(media.duration, playerLength, 0L)

        val videoTracks = ArrayList<Map<String, Any?>>()
        val audioTracks = ArrayList<Map<String, Any?>>()
        val subtitleTracks = ArrayList<Map<String, Any?>>()
        for (index in 0 until media.trackCount) {
            val track = media.getTrack(index) ?: continue
            val trackInfo = mediaTrackInfo(track)
            when (track.type) {
                IMedia.Track.Type.Video -> videoTracks.add(trackInfo)
                IMedia.Track.Type.Audio -> audioTracks.add(trackInfo)
                IMedia.Track.Type.Text -> subtitleTracks.add(trackInfo)
            }
        }
        info["videoTracks"] = videoTracks
        info["audioTracks"] = audioTracks
        info["subtitleTracks"] = subtitleTracks
        return info
    }

    override fun onFlutterViewAttached(flutterView: View) {
        if (!disposed) {
            scheduleAttachViews()
        }
    }

    override fun onFlutterViewDetached() {
        detachViewsIfNeeded()
    }

    override fun dispose() {
        if (disposed) {
            return
        }
        disposed = true
        audioFocus.dispose()
        eventChannel.setStreamHandler(null)
        mediaPlayer.setEventListener(null)
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                target.layout.removeOnAttachStateChangeListener(attachStateListener)
                target.layout.removeOnLayoutChangeListener(layoutChangeListener)
            }
            is VlcRenderTarget.Texture -> target.producer.setCallback(null)
        }
        mediaPlayer.vlcVout.removeCallback(voutCallback)
        mediaPlayer.stop()
        releaseViews()
        // Producer between the vout and the player: releasing it closes the
        // ImageReader behind the surface, so libVLC has to have let go of that
        // surface first (releaseViews, above) and the player, which no longer
        // has anywhere to draw, goes last.
        if (target is VlcRenderTarget.Texture) {
            target.producer.release()
        }
        mediaPlayer.release()
        libVLC.release()
        onDispose(viewId, this)
    }

    override fun onEvent(event: MediaPlayer.Event) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            handlePlayerEvent(event)
        } else {
            mainHandler.post { handlePlayerEvent(event) }
        }
    }

    private fun handlePlayerEvent(event: MediaPlayer.Event) {
        if (disposed) {
            return
        }

        when (event.type) {
            MediaPlayer.Event.Opening -> {
                bufferingProgress = null
                updateState(STATE_OPENING)
            }
            MediaPlayer.Event.Buffering -> {
                val percent = event.getBuffering().coerceIn(0.0f, 100.0f)
                bufferingProgress = percent.toDouble() / 100.0
                // libVLC emits Buffering CONTINUOUSLY during healthy playback,
                // reaching 100 each time. Mapping every one to STATE_BUFFERING
                // overwrote STATE_PLAYING, so the player never reported that it
                // was playing: the spinner never cleared, the play/pause icon
                // was wrong, and every host feature gated on "playing" -
                // progress, scrobbling, completion, next episode - silently
                // stopped working. Only a partial buffer is a real stall.
                //
                // And only on a player that is actually running. A pause lands
                // while the demuxer is mid-fill, so a trailing Buffering below
                // 100 can arrive after Paused and would overwrite STATE_PAUSED
                // with a spinner over a frame the viewer asked to hold.
                if (mediaPlayer.isPlaying) {
                    updateState(if (percent < 100.0f) STATE_BUFFERING else STATE_PLAYING)
                }
            }
            MediaPlayer.Event.Playing -> {
                bufferingProgress = null
                updateState(STATE_PLAYING)
            }
            MediaPlayer.Event.Paused -> {
                bufferingProgress = null
                updateState(STATE_PAUSED)
            }
            MediaPlayer.Event.Stopped -> {
                bufferingProgress = null
                // Focus is deliberately not abandoned here. Replacing the media
                // on a running player emits Stopped, and this event arrives a
                // main-thread hop later - after setSource has already taken
                // focus for the next item, which this would then throw away.
                // The deliberate stop() abandons on its own.
                updateState(STATE_STOPPED)
            }
            MediaPlayer.Event.EndReached -> {
                bufferingProgress = null
                // Nothing left to play: hold audio no longer, so whatever was
                // ducked or paused behind us can come back on its own. A
                // playlist advancing takes it straight back.
                audioFocus.abandon()
                updateState(STATE_ENDED)
            }
            MediaPlayer.Event.EncounteredError -> {
                bufferingProgress = null
                errorCode = ERROR_PLAYBACK
                errorDescription = "VLC encountered an error while playing the media."
                updateState(STATE_ERROR)
            }
            MediaPlayer.Event.TimeChanged,
            MediaPlayer.Event.PositionChanged,
            MediaPlayer.Event.LengthChanged,
            MediaPlayer.Event.SeekableChanged,
            MediaPlayer.Event.Vout,
            MediaPlayer.Event.ESSelected,
            -> sendSnapshot()
            MediaPlayer.Event.ESAdded,
            MediaPlayer.Event.ESDeleted,
            -> {
                // Only the audio and subtitle lists are published, and libVLC
                // announces the video ES here too. A rendition change or an
                // MPEG-TS PMT update re-announces video on its own, and
                // bumping for that reloads a track list that did not change:
                // the panel blinks to a spinner and the D-pad cursor jumps
                // back to the active row from wherever the viewer had it.
                if (event.esChangedType == IMedia.Track.Type.Audio ||
                    event.esChangedType == IMedia.Track.Type.Text
                ) {
                    trackRevision += 1
                }
                sendSnapshot()
            }
        }
    }

    /// Claims audio focus, and says whether playback may start.
    ///
    /// A refusal is reported as an interruption rather than swallowed: it is
    /// why the play button appeared to do nothing, and it is what tells the
    /// Dart side to resume when the delayed grant lands after the call.
    private fun requestAudioFocusToPlay(): Boolean {
        if (audioFocus.request()) {
            return true
        }
        interruption = INTERRUPTION_FOCUS_LOST_TRANSIENT
        sendSnapshot()
        return false
    }

    /// Pauses for an interruption the viewer did not ask for.
    ///
    /// The pause happens here rather than after a round trip to Dart because
    /// audio focus has to be honoured in the instant it moves - a film that
    /// waits for an event channel talks over the first ring of a phone call.
    private fun interruptPlayback(reason: String) {
        if (disposed) {
            return
        }
        restoreDuckedVolume()
        if (mediaPlayer.isPlaying) {
            interruption = reason
            mediaPlayer.pause()
            updateState(STATE_PAUSED)
            return
        }
        if (interruption != INTERRUPTION_NONE) {
            // Already silent for an earlier interruption. A transient loss that
            // turned permanent is still worth saying, because it withdraws the
            // promise that anything is coming back.
            interruption = reason
            sendSnapshot()
            return
        }
        // Nothing was playing and nothing had interrupted it. Reporting one
        // would make a player the viewer paused themselves look system-paused,
        // and invite a resume they never asked for.
    }

    private fun applyVolume() {
        mediaPlayer.volume = (volume * duckFactor).toInt().coerceIn(0, 200)
    }

    private fun restoreDuckedVolume() {
        if (duckFactor == 1.0f) {
            return
        }
        duckFactor = 1.0f
        applyVolume()
    }

    /// Drops the system's claim, restoring whatever it changed.
    ///
    /// Called from the deliberate-intent entry points: once the viewer has
    /// pressed something, the interruption no longer explains what the player
    /// is doing.
    private fun clearInterruption() {
        restoreDuckedVolume()
        interruption = INTERRUPTION_NONE
    }

    private fun updateState(state: String) {
        this.state = state
        sendSnapshot()
    }

    /// Changes how video is scaled without recreating the player.
    ///
    /// setVideoScale is already a runtime call on MediaPlayer; only the Dart
    /// side forced a rebuild, by folding `fit` into the platform-view key.
    ///
    /// A texture-backed player is fitted in Dart, by the widget that owns the
    /// Texture. setVideoScale is a no-op without a VLCVideoLayout behind it, so
    /// nothing needs guarding here; the value is kept so a later attach of a
    /// view target would still honour it.
    fun setFit(fit: String, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "This player has been disposed.", null)
            return
        }
        videoScale = scaleTypeFor(fit)
        mediaPlayer.setVideoScale(videoScale)
        result.success(null)
    }

    private fun attachViewsIfNeeded() {
        if (disposed || viewsAttached) {
            return
        }
        when (target) {
            is VlcRenderTarget.VideoLayout -> {
                if (!target.layout.isAttachedToWindow) {
                    return
                }
                releaseViews()
                mediaPlayer.attachViews(target.layout, null, false, true)
                mediaPlayer.setVideoScale(videoScale)
            }
            is VlcRenderTarget.Texture -> {
                val surface = target.producer.surface
                if (surface == null || !surface.isValid) {
                    return
                }
                releaseViews()
                val vout = mediaPlayer.vlcVout
                // Video only. There is no second surface for subtitles, so
                // libVLC blends them into the picture; see VlcRenderTarget.
                vout.setVideoSurface(surface, null)
                vout.attachViews(videoLayoutListener)
                attachedSurface = surface
                if (videoLayoutWidth > 0 && videoLayoutHeight > 0) {
                    vout.setWindowSize(videoLayoutWidth, videoLayoutHeight)
                }
            }
        }
        viewsAttached = true
    }

    /// libVLC has opened its display and knows the picture it will draw.
    ///
    /// The window is told it is exactly the visible picture, so libVLC places
    /// the video 1:1 and neither scales nor letterboxes inside the buffer -
    /// fit belongs to the widget. The producer is told the same size so the
    /// ImageReader the engine builds is the video's, not a placeholder.
    ///
    /// What deliberately does NOT happen here is a re-attach. On API 29+ the
    /// engine answers setSize by minting a new ImageReader on the next
    /// getSurface(), and swapping libVLC onto it would go through
    /// MediaPlayer's own surface callback, which disables and re-enables the
    /// video track - a decoder restart and a wait for the next keyframe, at
    /// the first frame of every stream. The buffers MediaCodec queues carry
    /// their own dimensions and crop, which the engine honours
    /// (handlesCropAndRotation), so the surface libVLC already holds keeps
    /// showing the right picture; the resized reader is picked up the next
    /// time the engine recycles the surface anyway.
    private fun onNewVideoLayout(width: Int, height: Int) {
        if (disposed || width <= 0 || height <= 0) {
            return
        }
        val producer = (target as? VlcRenderTarget.Texture)?.producer ?: return
        if (width == videoLayoutWidth && height == videoLayoutHeight) {
            return
        }
        videoLayoutWidth = width
        videoLayoutHeight = height
        producer.setSize(width, height)
        mediaPlayer.vlcVout.setWindowSize(width, height)
        sendSnapshot()
    }

    private fun scheduleAttachViews() {
        if (disposed || attachViewsPosted) {
            return
        }
        attachViewsPosted = true
        mainHandler.post {
            attachViewsPosted = false
            attachViewsIfNeeded()
        }
    }

    private fun detachViewsIfNeeded() {
        releaseViews()
    }

    private fun releaseViews() {
        detachingViews = true
        try {
            // MediaPlayer.detachViews() only releases the VLCVideoLayout helper;
            // a raw surface is let go on the vout itself. Each is a no-op for
            // the target that did not use it.
            mediaPlayer.detachViews()
            mediaPlayer.vlcVout.detachViews()
            attachedSurface = null
            viewsAttached = false
        } finally {
            detachingViews = false
        }
    }

    private fun ensureActive(result: MethodChannel.Result): Boolean {
        if (!disposed) {
            return true
        }
        result.error("disposed", "The vlc_player has been disposed.", null)
        return false
    }

    private fun trackDescriptions(
        tracks: Array<MediaPlayer.TrackDescription>?,
    ): List<Map<String, Any?>> {
        return tracks.orEmpty().map { track ->
            mapOf(
                "id" to track.id,
                "name" to track.name,
                "language" to null,
            )
        }
    }

    private fun emptyMediaInfo(): Map<String, Any?> {
        return mapOf(
            "title" to null,
            "artist" to null,
            "album" to null,
            "duration" to 0L,
            "videoTracks" to emptyList<Map<String, Any?>>(),
            "audioTracks" to emptyList<Map<String, Any?>>(),
            "subtitleTracks" to emptyList<Map<String, Any?>>(),
        )
    }

    private fun mediaStats(stats: IMedia.Stats?): Map<String, Any> {
        return mapOf(
            "available" to (stats != null),
            "readBytes" to (stats?.readBytes ?: 0),
            "inputBitrate" to (stats?.inputBitrate?.toDouble() ?: 0.0),
            "demuxReadBytes" to (stats?.demuxReadBytes ?: 0),
            "demuxBitrate" to (stats?.demuxBitrate?.toDouble() ?: 0.0),
            "demuxCorrupted" to (stats?.demuxCorrupted ?: 0),
            "demuxDiscontinuity" to (stats?.demuxDiscontinuity ?: 0),
            "decodedVideo" to (stats?.decodedVideo ?: 0),
            "decodedAudio" to (stats?.decodedAudio ?: 0),
            "displayedPictures" to (stats?.displayedPictures ?: 0),
            "lostPictures" to (stats?.lostPictures ?: 0),
            "playedAudioBuffers" to (stats?.playedAbuffers ?: 0),
            "lostAudioBuffers" to (stats?.lostAbuffers ?: 0),
            "sentPackets" to (stats?.sentPackets ?: 0),
            "sentBytes" to (stats?.sentBytes ?: 0),
            "sendBitrate" to (stats?.sendBitrate?.toDouble() ?: 0.0),
        )
    }

    private fun mediaTrackInfo(track: IMedia.Track): Map<String, Any?> {
        val info = HashMap<String, Any?>()
        info["type"] = trackTypeName(track.type)
        info["codec"] = track.codec
        info["language"] = track.language
        info["bitrate"] = track.bitrate.takeIf { it > 0 }
        if (track is IMedia.VideoTrack) {
            info["width"] = track.width.takeIf { it > 0 }
            info["height"] = track.height.takeIf { it > 0 }
        }
        if (track is IMedia.AudioTrack) {
            info["channels"] = track.channels.takeIf { it > 0 }
            info["sampleRate"] = track.rate.takeIf { it > 0 }
        }
        return info
    }

    private fun trackTypeName(type: Int): String {
        return when (type) {
            IMedia.Track.Type.Audio -> "audio"
            IMedia.Track.Type.Video -> "video"
            IMedia.Track.Type.Text -> "subtitle"
            else -> "unknown"
        }
    }

    private fun sendSnapshot(force: Boolean = false) {
        if (disposed) {
            return
        }

        val duration = mediaPlayer.length.coerceAtLeast(0L)
        val isSeekable = mediaPlayer.isSeekable
        val event = HashMap<String, Any?>()
        event["state"] = state
        event["position"] = mediaPlayer.time.coerceAtLeast(0L)
        event["duration"] = duration
        event["volume"] = volume
        event["playbackSpeed"] = playbackSpeed.toDouble()
        event["audioDelay"] = mediaPlayer.audioDelay
        event["subtitleDelay"] = mediaPlayer.spuDelay
        // -1 when there is none / subtitles are off; Dart normalises to null.
        event["audioTrack"] = mediaPlayer.audioTrack
        event["subtitleTrack"] = mediaPlayer.spuTrack
        event["trackRevision"] = trackRevision
        event["isReady"] = isReadyState(state)
        event["isSeekable"] = isSeekable
        event["isLive"] = isLiveState(state) && duration == 0L && !isSeekable
        event["interruption"] = interruption
        putVideoShape(event)
        bufferingProgress?.let {
            event["bufferingProgress"] = it
        }
        errorDescription?.let {
            event["errorCode"] = errorCode ?: ERROR_PLAYBACK
            event["errorDescription"] = it
        }
        if (!force && event == lastSentEvent) {
            return
        }
        lastSentEvent = HashMap(event)
        streamHandler.send(event)
    }

    /**
     * Puts the video's stored size and its rotation into the snapshot.
     *
     * One function, and one read of `currentVideoTrack`, because that property
     * walks the media's track array every time it is touched and this runs on
     * every snapshot.
     *
     * `videoSize` stays the *stored* size - the elementary stream's own width
     * and height - because that is what this key means on every other platform
     * and what the layout code expects. The rotation goes beside it rather than
     * being folded into it. A clip shot in portrait on a handset is stored as
     * landscape frames plus a 90 degree matrix, so the two have to be combined
     * to get the shape a viewer sees, and Dart is where that happens: it is the
     * only side of this channel the project's CI runs tests on.
     *
     * Nothing is sent before the first video track exists. `currentVideoTrack`
     * is null while the player is still opening, which is exactly when a shape
     * would be a guess.
     */
    private fun putVideoShape(event: HashMap<String, Any?>) {
        val track = mediaPlayer.currentVideoTrack ?: return
        val width = track.width
        val height = track.height
        if (width <= 0 || height <= 0) {
            return
        }
        event["videoSize"] = mapOf("width" to width, "height" to height)
        event["videoOrientation"] = track.orientation
    }

    private inner class StreamHandler : EventChannel.StreamHandler {
        private var events: EventChannel.EventSink? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            this.events = events
            sendSnapshot(force = true)
        }

        override fun onCancel(arguments: Any?) {
            events = null
        }

        fun send(event: Map<String, Any?>) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                sendOnMainThread(event)
            } else {
                mainHandler.post { sendOnMainThread(event) }
            }
        }

        private fun sendOnMainThread(event: Map<String, Any?>) {
            if (!disposed) {
                events?.success(event)
            }
        }
    }

    private companion object {
        const val STATE_IDLE = "idle"
        const val STATE_OPENING = "opening"
        const val STATE_BUFFERING = "buffering"
        const val STATE_PLAYING = "playing"
        const val STATE_PAUSED = "paused"
        const val STATE_STOPPED = "stopped"
        const val STATE_ENDED = "ended"
        const val STATE_ERROR = "error"
        const val INTERRUPTION_NONE = "none"
        const val INTERRUPTION_FOCUS_LOST = "focusLost"
        const val INTERRUPTION_FOCUS_LOST_TRANSIENT = "focusLostTransient"
        const val INTERRUPTION_DUCKED = "ducked"
        const val INTERRUPTION_BECAME_NOISY = "becameNoisy"

        // Roughly the attenuation a system notification ducks other audio by.
        const val DUCK_FACTOR = 0.3f

        const val ERROR_PLAYBACK = "playback_error"
        const val ERROR_SET_SOURCE_FAILED = "set_source_failed"

        fun scaleTypeFor(fit: String): ScaleType {
            return when (fit) {
                "cover" -> ScaleType.SURFACE_FIT_SCREEN
                "fill" -> ScaleType.SURFACE_FILL
                "none" -> ScaleType.SURFACE_ORIGINAL
                else -> ScaleType.SURFACE_BEST_FIT
            }
        }

        fun activityFrom(context: Context): Activity? {
            var current = context
            while (current is ContextWrapper) {
                if (current is Activity) {
                    return current
                }
                current = current.baseContext
            }
            return null
        }

        fun isReadyState(state: String): Boolean {
            return state == STATE_PLAYING ||
                state == STATE_PAUSED ||
                state == STATE_STOPPED ||
                state == STATE_ENDED
        }

        fun isLiveState(state: String): Boolean {
            // STATE_BUFFERING is deliberately excluded. isLive is derived from
            // `duration == 0 && !isSeekable`, and both are trivially true while
            // VLC is still opening the stream — including buffering made every
            // VOD report isLive for the first frames.
            return state == STATE_PLAYING || state == STATE_PAUSED
        }
    }
}
