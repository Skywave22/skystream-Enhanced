import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/addon_manager.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/addons/models/stremio_addon.dart';
import '../../../core/addons/services/addon_client.dart';
import '../../../core/addons/services/builtin_addons.dart';
import 'addons_screen.dart' show AddonPosterCard;

/// Full-screen, paginated view of a single add-on catalog.
///
/// Stremio catalogs page through an integer `skip` extra (100 per page by
/// convention), so this screen fetches lazily as the grid scrolls instead of
/// pulling everything at once — one page is ~100 posters, which is also what
/// keeps the image cache inside its budget.
class AddonCatalogScreen extends ConsumerStatefulWidget {
  final String addonId;
  final String type;
  final String catalogId;
  final String title;

  const AddonCatalogScreen({
    super.key,
    required this.addonId,
    required this.type,
    required this.catalogId,
    required this.title,
  });

  @override
  ConsumerState<AddonCatalogScreen> createState() => _AddonCatalogScreenState();
}

class _AddonCatalogScreenState extends ConsumerState<AddonCatalogScreen> {
  static const int _pageSize = 100;

  final ScrollController _scrollController = ScrollController();
  final List<AddonMetaPreview> _items = [];

  bool _loading = false;
  bool _exhausted = false;
  String? _error;
  int _skip = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadMore()));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loading || _exhausted) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      unawaited(_loadMore());
    }
  }

  InstalledAddon? _resolveAddon() {
    for (final addon in ref.read(addonManagerProvider).addons) {
      if (addon.id == widget.addonId) return addon;
    }
    if (widget.addonId == BuiltInAddons.cinemeta.id) {
      return BuiltInAddons.cinemeta;
    }
    return null;
  }

  Future<void> _loadMore() async {
    final addon = _resolveAddon();
    if (addon == null) {
      setState(() => _error = 'That add-on is no longer installed.');
      return;
    }
    if (_loading || _exhausted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final page = await ref
          .read(addonClientProvider)
          .catalog(
            addon,
            type: widget.type,
            id: widget.catalogId,
            extra: _skip == 0 ? null : {'skip': '$_skip'},
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;
      setState(() {
        final seen = _items.map((e) => e.id).toSet();
        for (final item in page) {
          if (seen.add(item.id)) _items.add(item);
        }
        _skip += _pageSize;
        _exhausted = page.length < _pageSize;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
        _exhausted = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _items.isEmpty && _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error ?? 'This catalog returned nothing.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                childAspectRatio: 0.55,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: _items.length + (_loading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) {
                  return const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return AddonPosterCard(
                  item: _items[index],
                  addonId: widget.addonId,
                  width: double.infinity,
                );
              },
            ),
    );
  }
}
