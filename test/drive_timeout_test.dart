import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:papernote/data/sync/drive_client.dart';

/// A Drive request that never answers must fail rather than hang — a hung
/// request used to wedge the sync engine until the app was restarted.
void main() {
  const short = Duration(milliseconds: 50);

  TimeoutClient client(MockClientStreamHandler handler) => TimeoutClient(
        MockClient.streaming(handler),
        headerTimeout: short,
        idleTimeout: short,
      );

  test('a response that never arrives times out', () async {
    final c = client((_, _) => Completer<http.StreamedResponse>().future);
    await expectLater(c.get(Uri.parse('https://x/')),
        throwsA(isA<TimeoutException>()));
  });

  test('a body that stalls mid-download times out', () async {
    final c = client((_, _) async {
      final body = StreamController<List<int>>();
      body.add([1, 2, 3]); // first chunk, then silence
      return http.StreamedResponse(body.stream, 200);
    });
    await expectLater(c.get(Uri.parse('https://x/')),
        throwsA(isA<TimeoutException>()));
  });

  test('a normal response passes through untouched', () async {
    final c = client((_, _) async => http.StreamedResponse(
        Stream.value('ok'.codeUnits), 201,
        headers: {'x-a': 'b'}));
    final res = await c.get(Uri.parse('https://x/'));
    expect(res.statusCode, 201);
    expect(res.body, 'ok');
    expect(res.headers['x-a'], 'b');
  });
}
