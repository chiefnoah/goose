# Nix packages

The flake provides three packages:

| Package | Executable | Contents |
| --- | --- | --- |
| `goose` | `goose` | The compiler, standard library, and TinyCC runtime. |
| `goose-lsp` | `goose-lsp` | The language server written in Goose. |
| `goose-lsp-cpp` | `goose-lsp-cpp` | A wrapper for the compiler command `goose lsp`. |

The default package is `goose`. Packages support Apple Silicon macOS, ARM64 Linux, and x86-64 Linux.
The pinned nixpkgs revision does not support Intel macOS.

## Build

From the repository root, build the compiler and both servers:

```sh
nix build path:.#goose path:.#goose-lsp path:.#goose-lsp-cpp
```

This command also includes untracked source files. The outputs appear at `result`, `result-1`, and `result-2`.
The Goose server build uses the packaged Goose compiler first.
The compiler package includes no optional graphics, audio, UI, or physics packages.

## Run

Run the compiler:

```sh
nix run path:.#goose -- --version
```

Start either server through an editor with one of these commands:

```sh
nix run path:.#goose-lsp -- --stdio
nix run path:.#goose-lsp-cpp -- --stdio
```

Both servers use stdin and stdout for LSP messages. Both packages locate the installed standard library without a source checkout.
The compiler includes the TinyCC runtime for `goose run`. Native executable builds still need a C compiler on `PATH`.

## Tests

Build all packages and run their checks:

```sh
nix flake check path:.
```

The compiler check covers standard-library discovery and TinyCC execution outside the source tree.
The Goose server check runs its protocol suite against the installed executable.
Both server checks cover standard-library navigation outside the source tree. The C++ server check also checks the protocol probe through its wrapper.

## Development shell

Enter the existing compiler environment:

```sh
nix develop path:.
```
