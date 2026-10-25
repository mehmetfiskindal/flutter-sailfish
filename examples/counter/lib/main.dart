import 'package:flutter/material.dart';

void main() => runApp(const CounterApp());

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
              Text('Lifecycle: ${_lifecycle?.name ?? "unknown"}'),
              Text('Events: ${_history.join(", ")}'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => setState(() => _count++),
          child: const Icon(Icons.add),
        ),
      );
}
