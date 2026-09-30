// Session-state checker.
//
// Concrete repositories and services live for the whole process — the provider
// graph is built inside `runApp`, above the router, and no logout rebuilds it.
// So any state one of them holds in a field outlives the session that produced
// it unless something deliberately empties it.
//
// Seven cross-user defects of that shape were found one at a time, in two
// distinct flavours:
//
//   late write     identity read before an `await`, state written after it, by
//                  which point SessionScope has already emptied the map for
//                  whoever signed in next. `Session.ended` answers this one,
//                  and it is a runtime property, so a test can catch it.
//
//   early capture  identity read once and baked into a long-lived object that
//                  is then held forever. `Session` cannot help: there is no
//                  await to straddle and no invalidation call to forget. The
//                  KYC wizard cache was this, and it survived seven passes
//                  over its own file because it looks like ordinary caching.
//
// Early capture has no runtime signature to test for, which is why this is a
// source check. What it can see is the field that does the holding.
//
// Three rules, all over `lib/sdks/` — the concrete implementations:
//
//   S1 mutable-collection  a field holding a mutable Map/Set/List. Use
//                          SessionMap if it is per-user; baseline it if not.
//   S2 async-cache         a field holding package:async's AsyncCache, which
//                          retains a failed future for the full TTL and has
//                          no session hook. Use AsyncMemo.
//   S3 reassignable        a non-final field. Reassignment is how a value from
//                          one session becomes the value read in the next.
//
// SessionMap, AsyncMemo and KeyedAsyncMemo are exempt: they register with the
// SessionScope that constructs them, so a cache that exists is a cache that is
// cleared. Genuinely session-independent state is not a defect — record it in
// the baseline, where the reason is reviewable, rather than teaching this tool
// to guess.
//
// Handles that are lifecycle rather than data — subscriptions, timers, stream
// controllers — are exempt from S3 only. `cancel_subscriptions` already covers
// them and they carry no user data.
//
// Usage:
//   fvm dart run tool/check_session_state.dart                    # check (CI)
//   fvm dart run tool/check_session_state.dart --report            # by rule
//   fvm dart run tool/check_session_state.dart --update-baseline   # ratchet
//
// Baseline keys name the field, not its line, so recorded entries survive the
// file being reformatted or moved around. The baseline may only ever shrink.

import 'dart:io';

const baselinePath = 'tool/session_state_baseline.txt';

const scanRoots = <String>['lib/sdks'];

/// Registers itself with a `SessionScope`, so it is emptied at the boundary.
const managedPrimitives = <String>['SessionMap', 'AsyncMemo', 'KeyedAsyncMemo'];

/// Lifecycle handles rather than per-user data. Exempt from S3 only — one of
/// these held in a Map is still a Map.
const lifecycleTypes = <String>[
  'StreamSubscription',
  'StreamController',
  'Timer',
  'Completer',
  'Subject',
];

class Finding {
  Finding(this.rule, this.file, this.field, this.line, this.source);

  final String rule;
  final String file;
  final String field;
  final int line;
  final String source;

  String get key => '$rule $file $field';
}

