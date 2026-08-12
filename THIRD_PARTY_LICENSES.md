# Third-Party Licenses

karinto is licensed under Apache-2.0 (see `LICENSE`).

This project is **inspired by**, and in a handful of cases ports algorithms
from, the following projects. Their rule taxonomy, behaviour expectations, and
in some cases test fixtures were used as a specification. All three are
distributed under the MIT License; their license texts are reproduced below.

| Project | Repository | License | Relationship |
| --- | --- | --- | --- |
| actionlint | <https://github.com/rhysd/actionlint> | MIT | Rule taxonomy inspiration |
| zizmor | <https://github.com/zizmorcore/zizmor> | MIT | Rule taxonomy inspiration |
| ghalint | <https://github.com/suzuki-shunsuke/ghalint> | MIT | Rule taxonomy inspiration |
| eemeli/yaml | <https://github.com/eemeli/yaml> | ISC | Parser design ported into the in-tree `yamlpos` package |
| tree-sitter / web-tree-sitter | <https://github.com/tree-sitter/tree-sitter> | MIT | `run:` shell parsing (#113), bundled as a Worker runtime dependency |
| tree-sitter-bash | <https://github.com/tree-sitter/tree-sitter-bash> | MIT | Bash grammar for the shell-script rules (#113), bundled as a Worker runtime dependency |

Rule IDs in karinto are prefixed with `act-`, `ziz-`, or `ghl-` to indicate
which upstream linter the rule originated from. `cl-*` IDs are karinto-only.

If you only use rule **ideas / specifications**, MIT imposes no attribution
obligation. Once a karinto rule is implemented by translating upstream code
(e.g. the expression parser or shell-injection taint analysis), the
corresponding NOTICE block below applies and must be retained in any
redistribution of karinto.

---

## actionlint

```
MIT License

Copyright (c) 2021 rhysd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## zizmor

```
MIT License

Copyright (c) William Woodruff <william@yossarian.net>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ghalint

```
MIT License

Copyright (c) 2023 Shunsuke Suzuki

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## eemeli/yaml

karinto's in-tree `yamlpos` package is a MoonBit port of the parser design of
[eemeli/yaml](https://github.com/eemeli/yaml) (its layered lexer → offset-range
CST → composed AST, and the `LineCounter` lazy line/column resolution). The
MoonBit JS build inlines `yamlpos` into the Worker artifact, so the upstream ISC
attribution is reproduced here. (karinto no longer depends on
`moonbit-community/yaml`.)

```
ISC License

Copyright Eemeli Aro <eemeli@gmail.com>

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

## tree-sitter / web-tree-sitter

`web-tree-sitter` (the WASM runtime) and its `web-tree-sitter.wasm` engine are
bundled into the Worker artifact (`cf/`) to parse `run:` shell script bodies
for the shell rules added in #113 — see `shell-ts-adapter/`. `web-tree-sitter`
is patched locally (`patches/web-tree-sitter+0.26.12.patch`, applied via
`patch-package` on `npm install`) to let `Language.load` accept a precompiled
`WebAssembly.Module`, which workerd requires since it forbids compiling WASM
from raw bytes at runtime; the patch does not change the upstream license.

```
The MIT License (MIT)

Copyright (c) 2018 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## tree-sitter-bash

The Bash grammar `tree-sitter-bash.wasm` is bundled into the Worker artifact
alongside `web-tree-sitter` for the same shell rules.

```
The MIT License (MIT)

Copyright (c) 2017 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
