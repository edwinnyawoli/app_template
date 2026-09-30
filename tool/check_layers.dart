// Architecture boundary checker.
//
// Enforces a strict vertical layering: a higher layer may depend on a lower
// one, never the reverse, and never sideways between peers. The layer order is
// the `featureLayers` map below — that map is the single source of truth.
//
// Six rules are enforced:
//
//   R1 layer-direction  features/<X> may import features/<Y> only if X's layer
//                       is strictly higher than Y's.
//   R2 core-purity      lib/core/ must not import lib/features/ or lib/sdks/.
//   R3 common-purity    lib/common/ must not import lib/features/.
//   R4 shell-isolation  no feature below the shell layer may import lib/app/.
//   R5 port-purity      a feature must import its own repository/ interface,
//                       never the lib/sdks/ implementation.
//
// R1-R5 are about our own layers. By then the app's vocabulary is the backend's vocabulary
// and a spec change is a UI change.
//
// The allowed locations are the three that have to name wire types:
//   * lib/app/   builds the SDK instance and picks live vs simulated.
//   * repository/ states a feature's port. Permitted by long-standing
//                convention rather than necessity — see
//                features/notification/repository/ for a port that carries no
//                wire types at all, which is the better shape.
//
// Deep imports (bypassing a feature's index.dart) are counted in --report but
// not enforced: almost every cross-feature import is currently deep, so that
// rule only becomes meaningful once the shared UI and models have been moved
// out of the features that happen to host them.
//
// Usage:
//   fvm dart run tool/check_layers.dart                    # check (CI)
//   fvm dart run tool/check_layers.dart --report            # full statistics
//   fvm dart run tool/check_layers.dart --update-baseline   # re-record the ratchet
//
// Existing violations are recorded in tool/layer_baseline.txt so the check can
// fail on *new* violations from day one while the backlog is worked down. The
// baseline may only ever shrink.

import 'dart:io';

/// Layer ranks. A module may import a module with a strictly lower rank.
/// Equal ranks are peers and may not import each other.
/// `lib/core/` is below everything, `lib/common/` sits just above it, and
/// `lib/assets/` + `lib/theme/` are leaves importable from anywhere.
///
/// Derived from the real import graph (greedy minimum-feedback-arc-set) then
/// adjusted for domain sense. Two orderings are deliberate rather than
/// data-driven, because the graph was near-symmetric in both cases:
///   * `transact` above `accounts` — an account is the more foundational noun;
///     a transaction references accounts, not the reverse.
///   * `profiles` above `auth` — authentication is the more primitive
///     capability; identity/KYC builds on it.
const featureLayers = <String, int>{
  // L2 — leaves. Nothing here depends on another feature. `support` still
  // carries the transaction-dispute pages that reach upward; those move to
  // `disputes` and the remainder is a true leaf.
  'app_links': 2,
  'versioning': 2,
  'support': 2,
  // L3 — platform capabilities built on the leaves
  'notification': 3,
  'referrals': 3,
  // L4 — authentication
  'auth': 4,
  // L5 — identity / KYC
  'profiles': 5,
  // L6 — accounts
  'accounts': 6,
  // L7 — payments
  'transact': 7,
  // L8 — journeys. `disputes` is the Phase 5 split of `support`'s reporting half.
  'loans': 8,
  'settings': 8,
  'disputes': 8,
  // L9 — entry
  'onboarding': 9,
  // L10 — shell. `shell` is the Phase 5 destination of `dashboard`.
  'dashboard': 10,
  'shell': 10,
};

const shellLayer = 10;
const baselinePath = 'tool/layer_baseline.txt';

/// Whether [libRelativePath] is one of the places allowed to name generated
/// API types (R6). See the rule notes at the top of this file.
bool mayNameWireTypes(String libRelativePath) {
  final parts = libRelativePath.split('/');
  return switch (parts.first) {
    'sdks' || 'app' => true,
    'features' => parts.length > 2 && parts[2] == 'repository',
    _ => false,
  };
}

/// Where a file or an import URI sits in the tree.
class Module {
  const Module(this.kind, [this.feature = '']);
  final String kind; // core | common | features | sdks | app | leaf
  final String feature;

  bool get isFeature => kind == 'features';
  int get layer => isFeature ? (featureLayers[feature] ?? -1) : -1;
  String get name => isFeature ? 'features/$feature' : kind;
}

