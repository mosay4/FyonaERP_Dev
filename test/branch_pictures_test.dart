import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/branches/data/branch_pictures.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('branch pictures are kept on the device and follow new versions', () async {
    final docs = await Directory.systemTemp.createTemp('fyona-branch-pics-');
    addTearDown(() => docs.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
    var online = true;
    var served = <int>[1, 2, 3];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (!online) {
            handler.reject(
              DioException.connectionError(
                requestOptions: request,
                reason: 'offline',
              ),
            );
            return;
          }
          handler.resolve(
            Response(requestOptions: request, data: served, statusCode: 200),
          );
        },
      ),
    );
    final rows = [
      {'id': 'b1', 'image': 'https://pics.example/b1.jpg', 'image_version': '1'},
      {'id': 'b2', 'image': null},
    ];
    expect(await BranchPictures.sync(dio, rows, public: dio), isTrue);
    var paths = await BranchPictures.paths();
    expect(paths.keys, ['b1']);
    expect(await File(paths['b1']!).readAsBytes(), [1, 2, 3]);

    // Offline (and after a restart): the copy is still there, no request.
    online = false;
    expect(await BranchPictures.sync(dio, rows, public: dio), isFalse);
    expect((await BranchPictures.paths())['b1'], paths['b1']);

    // The owner changed the picture: the new version replaces the copy.
    online = true;
    served = [9, 9];
    expect(
      await BranchPictures.sync(dio, [
        {'id': 'b1', 'image': 'https://pics.example/b1.jpg', 'image_version': '2'},
      ], public: dio),
      isTrue,
    );
    paths = await BranchPictures.paths();
    expect(await File(paths['b1']!).readAsBytes(), [9, 9]);
    expect(
      docs.listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.img'),
      ),
      hasLength(1),
    );

    // A picture set on this device (offline) is stored the same way.
    final local = File('${docs.path}/branch_b3.img')..writeAsBytesSync([7]);
    expect(
      await BranchPictures.sync(dio, [
        {'id': 'b3', 'image': 'local://${local.path}'},
      ], public: dio),
      isTrue,
    );
    expect(await File((await BranchPictures.paths())['b3']!).readAsBytes(), [7]);
  });
}
