---
"karinto": patch
---

Honour inline `# zizmor: ignore[...]` / `# karinto: ignore[...]` comments for
workflow-scoped findings that carry no source position (e.g.
`cache-poisoning`). When inline ignores became line-scoped, such findings —
emitted once per workflow without a step/job anchor, so `fill_positions`
leaves them position-less — could no longer be suppressed by an inline
comment, because the line-scoped match guarded on a resolved position. The
opt-out was silently dropped even when the author placed the comment exactly
where the upstream tool (zizmor) attributes the finding. Position-less
findings now fall back to a file-wide match: any inline ignore in the file
that names the rule suppresses it. Positioned findings remain strictly
line-scoped.
