"""Protocol tests for the standalone Goose server. No editor or packages are required."""

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "build/goose-lsp"
TIMEOUT = 10


class Client:
    def __init__(self):
        self.process = subprocess.Popen(
            [str(SERVER), "--stdio", "--stdlib", str(ROOT / "stdlib")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.sequence = 0
        self.buffer = b""

    def write(self, message):
        body = json.dumps(message, ensure_ascii=False).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def send(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        self.sequence += 1
        message["id"] = self.sequence
        self.write(message)

    def notify(self, method, params=None):
        self.write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def read(self):
        deadline = time.monotonic() + TIMEOUT

        def receive():
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise AssertionError("The server did not reply.")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError("The server closed stdout: " + self.process.stderr.read().decode())
            self.buffer += chunk

        while b"\r\n\r\n" not in self.buffer:
            receive()
        headers, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        length = int(headers.split(b":", 1)[1])
        while len(self.buffer) < length:
            receive()
        body, self.buffer = self.buffer[:length], self.buffer[length:]
        return json.loads(body)

    def request(self, method, params=None):
        self.send(method, params)
        result = self.read()
        assert result["id"] == self.sequence, result
        assert "error" not in result, result
        return result["result"]

    def open(self, uri, source):
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": uri, "text": source, "version": 1, "languageId": "goose",
        }})

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=TIMEOUT)


