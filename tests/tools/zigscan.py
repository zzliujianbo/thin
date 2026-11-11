"""Small Zig lexical scanner for physical test extraction; offsets are Python string character offsets.

Unknown/malformed input raises ValueError instead of guessing. This is not a Zig AST
and must not be used to infer declaration reachability or remove declarations.
"""
from dataclasses import dataclass

@dataclass(frozen=True)
class Token:
    text: str
    start: int
    end: int


def scan(s):
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
            continue
        if s.startswith('//', i):
            end = s.find('\n', i)
            i = n if end < 0 else end
            continue
        # Zig multiline strings are one or more lines beginning with \\\\.
        if s.startswith('\\\\', i):
            start = i
            end = s.find('\n', i)
            i = n if end < 0 else end
            out.append(Token(s[start:i], start, i))
            continue
        if s.startswith('/*', i):
            raise ValueError('block comment syntax is not accepted by Zig scanner')
        start = i
        if c in ('"', "'") or (c == '@' and i + 1 < n and s[i + 1] == '"'):
            if c == '@':
                i += 1
                c = '"'
            i += 1
            while i < n:
                if s[i] == '\\':
                    i += 2
                elif s[i] == c:
                    i += 1
                    break
                elif s[i] in '\r\n':
                    raise ValueError(f'unterminated literal at {start}')
                else:
                    i += 1
            else:
                raise ValueError(f'unterminated literal at {start}')
        elif c.isascii() and (c.isalpha() or c == '_'):
            i += 1
            while i < n and s[i].isascii() and (s[i].isalnum() or s[i] == '_'):
                i += 1
        else:
            i += 1
        out.append(Token(s[start:i], start, i))
    return out


def pairs(tokens):
    stack, match = [], {}
    opening = {'{': '}', '[': ']', '(': ')'}
    for i, tok in enumerate(tokens):
        if tok.text in opening:
            stack.append((i, opening[tok.text]))
        elif tok.text in opening.values():
            if not stack or stack[-1][1] != tok.text:
                raise ValueError(f'unbalanced delimiter at {tok.start}')
            j, _ = stack.pop()
            match[j] = i
            match[i] = j
    if stack:
        raise ValueError('unclosed delimiter')
    return match


def containers(tokens, match):
    """Recognize named const/var struct containers, including nested containers."""
    found = []
    for i in range(len(tokens) - 4):
        if tokens[i].text not in ('const', 'var') or tokens[i+2].text != '=':
            continue
        if tokens[i+3].text not in ('struct', 'union', 'enum', 'opaque'):
            continue
        j = i + 4
        if j < len(tokens) and tokens[j].text == '(':
            j = match[j] + 1
        if j < len(tokens) and tokens[j].text == '{':
            found.append((tokens[i+1].text, j, match[j]))
    return found


def tests(s):
    t = scan(s)
    m = pairs(t)
    cs = containers(t, m)
    result = []
    for i, tok in enumerate(t):
        if tok.text != 'test':
            continue
        j = i + 1
        if j < len(t) and t[j].text.startswith('"'):
            j += 1
        if j >= len(t) or t[j].text != '{':
            raise ValueError(f'unrecognized test syntax at {tok.start}')
        enclosing = [(name, a, b) for name, a, b in cs if a < i < b]
        # Tests must be container members, not arbitrary nested tokens.
        containing_braces = [k for k in m if k < i < m[k] and t[k].text == '{']
        if len(containing_braces) != len(enclosing):
            raise ValueError(f'test in unsupported container at {tok.start}')
        enclosing.sort(key=lambda x: x[1])
        result.append((tok.start, t[m[j]].end, [x[0] for x in enclosing]))
    return result


def container_closing(s, path):
    if not path:
        return len(s)
    t = scan(s)
    m = pairs(t)
    cs = containers(t, m)
    lo, hi = -1, len(t)
    for name in path:
        matches = [(a, b) for n, a, b in cs if n == name and lo < a < b < hi]
        # Must be a direct child; ambiguous names fail closed.
        matches = [(a, b) for a, b in matches if not any(lo < x < a < b < y < hi for _, x, y in cs)]
        if len(matches) != 1:
            raise ValueError(f'container {path!r} not uniquely found')
        lo, hi = matches[0]
    return t[hi].start
