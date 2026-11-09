---
"karinto": patch
---

Track zizmor 1.32.0: `obfuscation` no longer flags a constant expression whose string literals can join into `${{` (for example `${{ '${{' }}` or `${{ format('{0}{1}', '$', '{{') }}`), since replacing it by its value would create another expression. Literals such as `'$'` or `'a}}b'` are still flagged.
