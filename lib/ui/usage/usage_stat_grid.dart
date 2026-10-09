import 'package:flutter/material.dart';

import '../theme.dart';

/// Stat value/label grid shared by the app-usage summary cards and the
/// coding-plan activity card (official `s7` / `Bwn` form: value on top,
/// label below). 3 columns per row on wide surfaces, 2 on phones.
class UsageStatGrid extends StatelessWidget {
  final List<(String value, String label)> items;

  const UsageStatGrid({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 600 ? 3 : 2;
      final rows = (items.length + columns - 1) ~/ columns;
      return Column(
        children: [
          for (var r = 0; r < rows; r++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < columns; c++)
                    Expanded(
                      child: r * columns + c < items.length
                          ? _cell(context, items[r * columns + c])
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _cell(BuildContext context, (String value, String label) item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.$1, style: ZType.title),
        const SizedBox(height: 2),
        Text(
          item.$2,
          style: ZType.sub.copyWith(color: ZInk.muted(context)),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
