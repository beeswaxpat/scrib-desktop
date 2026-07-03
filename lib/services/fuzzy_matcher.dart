/// Fuzzy string matching for the command palette.
///
/// Pure Dart, no dependencies. Every query character must appear in the target
/// in order (case-insensitive); scoring rewards prefix matches, word starts,
/// consecutive runs, and exact-case hits, and penalizes gaps so tighter
/// matches rank first.
library;

/// Result of a successful fuzzy match: a comparable [score] (higher is
/// better) and the target indices that matched, for highlighting.
class FuzzyMatch {
  final int score;
  final List<int> matchedIndices;

  const FuzzyMatch(this.score, this.matchedIndices);
}

const int _bonusConsecutive = 16;
const int _bonusWordStart = 12;
const int _bonusTargetStart = 8;
const int _bonusExactCase = 1;
const int _penaltyPerGapChar = 1;
const int _maxGapPenalty = 9;

bool _isWordSeparator(String ch) =>
    ch == ' ' || ch == '_' || ch == '-' || ch == '.' || ch == '/' || ch == ':';

/// Whether the character at [index] starts a word in [target]:
/// position 0, after a separator, or an upper-case letter after a lower-case
/// one (camelCase boundary).
bool _isWordStart(String target, int index) {
  if (index == 0) return true;
  final prev = target[index - 1];
  if (_isWordSeparator(prev)) return true;
  final ch = target[index];
  final chIsUpper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
  final prevIsLower = prev.toLowerCase() == prev && prev.toUpperCase() != prev;
  return chIsUpper && prevIsLower;
}

/// Match [query] against [target]. Returns null when the query's characters
/// do not all appear in order. An empty query matches everything with score 0.
FuzzyMatch? fuzzyMatch(String query, String target) {
  if (query.isEmpty) return const FuzzyMatch(0, []);
  if (target.isEmpty || query.length > target.length) return null;

  final queryLower = query.toLowerCase();
  final targetLower = target.toLowerCase();

  // Greedy left-to-right matching is order-dependent: starting the match at a
  // later occurrence of the first query character can score higher (e.g. "ta"
  // against "Insert Table" should anchor on "Table", not the 't' in "Insert").
  // Targets are short (command titles), so try every anchor and keep the best.
  FuzzyMatch? best;
  for (int start = targetLower.indexOf(queryLower[0]);
      start != -1;
      start = targetLower.indexOf(queryLower[0], start + 1)) {
    final candidate = _matchFrom(query, queryLower, target, targetLower, start);
    if (candidate != null && (best == null || candidate.score > best.score)) {
      best = candidate;
    }
  }
  return best;
}

FuzzyMatch? _matchFrom(
  String query,
  String queryLower,
  String target,
  String targetLower,
  int start,
) {
  final indices = <int>[];
  int score = 0;
  int ti = start;

  for (int qi = 0; qi < queryLower.length; qi++) {
    final found = targetLower.indexOf(queryLower[qi], ti);
    if (found == -1) return null;

    if (indices.isNotEmpty) {
      final gap = found - indices.last - 1;
      if (gap == 0) {
        score += _bonusConsecutive;
      } else {
        score -= (gap * _penaltyPerGapChar).clamp(0, _maxGapPenalty);
      }
    }
    if (found == 0) score += _bonusTargetStart;
    if (_isWordStart(target, found)) score += _bonusWordStart;
    if (target[found] == query[qi]) score += _bonusExactCase;

    indices.add(found);
    ti = found + 1;
  }

  // Prefer tighter overall spans and shorter targets when raw bonuses tie.
  score -= (indices.last - indices.first) - (indices.length - 1);
  score -= (target.length / 8).floor();

  return FuzzyMatch(score, indices);
}