Module? moduleOf(String libRelativePath) {
  final parts = libRelativePath.split('/');
  if (parts.isEmpty) {
    return null;
  }
  switch (parts.first) {
    case 'core':
      return const Module('core');
    case 'common':
      return const Module('common');
    case 'sdks':
      return const Module('sdks');
    case 'app':
      return const Module('app');
    case 'assets':
    case 'theme':
      return const Module('leaf');
    case 'features':
      if (parts.length < 2) {
        return null;
      }
      return Module('features', parts[1]);
    default:
      return null;
  }
}

class Violation {
  Violation({
    required this.rule,
    required this.source,
    required this.target,
    required this.detail,
  });
  final String rule;
  final String source; // lib-relative path of the importing file
  final String target; // lib-relative path of the imported file
  final String detail;

  /// Stable, line-oriented key so baseline diffs stay readable.
  String get key => '$rule $source -> $target';
}

class Edge {
  Edge(this.fromFeature, this.toFeature, this.source, this.target);
  final String fromFeature;
  final String toFeature;
  final String source;
  final String target;

  /// Which layer of the target feature was reached — determines the remediation.
  String get bucket {
    final rest = target.split('/').skip(2).join('/');
    if (rest == 'theme.dart' ||
        rest == 'common.dart' ||
        rest == 'core.dart' ||
        rest == 'assets.dart') {
      return 'A-empty-barrel';
    }
    if (rest == 'router.dart' || rest == 'router.gr.dart') {
      return 'E-navigation';
    }
    if (rest == 'index.dart') {
      return 'G-public-index';
    }
    switch (rest.split('/').first) {
      case 'widgets':
        return 'B-shared-ui';
      case 'model':
      case 'extensions':
      case 'extension':
        return 'C-shared-model';
      case 'repository':
        return 'D-repository-port';
      case 'pages':
        return 'F-deep-page';
      default:
        return 'Z-other';
    }
  }
}

final _importPattern = RegExp(
  r"""^\s*(?:import|export)\s+'package:app_template/([^']+)'""",
  multiLine: true,
);

/// Matches the external SDK package and the generated API packages it
/// re-exports, so importing one of those directly cannot sidestep R6.

class Scan {
  final violations = <Violation>[];
  final edges = <Edge>[];
  final deepImports = <Edge>[];
}

Scan scan(Directory lib) {
  final result = Scan();
  final files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final source = file.path.substring(file.path.indexOf('lib/') + 4);
    final content = file.readAsStringSync();

    if (!mayNameWireTypes(source)) {
      for (final match in _wirePackagePattern.allMatches(content)) {
        result.violations.add(
          Violation(
            rule: 'R6-wire-purity',
            source: source,
            target: match.group(1)!,
            detail:
                'generated API types must stop at lib/sdks/, lib/app/ or a '
                "feature's own repository/",
          ),
        );
      }
    }

    final from = moduleOf(source);
    if (from == null) {
      continue;
    }

    for (final match in _importPattern.allMatches(content)) {
      final target = match.group(1)!;
      final to = moduleOf(target);
      if (to == null || to.kind == 'leaf') {
        continue;
      }

      void add(String rule, String detail) => result.violations.add(
        Violation(rule: rule, source: source, target: target, detail: detail),
      );

      if (from.kind == 'core' && to.isFeature) {
        add('R2-core-purity', 'lib/core must not depend on a feature');
      } else if (from.kind == 'core' && to.kind == 'sdks') {
        add('R2-core-purity', 'lib/core must not depend on lib/sdks');
      } else if (from.kind == 'common' && to.isFeature) {
        add('R3-common-purity', 'lib/common must not depend on a feature');
      } else if (from.isFeature &&
          to.kind == 'app' &&
          from.layer < shellLayer) {
        add('R4-shell-isolation', 'a feature must not depend on lib/app');
      } else if (from.isFeature && to.kind == 'sdks') {
        add(
          'R5-port-purity',
          'a feature must depend on its own repository interface, '
              'not the lib/sdks implementation',
        );
      } else if (from.isFeature && to.isFeature && from.feature != to.feature) {
        final edge = Edge(from.feature, to.feature, source, target);
        result.edges.add(edge);
        if (from.layer <= to.layer) {
          add(
            'R1-layer-direction',
            '${from.name} (L${from.layer}) must not depend on '
                '${to.name} (L${to.layer})',
          );
        }
        if (!target.endsWith('/index.dart')) {
          result.deepImports.add(edge);
        }
      }
    }
  }
  return result;
}

