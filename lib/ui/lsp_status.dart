import 'dart:async';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'downloads.dart';

/// "TS: ready / starting / not responding…" in the editor's status line, so a
/// missing or killed TypeScript server is visible. Tap it for what to do.
class LspStatusLabel extends StatefulWidget {
  final CodeForgeController controller;
  final bool lspEnabled;
  final bool serverInstalled;
  final Color color;

  const LspStatusLabel({
    super.key,
    required this.controller,
    required this.lspEnabled,
    required this.serverInstalled,
    required this.color,
  });

  @override
  State<LspStatusLabel> createState() => _LspStatusLabelState();
}

enum _Status { off, notInstalled, notRunning, starting, ready, problem }

class _LspStatusLabelState extends State<LspStatusLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // isInitialized has no notifier; checking every 2 s is cheap.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  _Status get _status {
    final config = widget.controller.lspConfig;
    if (!widget.lspEnabled) return _Status.off;
    if (!widget.serverInstalled) return _Status.notInstalled;
    if (config == null) return _Status.notRunning;
    if (config.problem.value != null) return _Status.problem;
    if (!config.isInitialized) return _Status.starting;
    return _Status.ready;
  }

  String _label(_Status status) => switch (status) {
    _Status.off => 'TS: off',
    _Status.notInstalled => 'TS: not installed',
    _Status.notRunning => 'TS: not running',
    _Status.starting => 'TS: starting…',
    _Status.ready => 'TS: ready',
    _Status.problem => 'TS: ${widget.controller.lspConfig?.problem.value}',
  };

  void _explain(_Status status) {
    final message = switch (status) {
      _Status.off => 'Language servers are turned off in Settings. Suggestions from the editor still work.',
      _Status.notInstalled => 'The TypeScript server needs Node.js and vscode-langservers-extracted. Install them in Downloads. Suggestions from the editor still work meanwhile.',
      _Status.starting => 'The TypeScript server is starting. On a 4 GB phone this can take a little while.',
      _Status.ready => 'The TypeScript server is running: members, types, auto-imports and hints are on.',
      _Status.notRunning => 'The TypeScript server did not start for this project. Close and reopen the project to try again. Suggestions from the editor keep working.',
      _Status.problem
          when (widget.controller.lspConfig?.problem.value ?? '').startsWith(
            'stopped',
          ) =>
        'The TypeScript server quit with an error. Copy the details below and send them so it can be fixed. Suggestions from the editor keep working.',
      _Status.problem => 'The TypeScript server is not answering (Android may have paused it to free memory). Close and reopen the project to start it again. Suggestions from the editor keep working.',
    };
    final details =
        widget.controller.lspConfig?.recentServerOutput.trim() ?? '';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_label(status)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Details',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  details,
                  style: const TextStyle(
                    fontFamily: 'jetBrainsMono',
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (details.isNotEmpty)
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: '${_label(status)}\n$details'),
              ),
              child: const Text('Copy details'),
            ),
          if (status == _Status.notInstalled)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadManager()),
                );
              },
              child: const Text('Open Downloads'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final warn = status != _Status.ready && status != _Status.starting;
    return InkWell(
      onTap: () => _explain(status),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          _label(status),
          style: TextStyle(
            fontSize: 11,
            color: warn ? const Color(0xFFF1B467) : widget.color,
          ),
        ),
      ),
    );
  }
}