def position(uri, source, needle, occurrence=0):
    start = -1
    for _ in range(occurrence + 1):
        start = source.index(needle, start + 1)
    prefix = source[:start]
    return {"textDocument": {"uri": uri}, "position": {
        "line": prefix.count("\n"),
        "character": len(prefix.rsplit("\n", 1)[-1].encode("utf-16-le")) // 2,
    }}


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.client = Client()
        self.addCleanup(self.client.close)
        self.directory = tempfile.TemporaryDirectory(prefix="goose-lsp-", dir=ROOT / "build")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "main.goose"
        self.uri = self.path.as_uri()
        self.capabilities = self.client.request("initialize")["capabilities"]

    def query(self, method, source, needle, occurrence=0, **extra):
        params = position(self.uri, source, needle, occurrence)
        params.update(extra)
        return self.client.request("textDocument/" + method, params)

    def test_capabilities_and_docs(self):
        for name in ("definitionProvider", "referencesProvider", "hoverProvider", "inlayHintProvider"):
            self.assertTrue(self.capabilities[name])
        source = "// Add two values.\nfn add(left: i64, right: i64) -> i64 { left + right }\nlet result = add(1, 2);\n"
        self.client.open(self.uri, source)
        definition = self.query("definition", source, "add(1")
        self.assertEqual(definition[0]["range"]["start"], {"line": 1, "character": 3})
        hover = self.query("hover", source, "add(1")
        self.assertIn("Add two values.", hover["contents"]["value"])
        self.assertIn("fn add(left: i64, right: i64) -> i64", hover["contents"]["value"])
        refs = self.query("references", source, "add(1", context={"includeDeclaration": False})
        self.assertEqual(len(refs), 1)
        refs = self.query("references", source, "add(1", context={"includeDeclaration": True})
        self.assertEqual(len(refs), 2)
        hints = self.client.request("textDocument/inlayHint", {
            "textDocument": {"uri": self.uri},
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 3, "character": 0}},
        })
        self.assertEqual([h["label"] for h in hints], ["left:", "right:"])

    def test_scopes_and_literals(self):
        source = ('fn f(value: i64) -> i64 {\n'
                  '  let local = value;\n'
                  '  { let value = 2; print(value); }\n'
                  '  // value local\n'
                  '  let text = "value local";\n'
                  '  /* value /* local */ value */\n'
                  '  let raw = """value local""";\n'
                  '  local + value\n}\n')
        self.client.open(self.uri, source)
        definition = self.query("definition", source, "value);", 0)
        self.assertEqual(definition[0]["range"]["start"], {"line": 2, "character": 8})
        refs = self.query("references", source, "value:", context={"includeDeclaration": True})
        self.assertEqual([r["range"]["start"]["line"] for r in refs], [0, 1, 7])
        self.assertEqual(self.query("definition", source, "value local"), [])

    def test_imports_unsaved_and_close(self):
        helper = self.path.with_name("helper.goose")
        helper.write_text("// Read the disk value.\nfn answer() -> i64 { 42 }\n")
        source = "import .helper;\nlet result = answer();\n"
        self.client.open(self.uri, source)
        definition = self.query("definition", source, "answer")
        self.assertEqual(definition[0]["uri"], helper.as_uri())
        imported = self.query("definition", source, "helper")
        self.assertEqual(imported[0]["uri"], helper.as_uri())
        self.assertIn("disk value", self.query("hover", source, "answer")["contents"]["value"])
        self.client.open(helper.as_uri(), "// Read the editor value.\nfn answer() -> i64 { 12 }\n")
        self.assertIn("editor value", self.query("hover", source, "answer")["contents"]["value"])
        refs = self.query("references", source, "answer", context={"includeDeclaration": True})
        self.assertEqual(len(refs), 2)
        self.client.notify("textDocument/didClose", {"textDocument": {"uri": helper.as_uri()}})
        self.assertIn("disk value", self.query("hover", source, "answer")["contents"]["value"])

    def test_incremental_utf16_and_versions(self):
        source = 'fn target() {}\nlet text = "🪿"; target();\n'
        self.client.open(self.uri, source)
        self.assertEqual(self.query("definition", source, "target();")[0]["range"]["start"],
                         {"line": 0, "character": 3})
        call = position(self.uri, source, "target();")["position"]
        end = dict(call, character=call["character"] + len("target"))
        self.client.notify("textDocument/didChange", {
            "textDocument": {"uri": self.uri, "version": 2},
            "contentChanges": [{"range": {"start": call, "end": end}, "text": "missing"}],
        })
        source = source.replace("target();", "missing();")
        self.assertEqual(self.query("definition", source, "missing"), [])
        self.client.notify("textDocument/didChange", {
            "textDocument": {"uri": self.uri, "version": 1},
            "contentChanges": [{"text": "fn missing() {}"}],
        })
        self.assertEqual(self.query("definition", source, "missing"), [])

    def test_fields_and_unrelated_files(self):
        source = "struct Point { x: i64 }\nfn get(p: Point) -> i64 { p.x }\n"
        self.client.open(self.uri, source)
        self.client.open(self.path.with_name("unrelated.goose").as_uri(), "fn get() {}\nget();\n")
        definition = self.query("definition", source, "x }")
        self.assertEqual(definition[0]["range"]["start"], {"line": 0, "character": 15})
        refs = self.query("references", source, "get(", context={"includeDeclaration": True})
        self.assertEqual(len(refs), 1)

    def test_lifecycle_and_errors(self):
        self.client.send("unknown")
        self.assertEqual(self.client.read()["error"]["code"], -32601)
        self.client.write({"jsonrpc": "2.0", "id": "string-id", "method": "textDocument/hover"})
        response = self.client.read()
        self.assertEqual(response["id"], "string-id")
        self.assertEqual(response["error"]["code"], -32602)
        self.assertIsNone(self.client.request("shutdown"))
        self.client.send("textDocument/hover")
        self.assertEqual(self.client.read()["error"]["code"], -32600)
        self.client.notify("exit")
        self.assertEqual(self.client.process.wait(timeout=TIMEOUT), 0)

    def test_namespaces_and_generic_parameters(self):
        first = self.path.with_name("first.goose")
        second = self.path.with_name("second.goose")
        first.write_text("namespace first;\nfn same<T>(x: T) -> T { x }\n")
        second.write_text("namespace second;\nfn same() -> i64 { 2 }\n")
        source = "import .first;\nimport .second;\nlet value = first::same(1);\n"
        self.client.open(self.uri, source)
        definition = self.query("definition", source, "same(1")
        self.assertEqual(definition[0]["uri"], first.as_uri())
        self.client.open(first.as_uri(), first.read_text())
        params = position(first.as_uri(), first.read_text(), "T { x")
        generic = self.client.request("textDocument/definition", params)
        self.assertEqual(generic[0]["range"]["start"], {"line": 1, "character": 8})

    def test_invalid_requests_and_positions(self):
        self.client.write({"jsonrpc": "2.0", "id": 900, "method": 42})
        self.assertEqual(self.client.read()["error"]["code"], -32600)
        self.client.write([1, 2, 3])
        self.assertEqual(self.client.read()["error"]["code"], -32600)
        source = "fn target() {}\ntarget();\n"
        self.client.open(self.uri, source)
        self.client.send("textDocument/definition", {
            "textDocument": {"uri": self.uri}, "position": {"line": -1, "character": 0},
        })
        self.assertEqual(self.client.read()["error"]["code"], -32602)

    def test_nested_default_arguments(self):
        source = "fn make(x: i64) -> i64 { x }\nfn use(value: i64 = make(2), other: i64 = 3) {}\nuse(1, 2);\n"
        self.client.open(self.uri, source)
        hints = self.client.request("textDocument/inlayHint", {
            "textDocument": {"uri": self.uri},
            "range": {"start": {"line": 2, "character": 0}, "end": {"line": 3, "character": 0}},
        })
        self.assertEqual([h["label"] for h in hints], ["value:", "other:"])

    def test_import_cycles_and_encoded_paths(self):
        helper = self.path.with_name("hé lper.goose")
        helper.write_text("import .main;\nfn answer() -> i64 { 42 }\n")
        # An unsaved file can import itself without duplicate definitions.
        source = "import .main;\nfn target() {}\ntarget();\n"
        self.client.open(self.uri, source)
        self.assertEqual(len(self.query("definition", source, "target();")), 1)
        self.client.open(helper.as_uri(), helper.read_text())
        params = {
            "textDocument": {"uri": helper.as_uri()}, "position": {"line": 1, "character": 3},
        }
        self.assertEqual(self.client.request("textDocument/definition", params)[0]["uri"], helper.as_uri())

    def test_standard_library(self):
        source = "import std;\nlet n = clamp(3, 1, 9);\n"
        self.client.open(self.uri, source)
        definition = self.query("definition", source, "clamp")
        self.assertEqual(definition[0]["uri"], (ROOT / "stdlib/std.goose").as_uri())

    def test_fragmented_frames_and_parse_error(self):
        body = b'{"jsonrpc":"2.0","id":"fragment","method":"unknown"}'
        wire = b"content-length: %d\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" % len(body) + body
        for start in range(0, len(wire), 3):
            self.client.process.stdin.write(wire[start:start + 3])
            self.client.process.stdin.flush()
        response = self.client.read()
        self.assertEqual(response["id"], "fragment")
        self.assertEqual(response["error"]["code"], -32601)
        self.client.process.stdin.write(b"Content-Length: 1\r\n\r\n{")
        self.client.process.stdin.flush()
        self.assertEqual(self.client.read()["error"]["code"], -32700)
        self.assertIsNone(self.client.request("shutdown"))

    def test_invalid_edits_and_full_changes(self):
        source = "fn target() {}\ntarget();\n"
        self.client.open(self.uri, source)
        self.client.notify("textDocument/didChange", {
            "textDocument": {"uri": self.uri, "version": 2},
            "contentChanges": [{"range": {"start": {"line": 80, "character": 0},
                                          "end": {"line": 80, "character": 0}}, "text": "bad"}],
        })
        self.assertEqual(len(self.query("definition", source, "target();")), 1)
        self.client.notify("textDocument/didChange", {
            "textDocument": {"uri": self.uri, "version": 2},
            "contentChanges": [{"text": "fn changed() {}\nchanged();\n"}],
        })
        self.assertEqual(len(self.query("definition", "fn changed() {}\nchanged();\n", "changed();")), 1)

    def test_oversized_frame(self):
        self.client.process.stdin.write(b"Content-Length: 16777217\r\n\r\n")
        self.client.process.stdin.flush()
        self.assertEqual(self.client.process.wait(timeout=TIMEOUT), 1)

    def test_oversized_header(self):
        self.client.process.stdin.write(b"X-Extra: " + b"a" * 8192 + b"\r\nContent-Length: 2\r\n\r\n{}")
        self.client.process.stdin.flush()
        self.assertEqual(self.client.process.wait(timeout=TIMEOUT), 1)

    def test_incomplete_code(self):
        source = "fn use(value: i64) {\n let local = value;\n local\n"
        self.client.open(self.uri, source)
        self.assertEqual(self.query("definition", source, "local", 1)[0]["range"]["start"],
                         {"line": 1, "character": 5})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=SERVER)
    options, remaining = parser.parse_known_args()
    SERVER = options.server.resolve()
    unittest.main(argv=[__file__, *remaining])
