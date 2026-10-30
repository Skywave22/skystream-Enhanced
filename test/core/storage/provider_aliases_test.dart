/// The names a person gave their providers: what is stored, and what a stored map that cannot
/// be read leaves behind.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/storage/storage_service.dart';

void main() {
  test('the names of the providers are read back as they were stored', () {
    final raw = jsonEncode({
      'com.example.alpha': 'Alpha TV',
      'com.example.beta': 'Beta',
    });
    expect(StorageService.parseProviderAliases(raw), {
      'com.example.alpha': 'Alpha TV',
      'com.example.beta': 'Beta',
    });
  });

  test('nothing stored is no names', () {
    expect(StorageService.parseProviderAliases(null), isEmpty);
    expect(StorageService.parseProviderAliases(''), isEmpty);
  });

  test('a stored map that cannot be read is no names', () {
    expect(StorageService.parseProviderAliases('{not json'), isEmpty);
    expect(StorageService.parseProviderAliases('["a", "b"]'), isEmpty);
    expect(StorageService.parseProviderAliases('{"a": 1}'), isEmpty);
  });
}
