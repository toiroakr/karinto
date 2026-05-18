///|
/// Demo CLI — runs the linter on a hard-coded workflow and prints the JSON
/// diagnostic envelope. Reading from stdin/files needs platform-specific FFI
/// in MoonBit, so for now this just exists to sanity-check the build pipeline.
///
/// For real usage, deploy the Cloudflare Worker in `cf/` and curl it.
fn main {
  let sample =
    #|on: push
    #|permissions: write-all
    #|jobs:
    #|  Build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - run: echo hi
  let result = @karinto.lint(sample)
  println(result.to_json().stringify(indent=2))
}