/// Blanks comments and string literals so their contents cannot match a rule,
/// preserving line structure so reported line numbers stay true.
String strip(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final rest = source.length - i;
    if (rest >= 2 && source[i] == '/' && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (rest >= 2 && source[i] == '/' && source[i + 1] == '*') {
      i += 2;
      var depth = 1;
      while (i < source.length && depth > 0) {
        if (i + 1 < source.length && source[i] == '/' && source[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (i + 1 < source.length &&
            source[i] == '*' &&
            source[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          if (source[i] == '\n') {
            out.write('\n');
          }
          i++;
        }
      }
      continue;
    }
    if (source[i] == "'" || source[i] == '"') {
      final quote = source[i];
      final triple =
          rest >= 3 && source[i + 1] == quote && source[i + 2] == quote;
      final delimiter = triple ? quote * 3 : quote;
      i += delimiter.length;
      while (i < source.length) {
        if (source[i] == r'\') {
          i += 2;
          continue;
        }
        if (source.startsWith(delimiter, i)) {
          i += delimiter.length;
          break;
        }
        if (source[i] == '\n') {
          out.write('\n');
        }
        i++;
      }
      out.write("''");
      continue;
    }
    out.write(source[i]);
    i++;
  }
  return out.toString();
}

/// The first `=` that is an assignment, skipping `==`, `>=`, `<=`, `!=`, `=>`.
int assignmentIndex(String declaration) {
  for (var i = 0; i < declaration.length; i++) {
    if (declaration[i] != '=') {
      continue;
    }
    final before = i > 0 ? declaration[i - 1] : '';
    final after = i + 1 < declaration.length ? declaration[i + 1] : '';
    if (after == '=' || after == '>') {
      i++;
      continue;
    }
    if (['=', '!', '<', '>'].contains(before)) {
      continue;
    }
    return i;
  }
  return -1;
}

/// Reads the field's name out of a declaration, or null when the declaration
/// is not a field at all.
String? fieldName(String declaration, String className) {
  final d = declaration.trim();
  if (d.isEmpty || d.startsWith('@')) {
    return null;
  }
  // A constructor, a redirect, or a factory.
  if (d.startsWith(className) || d.startsWith('factory ')) {
    return null;
  }
  if (d.startsWith('const ') || d.startsWith('static const ')) {
    return null;
  }

  final eq = assignmentIndex(d);
  final head = eq == -1 ? d : d.substring(0, eq);
  // A method or expression-bodied member: parentheses in the part that would
  // otherwise be the field's type and name.
  if (head.contains('(') || head.contains('=>')) {
    return null;
  }
  if (head.contains(' get ') || head.startsWith('get ')) {
    return null;
  }

  final words = head
      .replaceAll(';', '')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return null;
  }
  final name = words.last;
  return RegExp(r'^_?[a-z]\w*$').hasMatch(name) ? name : null;
}

String? classify(String declaration) {
  final d = declaration;
  if (managedPrimitives.any((p) => d.contains('$p('))) {
    return null;
  }
  if (managedPrimitives.any((p) => d.contains('$p<'))) {
    return null;
  }

  final eq = assignmentIndex(d);
  final head = eq == -1 ? d : d.substring(0, eq);
  final initialiser = eq == -1 ? '' : d.substring(eq + 1);

  if (initialiser.contains('AsyncCache<') || head.contains('AsyncCache<')) {
    return 'S2-async-cache';
  }

  // Owning a collection it created, rather than merely being typed as one: an
  // injected `final Map<..> x;` on a value object is the holder's business, and
  // a container in a type *argument* (a StreamSubscription<List<..>>) is not a
  // collection at all. A container field assigned later is non-final, so S3
  // still has it.
  final ownsCollection = RegExp(
    r'=\s*(?:const\s*)?<[^;]*>\s*(?:\{|\[)|=\s*(?:\{\s*\}|\[\s*\])',
  ).hasMatch(d);
  if (ownsCollection) {
    return 'S1-mutable-collection';
  }

  final isFinal = head.contains('final ') || head.startsWith('static final');
  if (!isFinal && !lifecycleTypes.any(head.contains)) {
    return 'S3-reassignable';
  }

  return null;
}

List<Finding> scanFile(File file) {
  final relative = file.path.replaceFirst(RegExp(r'^\./'), '');
  final lines = strip(file.readAsStringSync()).split('\n');
  final findings = <Finding>[];

  var depth = 0;
  String? className;
  var buffer = '';
  var bufferLine = 0;

  final classPattern = RegExp(
    '^(?:abstract |final |sealed |base |mixin |interface )*'
    r'(?:class|mixin)\s+(\w+)',
  );

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();

    if (depth == 0) {
      final match = classPattern.firstMatch(trimmed);
      if (match != null) {
        className = match.group(1);
        buffer = '';
      }
    }

    if (depth == 1 && className != null && trimmed.isNotEmpty) {
      if (buffer.isEmpty) {
        bufferLine = i + 1;
      }
      buffer += ' $trimmed';

      if (trimmed.endsWith(';')) {
        final name = fieldName(buffer, className);
        if (name != null) {
          final rule = classify(buffer);
          if (rule != null) {
            findings.add(
              Finding(rule, relative, name, bufferLine, buffer.trim()),
            );
          }
        }
        buffer = '';
      } else if (trimmed.endsWith('{')) {
        // A member body opens; nothing accumulated so far was a field.
        buffer = '';
      }
    }

    final opened = line.split('{').length - 1;
    final closed = line.split('}').length - 1;
    // A declaration whose `with`/`implements` clause wraps leaves depth at 0
    // for another line or two; only a body that actually opened can close.
    final wasInsideBody = depth > 0;
    depth += opened - closed;
    if (depth <= 0) {
      depth = 0;
      if (wasInsideBody) {
        className = null;
        buffer = '';
      }
    }
  }

  return findings;
}

List<Finding> scan() {
  final findings = <Finding>[];
  for (final root in scanRoots) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      continue;
    }
    final files =
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where(
              (f) => !f.path.endsWith('.g.dart') &&
                  !f.path.endsWith('.gr.dart') &&
                  !f.path.endsWith('.freezed.dart') &&
                  !f.path.endsWith('.mocks.dart'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      findings.addAll(scanFile(file));
    }
  }
  return findings;
}

