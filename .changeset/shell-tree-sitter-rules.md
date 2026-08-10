---
"karinto": patch
---

Add tree-sitter-bash shell script analysis (#113). `github-env`, `unpinned-tools`, `unredacted-secrets`, and `use-trusted-publishing` now parse `run:` scripts with a real bash AST instead of regex/manual-tokenizer heuristics — `github-env` in particular now catches heredoc-based `$GITHUB_ENV` writes (`cat <<EOF >> "$GITHUB_ENV"`) that the old per-line scanner silently missed. Two new karinto-original rules ship on the same integration: `shell-quote-safety` (unquoted expansion of an env var whose value derives from a `${{ }}` expression) and `shell-undefined-var` (a shell variable reference with no declared `env:` source, SC2154-style).
