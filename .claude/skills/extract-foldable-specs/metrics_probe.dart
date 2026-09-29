// A throwaway probe: prints what Flutter reports for the current window —
// size, padding, view insets, display features — whenever it changes, and
// once a second, as `METRICS {...}` JSON lines in the log.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

void main() => runApp(const _Probe());

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  Timer? _timer;
  String _last = '';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _report());
  }

  void _report() {
    final view = ui.PlatformDispatcher.instance.views.first;
    final mq = MediaQueryData.fromView(view);
    final line = jsonEncode({
      'size': [mq.size.width, mq.size.height],
      'dpr': mq.devicePixelRatio,
      'physical': [view.physicalSize.width, view.physicalSize.height],
      'padding': [mq.padding.left, mq.padding.top, mq.padding.right, mq.padding.bottom],
      'viewPadding': [mq.viewPadding.left, mq.viewPadding.top, mq.viewPadding.right, mq.viewPadding.bottom],
      'viewInsets': [mq.viewInsets.left, mq.viewInsets.top, mq.viewInsets.right, mq.viewInsets.bottom],
      'gesture': [mq.systemGestureInsets.left, mq.systemGestureInsets.top, mq.systemGestureInsets.right, mq.systemGestureInsets.bottom],
      'features': [
        for (final f in mq.displayFeatures)
          {'type': f.type.name, 'state': f.state.name, 'bounds': [f.bounds.left, f.bounds.top, f.bounds.right, f.bounds.bottom]}
      ],
    });
    if (line != _last) {
      _last = line;
      debugPrint('METRICS $line');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('metrics probe')),
        body: Center(
          child: ElevatedButton(
            onPressed: () => showModalBottomSheet(
              context: context,
              builder: (_) => const Padding(
                padding: EdgeInsets.all(16),
                child: TextField(autofocus: true),
              ),
            ),
            child: const Text('keyboard'),
          ),
        ),
      ),
    );
  }
}
