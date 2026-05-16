# Third-Party Licenses

curllint is licensed under Apache-2.0 (see `LICENSE`).

This project is **inspired by**, and in a handful of cases ports algorithms
from, the following projects. Their rule taxonomy, behaviour expectations, and
in some cases test fixtures were used as a specification. All three are
distributed under the MIT License; their license texts are reproduced below.

| Project | Repository | License |
| --- | --- | --- |
| actionlint | <https://github.com/rhysd/actionlint> | MIT |
| zizmor | <https://github.com/zizmorcore/zizmor> | MIT |
| ghalint | <https://github.com/suzuki-shunsuke/ghalint> | MIT |
| moonbit-community/yaml | <https://github.com/moonbit-community/yaml.mbt> | MIT |

Rule IDs in curllint are prefixed with `act-`, `ziz-`, or `ghl-` to indicate
which upstream linter the rule originated from. `cl-*` IDs are curllint-only.

If you only use rule **ideas / specifications**, MIT imposes no attribution
obligation. Once a curllint rule is implemented by translating upstream code
(e.g. the expression parser or shell-injection taint analysis), the
corresponding NOTICE block below applies and must be retained in any
redistribution of curllint.

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

## moonbit-community/yaml

curllint depends on this MIT-licensed MoonBit package at runtime; its license
file is shipped in `.mooncakes/moonbit-community/yaml/` after `moon` resolves
dependencies. The package itself is a MoonBit port of
[yaml-rust2](https://github.com/Ethiraric/yaml-rust2) (also MIT).
