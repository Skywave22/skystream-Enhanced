import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../player/domain/network_buffer.dart';
import '../../player/domain/playback_recovery.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/stream_quality_sorter.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'player_settings_provider.dart';
import 'widgets/settings_dialogs.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/subtitle_appearance_settings.dart';

/// Sub-screen for configuring all video playback, gestures, display, and quality preferences.
class PlayerSettingsScreen extends ConsumerWidget {
  final bool isEmbedded;

  const PlayerSettingsScreen({super.key, this.isEmbedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final profile = ref.watch(deviceProfileProvider).asData?.value;

    final playerSettings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    // What the read-ahead wish gets converted against: the rendition this
    // device will ask for, and the memory it can spare. Both come off the same
    // profile the player itself uses, so the figure shown here is the figure
    // the player will use.
    final bufferTier = profile?.tier ?? DeviceTier.standard;
    final bufferMaxHeight = adaptiveMaxHeightFor(
      tier: bufferTier,
      panelHeightPx: 0,
      hardwareDecode: hardwareDecodeAvailable(
        platform: defaultTargetPlatform,
        preference: playerSettings.hardwareDecoding,
      ),
    );

    // Whether this device has a touchscreen, which is the only thing the four
    // gesture rows below depend on: a swipe, a drag and a double-tap are the
    // one input that genuinely does not exist on a remote, a keyboard or a
    // mouse, so they are the one control the app is allowed to hide.
    //
    // A hardware fact, therefore, and asked of hardware: the mobile operating
    // systems, minus the leanback boxes and Apple TVs that run them without a
    // touchscreen. `DeviceProfile.isTv` is the single authority for "this is a
    // television"; the geometric guess in `ResponsiveContext` that used to be
    // OR-ed in here called every landscape Android phone a television and took
    // all four rows away while the gestures kept firing underneath them, so
    // the viewer could no longer switch off a gesture that was still happening.
    // Window shape must never reach this decision - the phone in landscape and
    // the phone in portrait are the same phone.
    final platform = Theme.of(context).platform;
    final isTouchDevice =
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        profile?.isTv != true;

    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm,
            ).copyWith(bottom: 100),
            children: [
              SettingsGroup(
                title: l10n.player,
                children: [
                  SettingsTile(
                    icon: Icons.smart_display_rounded,
                    title: l10n.defaultPlayer,
                    subtitle: getPlayerDisplayName(
                      playerSettings.preferredPlayer,
                      l10n,
                    ),
                    onTap: () => showDefaultPlayerDialog(
                      context,
                      ref,
                      playerSettings.preferredPlayer,
                    ),
                  ),
                  if (isTouchDevice) ...[
                    SettingsTile(
                      icon: Icons.swipe_vertical_rounded,
                      title: l10n.leftGesture,
                      subtitle: getGestureLabel(
                        playerSettings.leftGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        true,
                        playerSettings.leftGesture,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.swipe_vertical_rounded,
                      title: l10n.rightGesture,
                      subtitle: getGestureLabel(
                        playerSettings.rightGesture,
                        l10n,
                      ),
                      onTap: () => showGestureDialog(
                        context,
                        ref,
                        false,
                        playerSettings.rightGesture,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.touch_app_rounded,
                      title: l10n.doubleTapToSeek,
                      subtitle: playerSettings.doubleTapEnabled
                          ? l10n.enabled
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.doubleTapEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setDoubleTapEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setDoubleTapEnabled(
                            !playerSettings.doubleTapEnabled,
                          ),
                    ),
                    SettingsTile(
                      icon: Icons.swipe_rounded,
                      title: l10n.swipeToSeek,
                      subtitle: playerSettings.swipeSeekEnabled
                          ? l10n.enabled
                          : l10n.disabled,
                      trailing: Switch(
                        value: playerSettings.swipeSeekEnabled,
                        onChanged: (val) => ref
                            .read(playerSettingsProvider.notifier)
                            .setSwipeSeekEnabled(val),
                      ),
                      onTap: () => ref
                          .read(playerSettingsProvider.notifier)
                          .setSwipeSeekEnabled(
                            !playerSettings.swipeSeekEnabled,
                          ),
                    ),
                  ],
                  SettingsTile(
                    icon: Icons.av_timer_rounded,
                    title: l10n.seekDuration,
                    subtitle: formatSeekDuration(
                      playerSettings.seekDuration,
                      l10n,
                    ),
                    onTap: () => showDurationDialog(
                      context,
                      ref,
                      playerSettings.seekDuration,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.download_for_offline_rounded,
                    title: l10n.networkBuffer,
                    subtitle: formatNetworkBuffer(
                      playerSettings.networkBufferMinutes,
                      prefetchBufferMbFor(
                        minutes: playerSettings.networkBufferMinutes,
                        maxHeight: bufferMaxHeight,
                        tier: bufferTier,
                      ),
                      l10n,
                    ),
                    onTap: () => showNetworkBufferDialog(
                      context,
                      ref,
                      playerSettings.networkBufferMinutes,
                      maxHeight: bufferMaxHeight,
                      tier: bufferTier,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.aspect_ratio_rounded,
                    title: l10n.defaultResizeMode,
                    subtitle: getResizeModeLabel(
                      playerSettings.defaultResizeMode,
                      l10n,
                    ),
                    onTap: () => showResizeDialog(
                      context,
                      ref,
                      playerSettings.defaultResizeMode,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.subtitles_rounded,
                    title: l10n.subtitleDefault,
                    subtitle: subtitleDefaultLabel(
                      playerSettings.subtitleDefault,
                      l10n,
                    ),
                    onTap: () => showSubtitleDefaultDialog(
                      context,
                      ref,
                      playerSettings.subtitleDefault,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.high_quality_rounded,
                    title: l10n.hardwareDecoding,
                    subtitle: playerSettings.hardwareDecoding
                        ? '${l10n.enabled} (${l10n.recommended})'
                        : l10n.disabled,
                    trailing: Switch(
                      value: playerSettings.hardwareDecoding,
                      onChanged: (val) => ref
                          .read(playerSettingsProvider.notifier)
                          .setHardwareDecoding(val),
                    ),
                    onTap: () => ref
                        .read(playerSettingsProvider.notifier)
                        .setHardwareDecoding(!playerSettings.hardwareDecoding),
                  ),
                  SettingsTile(
                    icon: Icons.volume_up_rounded,
                    title: 'Maximum volume',
                    subtitle: playerSettings.maxVolumePercent <= 100
                        ? '100% (no boost)'
                        : '${playerSettings.maxVolumePercent}% — boost enabled',
                    onTap: () =>
                        showMaxVolumeDialog(context, ref, playerSettings),
                  ),
                  // The pair splits on metered vs unmetered, not on Wi-Fi:
                  // Ethernet, a VPN tunnel and no link at all take this one.
                  SettingsTile(
                    icon: Icons.wifi_rounded,
                    title: l10n.unmeteredQualityPreference,
                    subtitle: qualityPreferenceLabel(
                      playerSettings.wifiQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.unmeteredQualityPreference,
                      current: playerSettings.wifiQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setWifiQuality,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.signal_cellular_alt_rounded,
                    title: l10n.mobileQualityPreference,
                    subtitle: qualityPreferenceLabel(
                      playerSettings.mobileQuality,
                      l10n,
                    ),
                    onTap: () => showQualityDialog(
                      context,
                      ref,
                      title: l10n.mobileQualityPreference,
                      current: playerSettings.mobileQuality,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setMobileQuality,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.filter_list_rounded,
                    title: 'Quality Filter Mode',
                    subtitle: _qualityFilterModeLabel(
                      playerSettings.qualityFilterMode,
                    ),
                    onTap: () => showQualityFilterModeDialog(
                      context,
                      ref,
                      current: playerSettings.qualityFilterMode,
                      onChanged: ref
                          .read(playerSettingsProvider.notifier)
                          .setQualityFilterMode,
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.tune_rounded,
                    title: l10n.playerControls,
                    subtitle: l10n.playerControlsSubtitle,
                    isLast: true,
                    onTap: () => showPlayerControlsDialog(context, ref),
                  ),
                ],
              ),
              SubtitleAppearanceGroup(settings: playerSettings),
            ],
          ),
        ),
      ),
    );

    if (isEmbedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: Text(l10n.player),
      ),
      body: content,
    );
  }
}

String _qualityFilterModeLabel(QualityFilterMode mode) {
  switch (mode) {
    case QualityFilterMode.any:
      return 'Show all (sort only)';
    case QualityFilterMode.atOrAbove:
      return 'Hide sources below preference';
    case QualityFilterMode.atOrBelow:
      return 'Hide sources above preference';
  }
}
