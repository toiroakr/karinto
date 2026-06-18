// Persona gating: a finding declares the minimum persona at which it
// surfaces, and `lint(persona=…)` filters to that level. `Auditor` (the
// default) shows everything.
//
// Fixture below intentionally triggers a mix:
//   - self-hosted-runner   → Pedantic
//   - anonymous-definition → Pedantic (workflow + job, no `name:`)
//   - template-injection   → Error (untrusted, Regular) + Info backstop (Pedantic)
//   - secrets-outside-env  → Auditor
//   - excessive-permissions → job-level "default permissions used" is Regular;
//     the workflow-level "no permissions: block" finding is Pedantic (matching
//     zizmor); the per-key `write` finding is Pedantic too (see
//     persona_gating_test.mbt)
//   - concurrency-limits   → Pedantic (hidden at regular)

///|
fn persona_keys(content : String, persona : @karinto.Persona) -> Array[String] {
  let r = @karinto.lint(content, persona~)
  let out = r.diagnostics.map(fn(d) {
    let sev = match d.severity {
      @karinto.Error => "error"
      @karinto.Warning => "warning"
      @karinto.Info => "info"
    }
    "\{sev} \{d.rule}"
  })
  out.sort()
  out
}

///|
let persona_fixture : String =
  #|on: push
  #|jobs:
  #|  build:
  #|    runs-on: self-hosted
  #|    steps:
  #|      - run: echo "${{ github.run_id }}"
  #|      - run: echo "${{ github.event.issue.title }} ${{ secrets.TOKEN }}"

///|
test "persona=regular hides pedantic and auditor findings" {
  json_inspect(persona_keys(persona_fixture, @karinto.Persona::Regular), content=[
    "error template-injection", "warning excessive-permissions", "warning job-permissions-required",
    "warning job-timeout-minutes-required",
  ])
}

///|
test "persona=pedantic adds pedantic findings but still hides auditor" {
  json_inspect(persona_keys(persona_fixture, @karinto.Persona::Pedantic), content=[
    "info concurrency-limits", "info template-injection", "error template-injection",
    "info anonymous-definition", "info anonymous-definition", "warning self-hosted-runner",
    "warning excessive-permissions", "warning excessive-permissions", "warning job-permissions-required",
    "warning job-timeout-minutes-required",
  ])
}

///|
test "persona=auditor (default) shows everything" {
  json_inspect(persona_keys(persona_fixture, @karinto.Persona::Auditor), content=[
    "info concurrency-limits", "info template-injection", "error template-injection",
    "info anonymous-definition", "info anonymous-definition", "warning self-hosted-runner",
    "warning secrets-outside-env", "warning excessive-permissions", "warning excessive-permissions",
    "warning job-permissions-required", "warning job-timeout-minutes-required",
  ])
}
