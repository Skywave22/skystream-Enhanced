import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client_provider.dart';
import '../../../core/services/tmdb_service.dart';
import 'stream_aggregator.dart';

/// Shared TMDB client for source matching. Kept alive so repeated source
/// lookups reuse one Dio-backed service instead of rebuilding per sheet.
final tmdbClientProvider = Provider<TmdbService>((ref) {
  return TmdbService(ref.watch(dioClientProvider));
});

/// Cross-plugin stream aggregator used by the unified sources sheet.
final streamAggregatorProvider = Provider<StreamAggregator>((ref) {
  return StreamAggregator();
});
