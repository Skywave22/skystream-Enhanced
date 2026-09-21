import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/storage/extension_repository.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/text_input_dialog.dart';
import '../../../core/services/notification_service.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

/// A plugin's own settings, in the app's dialog panel rather than on a route
/// of its own.
///
/// It used to be a full page pushed over the extensions list, which on a
/// television meant losing the list - and the gear button focus was on - to
/// read three switches. The form is unchanged: the same [SettingsGroup] and
/// [SettingsTile] the main Settings screen uses, so it traverses the same way.
/// Width of the panel. Wide enough for a settings row - icon, title, subtitle
/// and a trailing switch - without the subtitle wrapping on every line. The
/// "Add Repository" dialog uses 480 for one text field; a form needs more.
const double _kDialogWidth = 560;

/// Horizontal inset of the content inside that width.
///
/// [SettingsGroup] already insets itself by [LayoutConstants.spacingMd], so
/// this is the remainder that puts its titles on the same 24 dp gutter
/// AlertDialog gives its own title.
const double _kContentInset = 8;

class PluginSettingsDialog extends ConsumerStatefulWidget {
  final ExtensionPlugin plugin;

  const PluginSettingsDialog({super.key, required this.plugin});

  static Future<void> open(BuildContext context, ExtensionPlugin plugin) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.65),
      builder: (_) => PluginSettingsDialog(plugin: plugin),
    );
  }

  @override
  ConsumerState<PluginSettingsDialog> createState() =>
      _PluginSettingsDialogState();
}

