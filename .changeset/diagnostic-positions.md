---
"karinto": minor
---

Carry source line/column positions on diagnostics (#35), and replace the YAML
parser to make it possible.

Each diagnostic tied to a concrete job or step now includes a `pos` field —
`{ "line": <1-based>, "col": <1-based> }`. Where a finding concerns a specific
field it points at that field's node (the `uses:` value, the `run:` script, the
`permissions:` key); otherwise it falls back to the job key or step entry. The
field is optional and omitted for workflow-global findings, so existing
consumers are unaffected; `job` / `step` remain fallback handles.

To obtain positions, karinto **drops the `moonbit-community/yaml` dependency** in
favour of a new in-tree parser, `yamlpos`: a MoonBit port of the
[eemeli/yaml](https://github.com/eemeli/yaml) design — a layered lexer →
offset-range CST → composed AST with first-class source ranges, plus a
`LineCounter` that resolves line/column lazily. It parses full YAML 1.2 (block +
flow, anchors/aliases, tags, all block-scalar styles, merge keys, multi-doc) and
decodes scalar values, so it is a drop-in replacement for the rule engine's
value tree (rule behaviour is unchanged) while additionally exposing positions.

We prototyped and benchmarked both forking the existing parser and porting
eemeli/yaml from scratch; the port won on size, position design (offset-first
ranges + lazy line/col), and not carrying a fork.

This unblocks richer integrations — SARIF `physicalLocation` and GitHub Actions
inline annotations.
