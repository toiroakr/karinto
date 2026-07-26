---
"karinto": patch
---

`use-trusted-publishing` findings in workflow files are now attributed to the specific step that triggered them (`job` + `step`, with `pos` pointing at that step's `uses:`/`run:` line) instead of only the owning job. This lets an inline `# karinto: ignore[...]` / `# zizmor: ignore[...]` comment placed on the offending step itself suppress the finding, which previously had no effect — the comment had to go on the job's own key line instead.
