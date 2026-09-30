import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';
import 'ui_settings.dart';

/// Links shown on the about page. Legal pages have zh / en variants picked
/// by the in-app language.
const _kGithubUrl = 'https://github.com/opensymph/ZLinker';
const _kPrivacyUrlZh = 'https://privacy.songsong.org/';
const _kPrivacyUrlEn = 'https://privacy.songsong.org/en.html';
const _kTosUrlZh = 'https://privacy.songsong.org/tos.html';
const _kTosUrlEn = 'https://privacy.songsong.org/tos-en.html';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  String _build = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _build = info.buildNumber;
      });
    } catch (_) {
      // Version display is best-effort.
    }
  }

  Future<void> _launch(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final en =
        UiSettingsProvider.of(context)?.locale.startsWith('en') ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'settings.about'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const SizedBox(height: 24),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset(
                'assets/icon/icon.png',
                width: 72,
                height: 72,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'ZLinker',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: ZInk.solid(context),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _version.isEmpty
                  ? ''
                  : '${tr(context, 'about.version')} $_version ($_build)',
              style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(tr(context, 'about.github')),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launch(_kGithubUrl),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(tr(context, 'about.privacy')),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launch(en ? _kPrivacyUrlEn : _kPrivacyUrlZh),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(tr(context, 'about.tos')),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launch(en ? _kTosUrlEn : _kTosUrlZh),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(tr(context, 'about.licenses')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'ZLinker',
              applicationVersion:
                  _version.isEmpty ? null : '$_version+$_build',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr(context, 'about.disclaimer'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ZInk.ghost(context)),
            ),
          ),
        ],
      ),
    );
  }
}
