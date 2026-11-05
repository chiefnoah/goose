# Goose language server in Goose

This standalone server uses Goose and its standard library. It does not call the C++ language server or compiler analysis APIs.
The existing `goose lsp` command remains unchanged.

## Build

The [Nix packages](../../docs/nix.md) include this server as `goose-lsp` and the C++ server as `goose-lsp-cpp`.

From the repository root, build both the C++ compiler and this server with Plan 9 `mk`:

```sh
mk
```

The `goose` target builds the compiler. The `goose-lsp` target builds the compiler first, then builds this server.

From the repository root, build the executable:

```sh
build/goose build -o build/goose-lsp tools/lsp/main.goose
```

On macOS, select Apple Clang if the default C compiler fails:

```sh
build/goose build --cc /usr/bin/clang -o build/goose-lsp tools/lsp/main.goose
```

Start the server through your editor. The command is:

```sh
/absolute/path/to/build/goose-lsp --stdio --stdlib /absolute/path/to/stdlib
```

`--stdlib` takes one absolute directory. Without this option, the server uses `GOOSE_STDLIB` or the standard library near the executable.
The server uses stdin and stdout for LSP messages. It does not present an interactive prompt.

## Editor configuration

For Neovim 0.11, add this configuration:

```lua
vim.filetype.add({ extension = { goose = 'goose' } })
vim.lsp.config('goose_native', {
  cmd = {
    '/absolute/path/to/build/goose-lsp', '--stdio',
    '--stdlib', '/absolute/path/to/stdlib',
  },
  filetypes = { 'goose' },
  root_markers = { '.git' },
})
vim.lsp.enable('goose_native')
vim.lsp.inlay_hint.enable(true)
```

Use only one Goose server for a buffer. Other editors can use the same command through their LSP client.

## Features

- Go to definition for functions, types, variables, parameters, generic parameters, fields, and enum variants.
- Go to definition on local and standard-library imports.
- Find references, with optional declaration locations.
- Hover with the declaration and adjacent `//` documentation.
- Parameter-name hints for direct function calls.
- Full and incremental document changes, with UTF-16 positions.
- Lexical scopes, simple namespace qualifiers, and incomplete function bodies.

The server follows imports from open files. Unsaved editor text takes precedence over disk files.
It reads imported disk files again for each request. It does not fetch packages or execute workspace code.

## Limits

This first version uses a source index, not a complete Goose parser or type checker.
It does not provide compiler diagnostics, type inference, completion, rename, or overload resolution.
Ambiguous function names return no definition instead of a guessed location.

Field resolution requires a variable or parameter with a named type annotation, or a direct enum name.
It does not resolve inferred receivers, chained receivers, aliases to receiver types, or extension methods.
Hints cover direct calls without explicit generic arguments. They do not infer types.

Imports support `import a.b;` and `import .a.b;`.
Root-relative imports use the initial file directory. Standard-library imports use the standard-library directory.
Package declarations, package sidecars, and configured entry files are not supported.
References cover open files and their imports, not unopened programs elsewhere in the workspace.

The server rebuilds the index for each request. It limits each message to 16 MiB, headers to 8 KiB, and each index to 512 files.
It reuses document storage after changes and closes. It does not retain old indexes.

## Tests

Build the server first. Then run the protocol tests:

```sh
python3 test/lsp_goose.py --server build/goose-lsp
```

The tests cover definitions, references, documentation, hints, scopes, imports, unsaved text, Unicode, edits, malformed messages, and shutdown.

## Modules

| File | Responsibility |
| --- | --- |
| `protocol.goose` | Message frames, JSON-RPC replies, and source positions. |
| `workspace.goose` | Open documents, edits, reusable storage, and file URI conversion. |
| `index.goose` | Source tokens, scopes, declarations, imports, and name resolution. |
| `features.goose` | Definition locations, hover text, references, and hints. |
| `main.goose` | Server lifecycle and request dispatch. |
