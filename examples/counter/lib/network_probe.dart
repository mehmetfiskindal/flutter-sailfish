import 'dart:io';

/// Checks network access. Inside Sailjail the network is off unless the app's desktop entry
/// lists the Internet permission, so this shows whether permissions reached the installed app.
Future<List<String>> runNetworkProbe() async {
  final out = <String>[];

  Future<void> step(String label, Future<String> Function() body) async {
    try {
      out.add('$label: ${await body().timeout(const Duration(seconds: 8))}');
    } catch (e) {
      out.add('$label: FAILED $e');
    }
  }

  await step('DNS example.com', () async {
    final addresses = await InternetAddress.lookup('example.com');
    return addresses.isEmpty ? 'no address' : 'OK ${addresses.first.address}';
  });
  await step('HTTPS example.com', () async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(Uri.parse('https://example.com/'));
      final response = await request.close();
      await response.drain<void>();
      return 'OK HTTP ${response.statusCode}';
    } finally {
      client.close(force: true);
    }
  });
  return out;
}
