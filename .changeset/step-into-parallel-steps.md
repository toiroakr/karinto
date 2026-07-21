---
"karinto": patch
---

Fix `template-injection` (and other per-step rules) missing findings inside zizmor 1.27's experimental `parallel:` steps. `build_steps` now flattens `parallel:` sub-steps into the step list so `on_step` rules see their `run:`/`uses:` bodies; diagnostics for a nested sub-step report the position of the parent `parallel:` entry.
