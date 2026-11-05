# Build the C++ compiler first, then build the Goose LSP with that compiler.

all: goose-lsp

goose:V:
	cmake --build build --config Release --target goose

goose-lsp:V: goose
	build/goose build -o build/goose-lsp tools/lsp/main.goose
