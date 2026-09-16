import 'package:flutter/material.dart';

import '../ui_settings.dart';

/// Localized device name for every display surface.
///
/// Devices are persisted with an EMPTY label when the user never named them
/// (the old behaviour baked the Chinese '未命名设备' into storage, which then
/// leaked into the en UI). Storage stays language-neutral; the fallback text
/// is applied here, at render time.
String deviceDisplayName(BuildContext context, String label) =>
    label.isEmpty ? tr(context, 'devices.unnamed') : label;
