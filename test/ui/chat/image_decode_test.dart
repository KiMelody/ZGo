import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zgo/protocol/conversation.dart';
import 'package:zgo/ui/chat/chat_page.dart';
import 'package:zgo/ui/chat/image_viewer_page.dart';
import 'package:zgo/ui/chat/markdown_view.dart';
import 'package:zgo/ui/theme.dart';
import 'package:zgo/ui/ui_settings.dart';

import '../../helpers/chat_role_fakes.dart';

/// 32x32 PNG — a real hit box (tap lands inside the InkWell) and a valid
/// decode target.
final Uint8List kPng32 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nO3NQQkAAAgE'
    'sItqJCMZzRQ+hMH+S/WcikAgEAgEAoFAIPgSLPH0wFuCZjkoAAAAAElFTkSuQmCC');

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: child),
    );

/// Attachment bytes through the conversation transport (the attachment
/// bubble loads via `attachmentRead`, not the gateway's file preview port).
class _AttachmentTransport extends RecordingConversationTransport {
  _AttachmentTransport() : super((_, __) {}, () => false);

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async =>
      (bytes: kPng32, mediaType: 'image/png');
}

class _AttachmentGateway extends FakeChatGateway {
  @override
  ConversationTransport get conversationCommands => _AttachmentTransport();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decode size (任务 11-19 图片减负)', () {
    testWidgets('attachment bubble decodes at 220dp × dpr', (tester) async {
      final gateway = _AttachmentGateway();
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {
          'rowId': 1,
          'kind': 'userInput',
          'text': '看图',
          'attachments': [
            {'ref': 'r1', 'fileName': 'shot.png', 'mime': 'image/png'},
          ],
        },
      ]);
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image).first);
      final provider = image.image as ResizeImage;
      final dpr = tester.view.devicePixelRatio;
      expect((provider.width! / dpr).round(), 220,
          reason: 'decoded width follows the 220dp bubble, not the file');
    });

    testWidgets('markdown image decodes at the laid-out width × dpr',
        (tester) async {
      await tester.pumpWidget(
        wrap(SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: AppMarkdown(
              '![pic](C:/w/pic.png)',
              imageResolver: (_) async => kPng32,
            ),
          ),
        )),
      );
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      final dpr = tester.view.devicePixelRatio;
      expect((provider.width! / dpr).round(), 300,
          reason: 'full-width markdown image decodes at its column width');
    });
  });

  group('node_repl base64 reuse', () {
    testWidgets('the inline image and the viewer share one decoded buffer',
        (tester) async {
      final gateway = FakeChatGateway();
      final b64 = base64Encode(kPng32);
      await tester.pumpWidget(
        wrap(ChatPage(host: gateway, sessionId: 's1', title: 't')),
      );
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '画图'},
        {
          'rowId': 2,
          'kind': 'toolCall',
          'toolName': 'NodeREPL',
          'status': 'success',
          'display': {
            'kind': 'node_repl_images',
            'images': [
              {'base64': b64},
            ],
          },
        },
      ]);
      await tester.pumpAndSettle();

      // Images live inside the collapsed tool tile: expand first.
      await tester.tap(find.byType(ExpansionTile).first);
      await tester.pumpAndSettle();

      final inline =
          (tester.widget<Image>(find.byType(Image).first).image as MemoryImage)
              .bytes;
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      final viewer = tester.widget<ImageViewerPage>(
        find.byType(ImageViewerPage),
      );
      expect(identical(viewer.bytes, inline), isTrue,
          reason: 'the tap reuses the row state cache — a second '
              'base64Decode produced a different buffer identity');
    });
  });
}
