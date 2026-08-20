import 'package:flutter/material.dart';

import '../../../core/nuvio/models/nuvio_models.dart';

/// Renders the settings form a Nuvio scraper describes in `onSettings()`.
///
/// Nuvio's `PluginSettingsDialog` supports `header`, `info`, `text`, `select`
/// and `toggle`; this adds `number`. The values are returned as a plain map and
/// stored per scraper, then passed back to the plugin in `SCRAPER_SETTINGS`.
class NuvioScraperSettingsDialog extends StatefulWidget {
  final String scraperName;
  final List<NuvioSettingsField> fields;
  final Map<String, dynamic> initialValues;

  const NuvioScraperSettingsDialog({
    super.key,
    required this.scraperName,
    required this.fields,
    this.initialValues = const {},
  });

  @override
  State<NuvioScraperSettingsDialog> createState() =>
      _NuvioScraperSettingsDialogState();
}

class _NuvioScraperSettingsDialogState
    extends State<NuvioScraperSettingsDialog> {
  late Map<String, dynamic> _values;
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _values = {
      ...NuvioSettingsField.defaults(widget.fields),
      ...widget.initialValues,
    };
    for (final field in widget.fields) {
      if (field.type == 'text' || field.type == 'number') {
        _controllers[field.key] = TextEditingController(
          text: _values[field.key]?.toString() ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AlertDialog(
      title: Text('${widget.scraperName} settings'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final field in widget.fields) ...[
                _buildField(field, theme, cs),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{}),
          child: const Text('Reset'),
        ),
        FilledButton(
          onPressed: () {
            for (final entry in _controllers.entries) {
              final field = widget.fields.firstWhere(
                (f) => f.key == entry.key,
                orElse: () => const NuvioSettingsField(type: 'text'),
              );
              final text = entry.value.text.trim();
              if (text.isEmpty) {
                _values.remove(entry.key);
              } else if (field.type == 'number') {
                _values[entry.key] = num.tryParse(text) ?? text;
              } else {
                _values[entry.key] = text;
              }
            }
            Navigator.pop(context, _values);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildField(
    NuvioSettingsField field,
    ThemeData theme,
    ColorScheme cs,
  ) {
    switch (field.type) {
      case 'header':
        return Text(
          field.label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
        );

      case 'info':
        return Text(
          field.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        );

      case 'toggle':
        final value = _values[field.key] == true;
        return SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: value,
          onChanged: (next) => setState(() => _values[field.key] = next),
          title: Text(field.label, style: theme.textTheme.bodyMedium),
          subtitle: field.description == null
              ? null
              : Text(
                  field.description!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
        );

      case 'select':
        final current =
            _values[field.key]?.toString() ?? field.defaultValue?.toString();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(field.label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue:
                  field.options.any((option) => option.value == current)
                  ? current
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final option in field.options)
                  DropdownMenuItem(
                    value: option.value,
                    child: Text(option.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => setState(() {
                if (value != null) _values[field.key] = value;
              }),
            ),
            if (field.description != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  field.description!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );

      case 'text':
      case 'number':
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(field.label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            TextField(
              controller: _controllers[field.key],
              obscureText: field.isPassword,
              keyboardType: field.type == 'number'
                  ? TextInputType.number
                  : TextInputType.text,
              decoration: InputDecoration(
                hintText: field.placeholder,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (field.description != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  field.description!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
    }
  }
}
