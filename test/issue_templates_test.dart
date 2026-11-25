import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the GitHub issue templates in `.github/ISSUE_TEMPLATE/`: three
/// templates (bug / feature / general question) plus `config.yml`, valid
/// frontmatter, names longer than 3 characters (GitHub hides shorter names),
/// labels that actually exist in the repo, and contact links on the pinned
/// hosts. The website host check itself lives in `test/website_links_test.dart`
/// (it scans `.github/**/*.md` recursively, so these files are covered there).
void main() {
  final dir = Directory('.github/ISSUE_TEMPLATE');

  /// Splits `---
  /// ...
  /// ---` frontmatter from the body.
  Map<String, String> frontmatter(String content) {
    expect(content.startsWith('---\n'), isTrue,
        reason: 'template must start with YAML frontmatter');
    final end = content.indexOf('\n---', 4);
    expect(end, greaterThan(0), reason: 'frontmatter must be closed');
    final out = <String, String>{};
    for (final line in content.substring(4, end).split('\n')) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        out[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
      }
    }
    return out;
  }

  test('the three templates plus config.yml exist', () {
    for (final f in [
      '01-bug-report.md',
      '02-feature-request.md',
      '03-general-question.md',
      'config.yml',
    ]) {
      expect(File('${dir.path}/$f').existsSync(), isTrue, reason: f);
    }
  });

  test('each template has valid frontmatter: name > 3 chars, about, title, existing label', () {
    // Labels that exist in the repo (fetched from the GitHub API 2026-11-25).
    const repoLabels = {
      'bug', 'documentation', 'duplicate', 'enhancement', 'good first issue',
      'help wanted', 'invalid', 'question', 'wontfix',
    };
    final seen = <String>[];
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.md'))) {
      final fm = frontmatter(f.readAsStringSync());
      final name = fm['name']?.replaceAll(RegExp(r"""^['"]|['"]$"""), '') ?? '';
      expect(name.length, greaterThan(3),
          reason: '${f.path}: GitHub hides template names <= 3 chars');
      expect(fm['about'], isNotNull, reason: '${f.path}: missing about');
      expect(fm['title'], isNotNull, reason: '${f.path}: missing title');
      final labels = fm['labels'];
      expect(labels, isNotNull, reason: '${f.path}: missing labels');
      for (final l in labels!.split(',')) {
        expect(repoLabels, contains(l.trim()),
            reason: '${f.path}: label "${l.trim()}" does not exist in the repo');
      }
      seen.add(name);
    }
    expect(seen, containsAll(['Bug report', 'Feature request', 'General question']));
  });

  test('bug report asks for the details this project needs', () {
    final bug = File('${dir.path}/01-bug-report.md').readAsStringSync();
    for (final needle in [
      'Settings → About',
      'Steps to reproduce',
      'Expected behavior',
      'Actual behavior',
      'Dolby Vision',
      'Media3',
      'MPV',
      'App crashed?',
      'logcat_dump.log',
      'smb_debug.log',
      'SMB',
      'WebDAV',
      'Jellyfin',
      'DLNA',
    ]) {
      expect(bug, contains(needle), reason: 'bug template missing "$needle"');
    }
  });

  test('config.yml keeps blank issues and lists contact links on allowed hosts', () {
    final cfg = File('${dir.path}/config.yml').readAsStringSync();
    expect(cfg, contains('blank_issues_enabled: true'));
    expect(cfg, contains('contact_links:'));
    expect(cfg, contains('https://discord.gg/sAnXAAA8R'));
    expect(cfg, contains('https://dreamplayer.isroot.in/'));
    // No wrong-TLD site lookalikes (same rule as website_links_test).
    expect(cfg, isNot(matches(RegExp(
        r'dreamplayer\.isroot\.(?:com|net|org|in\.au)|dreamplayer\.isroot\.io'))));
  });
}