class _PluginSettingsDialogState extends ConsumerState<PluginSettingsDialog> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<PluginSettingDefinition> _definitions = const [];
  List<PluginSubProvider> _providers = const [];
  final Map<String, String> _values = {};
  final Map<String, bool> _providerEnabled = {};
  final Map<String, TextEditingController> _controllers = {};
  String _selectedDomain = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final manager = ref.read(extensionManagerProvider.notifier);
      final definitions = await manager.getSettingsForPlugin(widget.plugin);
      final providers = manager.getProvidersForPlugin(widget.plugin);
      final storage = ref.read(extensionRepositoryProvider);
      final settingsRepository = ref.read(settingsRepositoryProvider);
      final savedBaseUrl = settingsRepository.getCustomBaseUrl(
        widget.plugin.packageName,
      );

      for (final controller in _controllers.values) {
        controller.dispose();
      }
      _controllers.clear();
      _values.clear();
      _providerEnabled.clear();

      for (final definition in definitions) {
        String value;
        if (definition.isBaseUrl) {
          value =
              savedBaseUrl ??
              (definition.defaultValue.isNotEmpty
                  ? definition.defaultValue
                  : (widget.plugin.manifest['baseUrl']?.toString() ?? ''));
        } else {
          value =
              storage.getExtensionData(
                '${widget.plugin.packageName}:${definition.key}',
              ) ??
              definition.defaultValue;
        }

        if (definition.type == PluginSettingType.select &&
            definition.options.isNotEmpty &&
            !definition.options.any((option) => option.value == value)) {
          value = definition.options.first.value;
        }

        if (definition.type == PluginSettingType.toggleGroup) {
          value = _normalizedToggleGroupValue(definition, value);
        }

        _values[definition.key] = value;
        if (definition.type == PluginSettingType.text ||
            definition.type == PluginSettingType.url) {
          _controllers[definition.key] = TextEditingController(text: value);
        }
      }

      for (final provider in providers) {
        final saved = storage.getExtensionData(
          '${widget.plugin.packageName}:'
          '_provider_enabled_${provider.id}',
        );
        _providerEnabled[provider.id] = saved == null ? true : saved == 'true';
      }

      final domains = widget.plugin.domains ?? const <PluginDomain>[];
      _selectedDomain =
          savedBaseUrl ??
          (domains.isNotEmpty
              ? domains.first.url
              : (widget.plugin.manifest['baseUrl']?.toString() ?? ''));

      if (!mounted) return;
      setState(() {
        _definitions = definitions;
        _providers = providers;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  bool _boolValue(String key) {
    final value = (_values[key] ?? '').trim().toLowerCase();
    return value == 'true' || value == '1' || value == 'yes' || value == 'on';
  }

  bool _boolFromDynamic(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value == null) return fallback;

    final normalized = value.toString().trim().toLowerCase();
    if (const {'true', '1', 'yes', 'on'}.contains(normalized)) return true;
    if (const {'false', '0', 'no', 'off'}.contains(normalized)) return false;
    return fallback;
  }

  Map<String, bool> _toggleGroupValues(
    PluginSettingDefinition definition, [
    String? rawValue,
  ]) {
    final values = <String, bool>{
      for (final option in definition.options) option.value: option.defaultBool,
    };

    final raw = rawValue ?? _values[definition.key] ?? definition.defaultValue;
    if (raw.trim().isEmpty) return values;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final option in definition.options) {
          values[option.value] = _boolFromDynamic(
            decoded[option.value],
            fallback: option.defaultBool,
          );
        }
      }
    } catch (_) {
      // Invalid or legacy values fall back to each option's default.
    }

    return values;
  }

  String _normalizedToggleGroupValue(
    PluginSettingDefinition definition,
    String rawValue,
  ) {
    return jsonEncode(_toggleGroupValues(definition, rawValue));
  }

  IconData _toggleGroupOptionIcon(PluginSettingOption option) {
    final icon = (option.icon ?? option.value).toLowerCase();

    if (icon.contains('trailer') || icon.contains('video')) {
      return Icons.movie_outlined;
    }
    if (icon.contains('character') || icon.contains('cast')) {
      return Icons.people_outline_rounded;
    }
    if (icon.contains('score') || icon.contains('rating')) {
      return Icons.star_outline_rounded;
    }
    if (icon.contains('year') || icon.contains('date')) {
      return Icons.calendar_today_outlined;
    }
    if (icon.contains('status')) return Icons.sensors_rounded;
    if (icon.contains('duration')) return Icons.timer_outlined;
    if (icon.contains('count')) return Icons.format_list_numbered_rounded;
    if (icon.contains('next') || icon.contains('airing')) {
      return Icons.schedule_rounded;
    }
    if (icon.contains('season')) return Icons.layers_outlined;
    if (icon.contains('banner') || icon.contains('image')) {
      return Icons.image_outlined;
    }
    if (icon.contains('title')) return Icons.title_rounded;
    if (icon.contains('description') || icon.contains('overview')) {
      return Icons.description_outlined;
    }
    if (icon.contains('genre')) return Icons.category_outlined;
    if (icon.contains('studio')) return Icons.business_outlined;
    if (icon.contains('format') || icon.contains('type')) {
      return Icons.movie_filter_outlined;
    }
    if (icon.contains('source')) return Icons.auto_stories_outlined;

    return Icons.tune_rounded;
  }

  String _toggleGroupSummary(PluginSettingDefinition definition) {
    final values = _toggleGroupValues(definition);
    final enabled = values.values.where((value) => value).length;
    final total = definition.options.length;

    if (Localizations.localeOf(context).languageCode == 'ar') {
      return '$enabled من $total مفعّلة';
    }
    return '$enabled of $total enabled';
  }

  Future<void> _showToggleGroupDialog(
    PluginSettingDefinition definition,
  ) async {
    if (_saving || definition.options.isEmpty) return;

    final values = _toggleGroupValues(definition);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              title: Text(definition.title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: definition.options
                      .map((option) {
                        final description = option.description?.trim();

                        return SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          secondary: Icon(_toggleGroupOptionIcon(option)),
                          title: Text(option.label),
                          subtitle: description == null || description.isEmpty
                              ? null
                              : Text(description),
                          value: values[option.value] ?? option.defaultBool,
                          onChanged: (enabled) {
                            values[option.value] = enabled;
                            setDialogState(() {});

                            if (!mounted) return;
                            setState(() {
                              _values[definition.key] = jsonEncode(values);
                            });
                          },
                        );
                      })
                      .toList(growable: false),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(AppLocalizations.of(dialogContext)!.close),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _normalizedUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';

    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
      value = 'https://$value';
    }

    value = value.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);

    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('Enter a valid HTTP or HTTPS URL');
    }

    return uri.origin;
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() => _saving = true);

    try {
      final storage = ref.read(extensionRepositoryProvider);
      final settingsRepository = ref.read(settingsRepositoryProvider);
      final manager = ref.read(extensionManagerProvider.notifier);
      var shouldReload = false;
      final hasScriptBaseUrl = _definitions.any(
        (definition) => definition.isBaseUrl,
      );

      for (final definition in _definitions) {
        var value =
            _controllers[definition.key]?.text ??
            _values[definition.key] ??
            definition.defaultValue;

        if (definition.type == PluginSettingType.url) {
          value = _normalizedUrl(value);
        } else if (definition.type == PluginSettingType.toggleGroup) {
          value = _normalizedToggleGroupValue(definition, value);
        }

        if (definition.isBaseUrl) {
          await settingsRepository.setCustomBaseUrl(
            widget.plugin.packageName,
            value.isEmpty ? null : value,
          );
          shouldReload = true;
        } else {
          await storage.setExtensionData(
            '${widget.plugin.packageName}:${definition.key}',
            value,
          );
          shouldReload = shouldReload || definition.reloadOnChange;
        }

        _values[definition.key] = value;
      }

      if (!hasScriptBaseUrl && (widget.plugin.domains?.isNotEmpty ?? false)) {
        await settingsRepository.setCustomBaseUrl(
          widget.plugin.packageName,
          _selectedDomain.isEmpty ? null : _selectedDomain,
        );
        shouldReload = true;
      }

      for (final provider in _providers) {
        await storage.setExtensionData(
          '${widget.plugin.packageName}:'
          '_provider_enabled_${provider.id}',
          (_providerEnabled[provider.id] ?? true) ? 'true' : 'false',
        );
        shouldReload = true;
      }

      if (shouldReload) {
        await manager.reloadPlugin(widget.plugin);
      }

      if (!mounted) return;
      ref
          .read(notificationServiceProvider)
          .showExtension(
            'Extension settings saved',
            title: widget.plugin.name,
            icon: Icons.extension_rounded,
          );
    } catch (error) {
      if (!mounted) return;
      ref
          .read(notificationServiceProvider)
          .showError(
            'Failed to save settings: $error',
            title: widget.plugin.name,
            icon: Icons.extension_rounded,
          );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  IconData _iconForSetting(PluginSettingDefinition definition) {
    switch (definition.type) {
      case PluginSettingType.toggle:
        return Icons.toggle_on_rounded;
      case PluginSettingType.toggleGroup:
        return Icons.tune_rounded;
      case PluginSettingType.select:
        return Icons.dns_rounded;
      case PluginSettingType.text:
        return Icons.text_fields_rounded;
      case PluginSettingType.url:
        return Icons.link_rounded;
    }
  }

  String _selectedOptionLabel(PluginSettingDefinition definition) {
    final value = _values[definition.key] ?? definition.defaultValue;
    for (final option in definition.options) {
      if (option.value == value) return option.label;
    }
    return value;
  }

  String? _settingSubtitle(PluginSettingDefinition definition) {
    final description = definition.description?.trim();

    final value = switch (definition.type) {
      PluginSettingType.toggle =>
        _boolValue(definition.key) ? 'Enabled' : 'Disabled',
      PluginSettingType.toggleGroup => _toggleGroupSummary(definition),
      PluginSettingType.select => _selectedOptionLabel(definition),
      PluginSettingType.text || PluginSettingType.url =>
        _controllers[definition.key]?.text ??
            _values[definition.key] ??
            definition.defaultValue,
    };

    if (description != null && description.isNotEmpty && value.isNotEmpty) {
      return '$value\n$description';
    }
    if (value.isNotEmpty) return value;
    return description;
  }

  void _setToggleValue(String key, bool value) {
    if (_saving) return;
    setState(() => _values[key] = value ? 'true' : 'false');
  }

  Future<void> _showSelectDialog(PluginSettingDefinition definition) async {
    if (_saving || definition.options.isEmpty) return;

    final current = _values[definition.key] ?? definition.defaultValue;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(definition.title),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value == null || !mounted) return;
            setState(() => _values[definition.key] = value);
            Navigator.of(dialogContext).pop();
          },
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: definition.options
                  .map(
                    (option) => ListTile(
                      title: Text(option.label),
                      leading: Radio<String>(value: option.value),
                      onTap: () {
                        if (!mounted) return;
                        setState(() {
                          _values[definition.key] = option.value;
                        });
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTextDialog(PluginSettingDefinition definition) async {
    if (_saving) return;

    final value = await TextInputDialog.show(
      context,
      title: definition.title,
      // Stored verbatim: the old dialog never trimmed, and a plugin may rely
      // on the exact text - a separator or a deliberate trailing space.
      trim: false,
      initialText:
          _controllers[definition.key]?.text ??
          _values[definition.key] ??
          definition.defaultValue,
      keyboardType: definition.type == PluginSettingType.url
          ? TextInputType.url
          : TextInputType.text,
      hintText: definition.type == PluginSettingType.url
          ? 'https://example.com'
          : null,
      helperText: definition.description,
      confirmLabel: 'Apply',
      allowEmpty: true,
    );

    if (value == null || !mounted) return;
    setState(() {
      _values[definition.key] = value;
      _controllers[definition.key]?.text = value;
    });
  }

  Future<void> _showDomainDialog(List<PluginDomain> domains) async {
    if (_saving || domains.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Website address'),
        content: RadioGroup<String>(
          groupValue: _selectedDomain,
          onChanged: (value) {
            if (value == null || !mounted) return;
            setState(() => _selectedDomain = value);
            Navigator.of(dialogContext).pop();
          },
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: domains
                  .map(
                    (domain) => ListTile(
                      title: Text(domain.name),
                      subtitle: Text(domain.url),
                      leading: Radio<String>(value: domain.url),
                      onTap: () {
                        if (!mounted) return;
                        setState(() => _selectedDomain = domain.url);
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ),
    );
  }

  String _selectedDomainLabel(List<PluginDomain> domains) {
    for (final domain in domains) {
      if (domain.url == _selectedDomain) {
        return '${domain.name}\n${domain.url}';
      }
    }
    return _selectedDomain;
  }

  Widget _buildSettingTile(
    PluginSettingDefinition definition, {
    required bool isLast,
  }) {
    switch (definition.type) {
      case PluginSettingType.toggle:
        final value = _boolValue(definition.key);
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: definition.description,
          trailing: Switch(
            value: value,
            onChanged: _saving
                ? null
                : (next) => _setToggleValue(definition.key, next),
          ),
          onTap: _saving ? null : () => _setToggleValue(definition.key, !value),
          isLast: isLast,
        );

      case PluginSettingType.toggleGroup:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showToggleGroupDialog(definition),
          isLast: isLast,
        );

      case PluginSettingType.select:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showSelectDialog(definition),
          isLast: isLast,
        );

      case PluginSettingType.text:
      case PluginSettingType.url:
        return SettingsTile(
          icon: _iconForSetting(definition),
          title: definition.title,
          subtitle: _settingSubtitle(definition),
          onTap: _saving ? null : () => _showTextDialog(definition),
          isLast: isLast,
        );
    }
  }

  Widget _buildContent(List<PluginDomain> domains, bool hasScriptBaseUrl) {
    // shrinkWrap, because this is a dialog and not a page: an unbounded
    // ListView takes every pixel its parent will give it, which made the
    // panel fill the whole screen and left a page of dead space under seven
    // switches. It still scrolls once the content is taller than the room
    // AlertDialog allows it.
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
        children: [
          if (_definitions.isNotEmpty)
            SettingsGroup(
              filled: false,
              title: 'Extension settings',
              children: List.generate(
                _definitions.length,
                (index) => _buildSettingTile(
                  _definitions[index],
                  isLast: index == _definitions.length - 1,
                ),
              ),
            ),
          if (_definitions.isNotEmpty &&
              ((domains.isNotEmpty && !hasScriptBaseUrl) ||
                  _providers.isNotEmpty))
            const SizedBox(height: LayoutConstants.spacingLg),
          if (domains.isNotEmpty && !hasScriptBaseUrl)
            SettingsGroup(
              filled: false,
              title: 'Website address',
              children: [
                SettingsTile(
                  icon: Icons.language_rounded,
                  title: 'Selected website',
                  subtitle: _selectedDomainLabel(domains),
                  onTap: _saving ? null : () => _showDomainDialog(domains),
                  isLast: true,
                ),
              ],
            ),
          if (domains.isNotEmpty && !hasScriptBaseUrl && _providers.isNotEmpty)
            const SizedBox(height: LayoutConstants.spacingLg),
          if (_providers.isNotEmpty)
            SettingsGroup(
              filled: false,
              title: 'Providers',
              children: List.generate(_providers.length, (index) {
                final provider = _providers[index];
                final enabled = _providerEnabled[provider.id] ?? true;

                return SettingsTile(
                  icon: Icons.extension_rounded,
                  title: provider.name,
                  subtitle: provider.id,
                  trailing: Switch(
                    value: enabled,
                    onChanged: _saving
                        ? null
                        : (value) {
                            setState(() {
                              _providerEnabled[provider.id] = value;
                            });
                          },
                  ),
                  onTap: _saving
                      ? null
                      : () {
                          setState(() {
                            _providerEnabled[provider.id] = !enabled;
                          });
                        },
                  isLast: index == _providers.length - 1,
                );
              }),
            ),
          // No save button here: as a page this was the only way to
          // commit, but a dialog has an action bar and two of them is one
          // too many.
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final domains = widget.plugin.domains ?? const <PluginDomain>[];
    final hasScriptBaseUrl = _definitions.any(
      (definition) => definition.isBaseUrl,
    );
    final hasContent =
        _definitions.isNotEmpty ||
        _providers.isNotEmpty ||
        (domains.isNotEmpty && !hasScriptBaseUrl);

    final theme = Theme.of(context);
    final Widget body;
    if (_loading) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: AppLoadingIndicator(),
        ),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 12),
            CustomButton(
              isPrimary: true,
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else if (!hasContent) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'This extension does not define configurable settings.',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    } else {
      body = _buildContent(domains, hasScriptBaseUrl);
    }

    // The same AlertDialog every other dialog in the app uses - the one "Add
    // Repository" opens - rather than the glass panel the source sheets are
    // drawn in. This is a form, not a source list.
    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.pluginSettings(widget.plugin.name)),
      // 4 down, because the group's own 12 dp of title padding follows it -
      // 16 between the two titles rather than the 36 that a full content
      // inset, a leading spacer and that 12 used to add up to.
      contentPadding: const EdgeInsets.fromLTRB(
        _kContentInset,
        4,
        _kContentInset,
        0,
      ),
      // Less the inset, so [_kDialogWidth] is the width of the PANEL rather
      // than of the box inside it.
      content: SizedBox(width: _kDialogWidth - _kContentInset * 2, child: body),
      actions: [
        CustomButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.close,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 8),
        CustomButton(
          isPrimary: true,
          onPressed: _loading || _saving ? null : _save,
          child: _saving
              ? const AppLoadingIndicator(
                  constraints: BoxConstraints.tightFor(width: 20, height: 20),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