Map<String, int> tally(Iterable<String> keys) {
  final counts = <String, int>{};
  for (final key in keys) {
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

void report(List<Finding> findings) {
  final byRule = tally(findings.map((f) => f.rule));
  stdout.writeln('Session state held in fields under ${scanRoots.join(', ')}');
  stdout.writeln();
  for (final entry in byRule.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value))) {
    stdout.writeln('${entry.value.toString().padLeft(4)}  ${entry.key}');
  }
  stdout.writeln();
  var lastFile = '';
  for (final f in findings) {
    if (f.file != lastFile) {
      stdout.writeln(f.file);
      lastFile = f.file;
    }
    stdout.writeln('  ${f.line.toString().padLeft(4)}  ${f.rule}  ${f.field}');
  }
}

void main(List<String> args) {
  if (!Directory('lib').existsSync()) {
    stderr.writeln('error: run from the repository root (lib/ not found).');
    exit(2);
  }

  final findings = scan();

  if (args.contains('--report')) {
    report(findings);
    return;
  }

  final current = findings.map((f) => f.key).toSet();
  final baselineFile = File(baselinePath);

  if (args.contains('--update-baseline')) {
    final sorted = current.toList()..sort();
    final perRule =
        (tally(sorted.map((k) => k.split(' ').first)).entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .map((e) => '#   ${e.value.toString().padLeft(4)}  ${e.key}')
            .join('\n');
    baselineFile.writeAsStringSync(
      '# Session state held in fields that nothing empties at the session\n'
      '# boundary. This list may only shrink.\n'
      '# Rules: tool/check_session_state.dart\n'
      '# Regenerate: fvm dart run tool/check_session_state.dart '
      '--update-baseline\n'
      '#\n'
      '# An entry here is a claim that the state is NOT derived from the\n'
      '# signed-in user. Per-user state belongs in a SessionMap or an\n'
      '# AsyncMemo, which the SessionScope that constructs them empties.\n'
      '#\n'
      '# Keys name the field rather than its line, so reformatting a file\n'
      '# does not churn this list.\n'
      '#\n'
      '# The count may also rise when the checker learns to see somewhere it\n'
      '# could not before. That is the only other legitimate reason.\n'
      '# count: ${sorted.length}\n'
      '$perRule\n'
      '${sorted.join('\n')}\n',
    );
    stdout.writeln('Baseline updated: ${sorted.length} field(s) recorded.');
    return;
  }

  final baseline = baselineFile.existsSync()
      ? baselineFile
            .readAsLinesSync()
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .toSet()
      : <String>{};

  final added = (current.difference(baseline).toList())..sort();
  final fixed = (baseline.difference(current).toList())..sort();
  final byKey = <String, Finding>{for (final f in findings) f.key: f};

  if (added.isNotEmpty) {
    stderr.writeln('FAIL: ${added.length} new session-state field(s).\n');
    for (final key in added) {
      final f = byKey[key]!;
      stderr.writeln('  ${f.rule}');
      stderr.writeln('    ${f.file}:${f.line}');
      stderr.writeln('    ${f.source}');
      stderr.writeln();
    }
    stderr.writeln(
      'A concrete repository outlives every session, so state it holds in a\n'
      'field is read by the next user unless something empties it.\n'
      '  * per-user collection  -> SessionMap(scope)\n'
      '  * per-user fetch       -> AsyncMemo(scope, fetch, ttl: ...)\n'
      '  * writes after an\n'
      '    await                -> take scope.current first, then bail when\n'
      '                            session.ended before writing\n'
      '  * an object that bakes\n'
      '    in the customer id   -> build it per call instead of holding it;\n'
      '                            see getProfileWizard\n'
      '\n'
      'If the state is genuinely not derived from the signed-in user, record\n'
      'it — with reviewer agreement — via:\n'
      '  fvm dart run tool/check_session_state.dart --update-baseline',
    );
    exit(1);
  }

  stdout.writeln(
    'Session state OK: ${current.length} known field(s), no new ones.',
  );
  if (fixed.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('${fixed.length} baselined field(s) now gone:');
    for (final key in fixed.take(20)) {
      stdout.writeln('  $key');
    }
    if (fixed.length > 20) {
      stdout.writeln('  ... and ${fixed.length - 20} more');
    }
    stdout.writeln();
    stdout.writeln(
      'Ratchet the baseline down:\n'
      '  fvm dart run tool/check_session_state.dart --update-baseline',
    );
  }
}
