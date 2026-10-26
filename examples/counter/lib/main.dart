import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dbus_probe.dart';
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Normally the flutter tool generates this registration; the Sailfish build does not run it yet.
  PathProviderLinux.registerWith();
  SharedPreferencesLinux.registerWith();
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: CounterPage());
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> with WidgetsBindingObserver {
  int _count = 0;
  AppLifecycleState? _lifecycle;
  final List<String> _history = [];
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    _loadStored();
  }

  // Plugin check: the tap count survives restarts if shared_preferences works on the device.
  String _storage = 'storage: loading...';
  String _dbus = '';

  Future<void> _loadStored() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('count') ?? 0;
      setState(() {
        _count = saved;
        _storage = 'storage OK, restored $saved\n${dir.path}';
      });
    } catch (e) {
      setState(() => _storage = 'storage failed: $e');
    }
  }

  Future<void> _saveCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('count', _count);
    } catch (e) {
      setState(() => _storage = 'save failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _lifecycle = state;
      _history.add(state.name);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Hello, SailfishOS')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              Text('Taps: $_count', style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(labelText: 'Type here', border: OutlineInputBorder()),
                onSubmitted: (v) => setState(() => _history.add('submitted: $v')),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, v, _) => Text('Text: "${v.text}" (${v.text.length} chars)'),
              ),
              const SizedBox(height: 16),
              const TextField(
                maxLines: 3,
                decoration: InputDecoration(labelText: 'Multiline', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              Text(_storage),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  setState(() => _dbus = 'running...');
                  final lines = await runDbusProbe();
                  setState(() => _dbus = lines.join('\n'));
                },
                child: const Text('D-Bus test'),
              ),
              Text(_dbus),
              const SizedBox(height: 16),
              Text('Lifecycle: ${_lifecycle?.name ?? "unknown"}'),
              Text('Events: ${_history.join(", ")}'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            setState(() => _count++);
            _saveCount();
          },
          child: const Icon(Icons.add),
        ),
      );
}
