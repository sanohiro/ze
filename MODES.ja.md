# ze 言語モード一覧

[English](MODES.md)

zeはファイルの拡張子やファイル名から言語モードを自動検出します。`M-x mode <名前>` で手動設定も可能です。

## 利用可能なモード

| モード | 拡張子 | 特殊ファイル |
|--------|--------|--------------|
| AWK | `.awk` | |
| Apache | | `.htaccess`, `httpd.conf`, `apache.conf`, `apache2.conf` |
| C | `.c`, `.h` | |
| C# | `.cs` | |
| C++ | `.cpp`, `.cxx`, `.cc`, `.hpp`, `.hxx`, `.hh`, `.h++` | |
| CSS | `.css`, `.scss`, `.sass`, `.less` | |
| Clojure | `.clj`, `.cljs`, `.cljc`, `.edn` | `project.clj`, `deps.edn` |
| Common Lisp | `.lisp`, `.cl`, `.lsp`, `.asd`, `.asdf` | |
| Diff | `.diff`, `.patch` | |
| Dockerfile | | `Dockerfile`, `dockerfile`, `Containerfile` |
| Elixir | `.ex`, `.exs` | `mix.exs` |
| Emacs Lisp | `.el` | `.emacs`, `_emacs`, `.gnus` |
| Environment | `.env` | `.env`, `.env.local`, `.env.development`, `.env.production`, `.env.test`, `.env.example` |
| Erlang | `.erl`, `.hrl` | `rebar.config` |
| F# | `.fs`, `.fsi`, `.fsx` | |
| Gitignore | `.gitignore` | `.gitignore`, `.gitattributes`, `.gitmodules`, `.dockerignore`, `.npmignore`, `.eslintignore`, `.prettierignore` |
| Go | `.go` | |
| GraphQL | `.graphql`, `.gql` | |
| HTML | `.html`, `.htm`, `.xhtml` | |
| Haskell | `.hs`, `.lhs` | |
| INI | `.ini`, `.cfg`, `.conf` | `.gitconfig`, `.editorconfig` |
| JSON | `.json`, `.jsonc` | `package.json`, `tsconfig.json`, `composer.json` |
| Java | `.java` | |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` | |
| Kotlin | `.kt`, `.kts` | |
| Lua | `.lua` | |
| Makefile | `.mk` | `Makefile`, `makefile`, `GNUmakefile` |
| Markdown | `.md`, `.markdown`, `.mdown`, `.mkd` | `README`, `CHANGELOG`, `LICENSE` |
| Nginx | | `nginx.conf`, `mime.types` |
| OCaml | `.ml`, `.mli`, `.mll`, `.mly` | `dune`, `dune-project` |
| PHP | `.php`, `.phtml`, `.php3`, `.php4`, `.php5`, `.phps` | |
| Perl | `.pl`, `.pm`, `.t`, `.pod` | |
| Protocol Buffers | `.proto` | |
| Python | `.py`, `.pyw`, `.pyi` | |
| R | `.r`, `.R`, `.Rmd` | `.Rprofile` |
| Ruby | `.rb`, `.rake`, `.gemspec`, `.ru` | `Rakefile`, `Gemfile`, `Guardfile`, `Capfile` |
| Rust | `.rs` | |
| SQL | `.sql` | |
| Scala | `.scala`, `.sc` | `build.sbt` |
| Scheme | `.scm`, `.ss`, `.sld`, `.sls`, `.sps` | |
| Shell | `.sh`, `.bash`, `.zsh`, `.fish`, `.ksh` | `.bashrc`, `.zshrc`, `.profile`, `.bash_profile`, `.zprofile` |
| Swift | `.swift` | `Package.swift` |
| Systemd | `.service`, `.socket`, `.timer`, `.path`, `.mount`, `.automount`, `.target`, `.slice`, `.scope` | |
| TOML | `.toml` | `Cargo.toml`, `pyproject.toml` |
| Terraform | `.tf`, `.tfvars` | |
| Text | `.txt`, `.text`, `.log` | |
| TypeScript | `.ts`, `.tsx`, `.mts`, `.cts` | |
| Vim script | `.vim` | `.vimrc`, `.gvimrc`, `_vimrc`, `_gvimrc` |
| XML | `.xml`, `.xsl`, `.xslt`, `.svg`, `.xsd`, `.wsdl` | `pom.xml` |
| YAML | `.yml`, `.yaml` | |
| Zig | `.zig` | `build.zig`, `build.zig.zon` |

## 使い方

```
M-x mode           現在のモードを表示
M-x mode zig       Zigモードに設定
M-x mode python    Pythonモードに設定
M-x mode js        JavaScriptモードに設定（部分一致）
M-x mode py        Pythonモードに設定（拡張子一致）
```

**マッチングルール:**
- **名前の部分一致**（大文字小文字無視）: `js` → "JavaScript"、`lisp` → "Common Lisp"
- **拡張子一致**: `py`, `rs`, `go`, `ts` など

注: 部分一致は表の順序で最初にマッチしたものが選ばれます。`c` は "C"（C++やC#ではない）。
