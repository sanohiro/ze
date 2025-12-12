# ze Regular Expression Syntax

[日本語](REGEX.ja.md)

ze includes a simple built-in regex engine for search (`C-s`, `C-r`) and query-replace (`M-%`).

## Supported Syntax

### Basic Patterns

| Pattern | Description | Example |
|---------|-------------|---------|
| `.` | Any character (except newline) | `a.c` matches "abc", "a1c" |
| `*` | 0 or more (greedy) | `ab*c` matches "ac", "abc", "abbc" |
| `+` | 1 or more (greedy) | `ab+c` matches "abc", "abbc" (not "ac") |
| `?` | 0 or 1 | `colou?r` matches "color", "colour" |

### Anchors

| Pattern | Description | Example |
|---------|-------------|---------|
| `^` | Start of line | `^TODO` matches "TODO" at line start |
| `$` | End of line | `;$` matches ";" at line end |

### Character Classes

| Pattern | Description | Example |
|---------|-------------|---------|
| `[abc]` | Any of a, b, c | `[aeiou]` matches vowels |
| `[^abc]` | Not a, b, c | `[^0-9]` matches non-digits |
| `[a-z]` | Range a to z | `[A-Za-z]` matches letters |
| `[a-zA-Z0-9]` | Multiple ranges | Alphanumeric |

### Escape Sequences

| Pattern | Description | Equivalent |
|---------|-------------|------------|
| `\d` | Digit | `[0-9]` |
| `\D` | Non-digit | `[^0-9]` |
| `\w` | Word character | `[a-zA-Z0-9_]` |
| `\W` | Non-word character | `[^a-zA-Z0-9_]` |
| `\s` | Whitespace | `[ \t\n\r]` |
| `\S` | Non-whitespace | `[^ \t\n\r]` |
| `\n` | Newline | |
| `\r` | Carriage return | |
| `\t` | Tab | |
| `\\` | Literal backslash | |

### Escaping Special Characters

To match literal special characters, escape with `\`:

```
\.    matches "."
\*    matches "*"
\+    matches "+"
\?    matches "?"
\[    matches "["
\^    matches "^"
\$    matches "$"
```

## Examples

| Pattern | Matches |
|---------|---------|
| `\d+` | One or more digits: "123", "42" |
| `^TODO` | "TODO" at line start |
| `[A-Z][a-z]+` | Capitalized word: "Hello", "World" |
| `\w+@\w+\.\w+` | Simple email pattern |
| `^$` | Empty line |
| `\s+$` | Trailing whitespace |
| `//.*$` | C-style line comment |
| `"[^"]*"` | Double-quoted string |

## Not Supported

The following advanced regex features are **not** supported:

- `()` Capture groups
- `\1` Backreferences
- `(?=)` Lookahead
- `(?<=)` Lookbehind
- `|` Alternation (use multiple searches)
- `*?`, `+?` Non-greedy quantifiers
- `\b` Word boundary
- `{n,m}` Specific repetition counts

## Tips

1. **Literal search**: If your pattern contains no special characters, it's treated as a literal string search (faster).

2. **Case sensitive**: All searches are case-sensitive. For case-insensitive search, use character classes like `[Tt]odo`.

3. **Greedy matching**: `*` and `+` are greedy (match as much as possible). For example, `".*"` on `"a" and "b"` matches the entire string, not just `"a"`.

4. **Line-oriented**: `^` and `$` match line boundaries, not just buffer start/end.
