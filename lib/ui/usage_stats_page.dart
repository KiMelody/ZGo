import 'package:flutter/material.dart';

import '../state/device_store.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Purely local usage statistics: device count, per-device open counts
/// and recency. Nothing leaves the device.
class UsageStatsPage extends StatefulWidget {
  final DeviceStore store;
  final UiSettings ui;
  const UsageStatsPage({super.key, required this.store, required this.ui});

  @override
  State<UsageStatsPage> createState() => _UsageStatsPageState();
}

class _UsageStatsPageState extends State<UsageStatsPage> {
  @override
  void initState() {
    super.initState();
    widget.store.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'usage.title'))),
      body: AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) {
          final devices = widget.store.devices;
          final totalOpens =
              devices.fold<int>(0, (sum, d) => sum + d.useCount);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _summaryCard(
                      context,
                      tr(context, 'usage.summary.devices'),
                      '${devices.length}',
                      Icons.devices_outlined,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _summaryCard(
                      context,
                      tr(context, 'usage.summary.opens'),
                      '$totalOpens',
                      Icons.touch_app_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(tr(context, 'usage.perDevice'),
                    style: ZType.sub.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ZInk.muted(context),
                    )),
              ),
              for (final d in devices) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.label,
                                  style: ZType.bodyStrong,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Text(
                                d.lastUsedAt != null
                                    ? trP(context, 'devices.lastUsed', [
                                        relativeTime(context, d.lastUsedAt!)
                                      ])
                                    : tr(context, 'usage.neverUsed'),
                                style: ZType.sub.copyWith(
                                    color: ZInk.muted(context),
                                ),
                              ),
                              Text(
                                trP(context, 'usage.addedAt', [
                                  relativeTime(context, d.addedAt)
                                ]),
                                style: ZType.caption.copyWith(
                                    color: ZInk.ghost(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          trP(context, 'usage.opens', ['${d.useCount}']),
                          style: ZType.bodyStrong.copyWith(
                              color: ZColors.sky500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard(
      BuildContext context, String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZSpacing.card),
        child: Row(
          children: [
            Icon(icon, size: 20, color: ZColors.sky500),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style:
                        ZType.display.copyWith(color: ZInk.solid(context))),
                Text(label,
                    style:
                        ZType.caption.copyWith(color: ZInk.muted(context))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
