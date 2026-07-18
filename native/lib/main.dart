import 'package:flutter/material.dart';
import 'voice/voice_controller.dart';

void main() => runApp(const HenryApp());

class HenryApp extends StatelessWidget {
  const HenryApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Henry (1a)',
        theme: ThemeData.dark(useMaterial3: true),
        home: const DebugHome(),
      );
}

class DebugHome extends StatefulWidget {
  const DebugHome({super.key});
  @override
  State<DebugHome> createState() => _DebugHomeState();
}

class _DebugHomeState extends State<DebugHome> {
  final _vc = VoiceController();

  @override
  void initState() {
    super.initState();
    _vc.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _vc.removeListener(_onChange);
    _vc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Henry 1a — ${_vc.state.name}')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _vc.connect, child: const Text('Connect')),
              OutlinedButton(onPressed: _vc.disconnect, child: const Text('Disconnect')),
              FilledButton.tonal(
                onPressed: () => _vc.micOn ? _vc.stopMic() : _vc.startMic(),
                child: Text(_vc.micOn ? 'Mic off' : 'Mic on'),
              ),
              // Spike buttons added in Task 7.
            ]),
            const SizedBox(height: 8),
            Text('caption: ${_vc.caption}',
                style: const TextStyle(fontSize: 18, color: Colors.amber)),
            const Divider(),
            const Text('Transcript', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              flex: 2,
              child: ListView(children: _vc.transcript.map(Text.new).toList()),
            ),
            const Divider(),
            const Text('Event log', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              flex: 3,
              child: ListView(
                children: _vc.eventLog.reversed
                    .map((l) => Text(l, style: const TextStyle(fontSize: 12)))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
