import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import '../state/device_session.dart';
import 'model_option_field.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Global new-task defaults (PRD 09-28): default collaboration mode,
/// model, and thought level applied to new conversations (and local
/// scheduled sends without their own override). Writes [UiSettings];
/// empty value = follow the desktop's runtime selection, and invalid
/// values are silently dropped at assembly time (sanitizeNewTaskConfig).
class NewTaskDefaultsPage extends StatefulWidget {
  final DeviceSession session;
  const NewTaskDefaultsPage({super.key, required this.session});

  @override
  State<NewTaskDefaultsPage> createState() => _NewTaskDefaultsPageState();
}

class _NewTaskDefaultsPageState extends State<NewTaskDefaultsPage> {
  late final UiSettings _ui =
      context.getInheritedWidgetOfExactType<UiSettingsProvider>()!.settings;

  /// Live mode vocabulary from prepareWorkspace; null (prep unavailable
  /// or optionless) falls back to the four-tier list, same as the chat
  /// draft sheet.
  List<ConfigOptionValue>? _modeOptions;

  @override
  void initState() {
    super.initState();
    // Fire-and-forget; failure keeps the four-tier fallback (the page
    // never blocks on the desktop answering).
    unawaited(widget.session.prepareWorkspace().then((prep) {
      if (mounted) setState(() => _modeOptions = prep.option('mode')?.options);
    }).catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'ntd.title'))),
      body: AnimatedBuilder(
        animation: _ui,
        builder: (context, _) {
          final prepModes = _modeOptions;
          final modeChoices = <(String, String)>[
            ('', tr(context, 'ntd.followDesktop')),
            if (prepModes != null && prepModes.isNotEmpty)
              for (final o in prepModes) (o.value, _modeLabel(context, o))
            else
              for (final v in const ['build', 'edit', 'plan', 'yolo'])
                (v, tr(context, 'chat.mode.$v')),
          ];
          return ListView(
            padding: const EdgeInsets.all(ZSpacing.screen),
            children: [
              _modeCard(context, modeChoices),
              const SizedBox(height: ZSpacing.cardGap),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      ModelOptionField(
                        loadOptions: widget.session.prepareWorkspace,
                        optionId: 'model',
                        labelText: tr(context, 'ntd.model'),
                        noneLabel: tr(context, 'ntd.followDesktop'),
                        value:
                            _ui.newTaskModel.isEmpty ? null : _ui.newTaskModel,
                        onChanged: (v) => _ui.setNewTaskModel(v ?? ''),
                      ),
                      const SizedBox(height: 16),
                      ModelOptionField(
                        loadOptions: widget.session.prepareWorkspace,
                        optionId: 'thought_level',
                        labelText: tr(context, 'ntd.thought'),
                        noneLabel: tr(context, 'ntd.followDesktop'),
                        value: _ui.newTaskThought.isEmpty
                            ? null
                            : _ui.newTaskThought,
                        onChanged: (v) => _ui.setNewTaskThought(v ?? ''),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Desktop's config-options payload carries English-only mode names
  /// ("Full access" for yolo, protocol drift 3.14 notes) — local
  /// `chat.mode.*` entries are the display source; a value outside the
  /// table (drifted vocabulary) falls back to the desktop's own name.
  String _modeLabel(BuildContext context, ConfigOptionValue o) {
    final loc = tr(context, 'chat.mode.${o.value}');
    return loc == 'chat.mode.${o.value}' ? o.name : loc;
  }

  /// Mode picker: prep's mode options win when present (desktop
  /// vocabularies drift, protocol drift 3.12.3), else the four-tier
  /// fallback. Labels reuse the chat sheet's `chat.mode.*` entries; the
  /// cleared choice is "follow the desktop".
  Widget _modeCard(BuildContext context, List<(String, String)> choices) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'ntd.mode'), style: ZType.body),
            RadioGroup<String>(
              groupValue: _ui.newTaskMode,
              onChanged: (v) {
                if (v != null) _ui.setNewTaskMode(v);
              },
              child: Column(
                children: [
                  for (final (v, label) in choices)
                    RadioListTile<String>(
                      value: v,
                      title: Text(label, style: ZType.body),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
