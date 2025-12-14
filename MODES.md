# ze Language Modes

[日本語](MODES.ja.md)

ze automatically detects the language mode based on file extension or filename. You can also manually set the mode with `M-x mode <name>`.

## Available Modes

| Mode | Extensions | Special Files |
|------|------------|---------------|
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

## Usage

```
M-x mode           Show current mode
M-x mode zig       Set mode to Zig
M-x mode python    Set mode to Python
M-x mode js        Set mode to JavaScript (partial match)
M-x mode py        Set mode to Python (extension match)
```

**Matching rules:**
- **Partial name match** (case-insensitive): `js` matches "JavaScript", `lisp` matches "Common Lisp"
- **Extension match**: `py`, `rs`, `go`, `ts` etc.

Note: Partial match finds first match in table order. `c` matches "C" (not C++ or C#).
