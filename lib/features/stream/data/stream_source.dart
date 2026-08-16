import 'package:skystream/core/domain/entity/multimedia_item.dart';

/// A stream link resolved from one installed plugin.
class AggregatedStream {
  final String providerId;
  final String providerName;
  final String itemUrl;
  final String episodeUrl;
  final StreamResult stream;
  final MultimediaItem detailedItem;
  final Episode? episode;

  const AggregatedStream({
    required this.providerId,
    required this.providerName,
    required this.itemUrl,
    required this.episodeUrl,
    required this.stream,
    required this.detailedItem,
    this.episode,
  });

  String get sourceLabel => stream.displaySource;
}