/// Tarjan's strongly connected components over the feature graph.
List<List<String>> stronglyConnected(Map<String, Set<String>> adjacency) {
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final out = <List<String>>[];
  var counter = 0;

  void strongConnect(String v) {
    index[v] = low[v] = counter++;
    stack.add(v);
    onStack.add(v);
    for (final w in adjacency[v] ?? const <String>{}) {
      if (!index.containsKey(w)) {
        strongConnect(w);
        low[v] = low[v]! < low[w]! ? low[v]! : low[w]!;
      } else if (onStack.contains(w)) {
        low[v] = low[v]! < index[w]! ? low[v]! : index[w]!;
      }
    }
    if (low[v] == index[v]) {
      final component = <String>[];
      String w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      out.add(component..sort());
    }
  }

  for (final v in adjacency.keys.toList()..sort()) {
    if (!index.containsKey(v)) {
      strongConnect(v);
    }
  }
  return out;
}

Map<String, int> tally(Iterable<String> items) {
  final counts = <String, int>{};
  for (final item in items) {
    counts[item] = (counts[item] ?? 0) + 1;
  }
  return counts;
}

List<MapEntry<String, int>> descending(Map<String, int> counts) =>
    counts.entries.toList()..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });

void report(Scan result) {
  final out = stdout;
  final features =
      featureLayers.keys
          .where((f) => Directory('lib/features/$f').existsSync())
          .toList()
        ..sort();

  out.writeln('=== ARCHITECTURE REPORT ===');
  out.writeln(
    'Generated by tool/check_layers.dart (includes generated files).',
  );
  out.writeln();
  out.writeln('Cross-feature import statements : ${result.edges.length}');
  out.writeln('Total boundary violations       : ${result.violations.length}');
  out.writeln();

  out.writeln('--- violations by rule ---');
  for (final e in descending(tally(result.violations.map((v) => v.rule)))) {
    out.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  out.writeln();

  final layerViolations = result.violations
      .where((v) => v.rule == 'R1-layer-direction')
      .toList();
  final buckets = <String, int>{};
  for (final edge in result.edges) {
    if (edge.fromFeature.isEmpty) {
      continue;
    }
    final from = featureLayers[edge.fromFeature] ?? -1;
    final to = featureLayers[edge.toFeature] ?? -1;
    if (from <= to) {
      buckets[edge.bucket] = (buckets[edge.bucket] ?? 0) + 1;
    }
  }
  out.writeln('--- R1 violations by remediation bucket ---');
  for (final e in descending(buckets)) {
    out.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  out.writeln();

  out.writeln('--- all cross-feature edges by bucket ---');
  for (final e in descending(tally(result.edges.map((x) => x.bucket)))) {
    out.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  out.writeln();

  final wire = result.violations
      .where((v) => v.rule == 'R6-wire-purity')
      .toList();
  out.writeln('--- R6 wire-type leaks by location ---');
  final byLocation = tally(
    wire.map((v) {
      final parts = v.source.split('/');
      return parts.first == 'features' && parts.length > 2
          ? 'features/*/${parts[2]}'
          : parts.first;
    }),
  );
  for (final e in descending(byLocation)) {
    out.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  if (wire.isEmpty) {
    out.writeln('     0  (none)');
  }
  out.writeln();

  final pairs = tally(
    result.edges.map((e) => '${e.fromFeature} -> ${e.toFeature}'),
  );
  final adjacency = <String, Set<String>>{
    for (final f in features) f: <String>{},
  };
  for (final edge in result.edges) {
    adjacency
        .putIfAbsent(edge.fromFeature, () => <String>{})
        .add(edge.toFeature);
  }

  out.writeln('--- cycles (mutually dependent pairs) ---');
  final seen = <String>{};
  var cycles = 0;
  for (final key in pairs.keys.toList()..sort()) {
    final parts = key.split(' -> ');
    final reverse = '${parts[1]} -> ${parts[0]}';
    if (pairs.containsKey(reverse) && !seen.contains(reverse)) {
      seen.add(key);
      cycles++;
      out.writeln(
        '  ${parts[0]} <-> ${parts[1]}   '
        '(${pairs[key]} / ${pairs[reverse]})',
      );
    }
  }
  out.writeln('  total: $cycles');
  out.writeln();

  out.writeln('--- strongly connected components ---');
  for (final component in stronglyConnected(adjacency)) {
    if (component.length > 1) {
      out.writeln('  SIZE ${component.length}: ${component.join(', ')}');
    }
  }
  out.writeln();

  out.writeln('--- fan-out / fan-in ---');
  for (final f in features) {
    final fanOut = adjacency[f]?.length ?? 0;
    final fanIn = adjacency.entries
        .where((e) => e.key != f && e.value.contains(f))
        .length;
    out.writeln(
      '  ${f.padRight(14)} L${featureLayers[f]}  out=$fanOut  in=$fanIn',
    );
  }
  out.writeln();

  out.writeln('--- files most often reached illegally (R1) ---');
  final byTarget = tally(layerViolations.map((v) => v.target));
  for (final e in descending(byTarget).take(15)) {
    out.writeln('  ${e.value.toString().padLeft(3)}  ${e.key}');
  }
  out.writeln();

  out.writeln(
    'ADVISORY: ${result.deepImports.length} cross-feature imports bypass the '
    "target's index.dart.",
  );
  out.writeln('  (Not enforced — this is Phase 3/4/7 work.)');
}

void main(List<String> args) {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    stderr.writeln('error: run from the repository root (lib/ not found).');
    exit(2);
  }

  final result = scan(lib);

  if (args.contains('--report')) {
    report(result);
    return;
  }

  final current = result.violations.map((v) => v.key).toSet();
  final baselineFile = File(baselinePath);

  if (args.contains('--update-baseline')) {
    final sorted = current.toList()..sort();
    final perRule = descending(
      tally(sorted.map((k) => k.split(' ').first)),
    ).map((e) => '#   ${e.value.toString().padLeft(4)}  ${e.key}').join('\n');
    baselineFile.writeAsStringSync(
      '# Known architecture boundary violations. This list may only shrink.\n'
      '# Rules and layer order: tool/check_layers.dart\n'
      '# Regenerate: fvm dart run tool/check_layers.dart --update-baseline\n'
      '#\n'
      '# Per-rule counts, so the total growing when a NEW rule is introduced\n'
      '# stays distinguishable from an existing rule regressing. Adding a rule\n'
      '# is the only legitimate reason for the total to rise.\n'
      '# count: ${sorted.length}\n'
      '$perRule\n'
      '${sorted.join('\n')}\n',
    );
    stdout.writeln('Baseline updated: ${sorted.length} violations recorded.');
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

  final byKey = <String, Violation>{
    for (final v in result.violations) v.key: v,
  };

  if (added.isNotEmpty) {
    stderr.writeln(
      'FAIL: ${added.length} new architecture boundary violation(s).\n',
    );
    for (final key in added) {
      final v = byKey[key]!;
      final target = v.target.startsWith('package:')
          ? v.target
          : 'lib/${v.target}';
      stderr.writeln('  ${v.rule}');
      stderr.writeln('    lib/${v.source}');
      stderr.writeln('    imports $target');
      stderr.writeln('    ${v.detail}');
      stderr.writeln();
    }
    stderr.writeln(
      'The layer order and the six rules are defined at the top of\n'
      'tool/check_layers.dart. Common fixes:\n'
      '  * shared widget      -> move it to lib/common/ui/'
      '  * shared model       -> put the interface in lib/common/model/ and\n'
      '                          keep the implementation in the feature\n'
      '  * need data from a\n'
      '    higher feature     -> declare a narrow port in your own\n'
      '                          repository/ and wire it in provider_scope\n'
      '  * need to navigate\n'
      '    upward             -> declare a navigator port; the shell\n'
      "                          implements it against the real routes\n"
      '  * need a generated\n'
      '    API type (R6)      -> declare a domain model in your feature and\n'
      '                          convert in lib/sdks/mapper/; see\n'
      '                          mapper/notification.dart for the pattern\n'
      '\n'
      'If the import is genuinely correct, record it — with reviewer\n'
      'agreement — via:\n'
      '  fvm dart run tool/check_layers.dart --update-baseline',
    );
    exit(1);
  }

  stdout.writeln(
    'Architecture boundaries OK: ${current.length} known violation(s), '
    'no new ones.',
  );
  if (fixed.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('${fixed.length} baselined violation(s) now fixed:');
    for (final key in fixed.take(20)) {
      stdout.writeln('  $key');
    }
    if (fixed.length > 20) {
      stdout.writeln('  ... and ${fixed.length - 20} more');
    }
    stdout.writeln();
    stdout.writeln(
      'Ratchet the baseline down:\n'
      '  fvm dart run tool/check_layers.dart --update-baseline',
    );
  }
}
