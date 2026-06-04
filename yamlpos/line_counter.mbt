///|
/// Records line-break offsets so that source offsets can be lazily resolved to
/// 1-based `(line, col)` positions.
///
/// Port of eemeli/yaml's `LineCounter` (`src/parse/line-counter.ts`). The
/// `line_starts` array holds the offset of the first character of each line.
/// `add_newline(offset)` records the offset *after* a line break. Resolution is
/// done with a binary search, matching the upstream lazy strategy.
pub struct LineCounter {
  line_starts : Array[Int]
}

///|
pub fn LineCounter::new() -> LineCounter {
  // Line 1 always starts at offset 0.
  { line_starts: [0] }
}

///|
/// Records that a line break ends at `offset`, so a new line begins at
/// `offset`. Offsets must be added in non-decreasing order; duplicates are
/// ignored to stay robust against being called from multiple scanners.
pub fn LineCounter::add_newline(self : LineCounter, offset : Int) -> Unit {
  let n = self.line_starts.length()
  if n == 0 || offset > self.line_starts[n - 1] {
    self.line_starts.push(offset)
  }
}

///|
/// Builds a LineCounter directly from source text by scanning for line breaks.
/// Handles `\n` and `\r\n` (the `\r` is consumed with the following `\n`).
pub fn LineCounter::from_source(source : String) -> LineCounter {
  let lc = LineCounter::new()
  let len = source.length()
  let mut i = 0
  while i < len {
    let c = source.unsafe_get(i).to_int()
    if c == '\n' {
      lc.add_newline(i + 1)
    } else if c == '\r' {
      // CR not followed by LF still ends a line in YAML.
      if i + 1 < len && source.unsafe_get(i + 1).to_int() == '\n' {
        lc.add_newline(i + 2)
        i = i + 1
      } else {
        lc.add_newline(i + 1)
      }
    }
    i = i + 1
  }
  lc
}

///|
/// Resolves a UTF-16 offset to a 1-based `(line, col)` pair via binary search
/// over the recorded line starts.
pub fn LineCounter::line_col(self : LineCounter, offset : Int) -> (Int, Int) {
  let starts = self.line_starts
  let mut low = 0
  let mut high = starts.length()
  // Find the last line start that is <= offset.
  while low < high {
    let mid = (low + high) / 2
    if starts[mid] <= offset {
      low = mid + 1
    } else {
      high = mid
    }
  }
  // `low` is the count of starts <= offset; line index is low-1 (0-based),
  // so the 1-based line number is `low`.
  let line = if low == 0 { 1 } else { low }
  let line_start = if low == 0 { 0 } else { starts[low - 1] }
  let col = offset - line_start + 1
  (line, col)
}
