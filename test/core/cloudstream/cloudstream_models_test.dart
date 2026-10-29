/// CloudStream's repository and plugin records, as saved and read back. Installed plugins are
/// saved with paths relative to CloudStream's folder: on iOS an app update can move the app's
/// container, and an absolute path would then lose every installed plugin.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';

const _repoUrl = 'https://repo.test/repo.json';

CsPluginInfo _plugin() => CsPluginInfo.fromJson({
  'internalName': 'Alpha',
  'name': 'Alpha',
  'url': 'https://repo.test/Alpha.cs3',
  'version': 3,
  'status': 2,
  'authors': ['a'],
  'tvTypes': ['Movie'],
  'language': 'en',
  'iconUrl': 'https://icons.test/alpha?sz=%size%',
  'fileSize': 2048,
}, _repoUrl);

void main() {
  test('a plugin entry reads, with the icon size filled in', () {
    final plugin = _plugin();
    expect(plugin.version, 3);
    expect(plugin.status, 2);
    expect(plugin.iconUrl, 'https://icons.test/alpha?sz=128');
    expect(plugin.repositoryUrl, _repoUrl);
  });

  test('a repository survives saving and reading back', () {
    final repo = CsRepository(url: _repoUrl, name: 'Test', description: 'd', plugins: [_plugin()]);
    final back = CsRepository.fromJson(repo.toJson());
    expect(back.url, _repoUrl);
    expect(back.name, 'Test');
    expect(back.plugins.single.internalName, 'Alpha');
    expect(back.withError('down').error, 'down');
    expect(back.withError('down').plugins, hasLength(1));
  });

  group('installed plugins', () {
    const root = '/var/mobile/Containers/Data/Application/NEW/Library/Application Support/extensions/cloudstream';

    test('are saved relative to CloudStream\'s folder and read back under it', () {
      final installed = CsInstalledPlugin(
        info: _plugin(),
        filePath: '$root/plugins/0a1b2c3d4e/Alpha.cs3',
        providers: const [CsProviderInfo(name: 'Alpha', sections: ['Latest'])],
        extractors: 2,
      );
      final json = installed.toJson(root);
      expect(json['file'], 'plugins/0a1b2c3d4e/Alpha.cs3');
      final back = CsInstalledPlugin.fromJson(json, root);
      expect(back.filePath, '$root/plugins/0a1b2c3d4e/Alpha.cs3');
      expect(back.providers.single.sections, ['Latest']);
      expect(back.extractors, 2);
    });

    test('saved with an absolute path before are found under the current folder', () {
      final json = CsInstalledPlugin(info: _plugin(), filePath: 'x').toJson(root)
        ..remove('file')
        ..['filePath'] =
            '/var/mobile/Containers/Data/Application/OLD/Library/Application Support/extensions/cloudstream/plugins/0a1b2c3d4e/Alpha.cs3';
      expect(CsInstalledPlugin.fromJson(json, root).filePath, '$root/plugins/0a1b2c3d4e/Alpha.cs3');
    });

    test('keep Windows paths working', () {
      const windowsRoot = r'C:\Users\a\AppData\Roaming\skystream\extensions\cloudstream';
      final installed = CsInstalledPlugin(info: _plugin(), filePath: '$windowsRoot\\plugins\\0a\\Alpha.cs3');
      expect(installed.toJson(windowsRoot)['file'], 'plugins/0a/Alpha.cs3');
    });
  });

  group('a repository that writes its fields differently', () {
    test('a plugin still reads', () {
      final plugin = CsPluginInfo.fromJson({
        'name': 'Alpha',
        'url': 'https://repo.test/Alpha.cs3',
        'version': '3',
        'status': '2',
        'fileSize': '2048',
      }, _repoUrl);
      expect(plugin.internalName, 'Alpha');
      expect(plugin.name, 'Alpha');
      expect(plugin.version, 3);
      expect(plugin.status, 2);
      expect(plugin.fileSize, 2048);
    });

    test('a plugin that names itself only after its file is called that', () {
      final plugin = CsPluginInfo.fromJson({'url': 'https://repo.test/Alpha.cs3'}, _repoUrl);
      expect(plugin.internalName, 'Alpha');
      expect(plugin.name, 'Alpha');
    });

    test('a plugin without an address does not read', () {
      expect(() => CsPluginInfo.fromJson({'name': 'Alpha'}, _repoUrl), throwsA(isA<FormatException>()));
      expect(() => CsPluginInfo.fromJson({'name': 'Alpha', 'url': ''}, _repoUrl), throwsA(isA<FormatException>()));
    });

    test('a repository without a name is called after its host', () {
      expect(CsRepository.fromJson({'url': 'https://repo.test/repo.json'}).name, 'repo.test');
    });

    test('a repository without an address does not read', () {
      expect(() => CsRepository.fromJson({'name': 'No url'}), throwsA(isA<FormatException>()));
    });

    test('a repository keeps the plugins that read when one does not', () {
      final repo = CsRepository.fromJson({
        'url': 'https://repo.test/repo.json',
        'plugins': [
          {'name': 'Good', 'url': 'https://repo.test/Good.cs3'},
          {'name': 'No address'},
          {'name': 'Also good', 'url': 'https://repo.test/Also.cs3'},
        ],
      });
      expect(repo.plugins.map((p) => p.name), ['Good', 'Also good']);
    });
  });

  test('an installed plugin keeps whether it has a settings screen, and older records read as unknown', () {
    const info = CsPluginInfo(
      internalName: 'A',
      name: 'A',
      url: 'https://r.test/A.cs3',
      repositoryUrl: 'https://r.test/repo.json',
    );
    const plugin = CsInstalledPlugin(info: info, filePath: '/root/plugins/A.cs3', hasSettings: true);
    final json = plugin.toJson('/root');
    expect(json['hasSettings'], isTrue);
    expect(CsInstalledPlugin.fromJson(json, '/root').hasSettings, isTrue);
    expect(CsInstalledPlugin.fromJson({...json}..remove('hasSettings'), '/root').hasSettings, isNull);
    expect(plugin.withSettings(false).hasSettings, isFalse);
    expect(plugin.withSettings(false).filePath, plugin.filePath);
  });
}
