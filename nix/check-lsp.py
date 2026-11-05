"""Check an installed server without source-tree paths or initialization options."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


def frame(message):
    body = json.dumps(message).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def messages(data):
    while data:
        header, body = data.split(b"\r\n\r\n", 1)
        fields = dict(line.split(b":", 1) for line in header.split(b"\r\n"))
        length = int(fields[b"Content-Length"])
        yield json.loads(body[:length])
        data = body[length:]


def main():
    executable, stdlib = sys.argv[1:]
    with tempfile.TemporaryDirectory() as directory:
        uri = (Path(directory) / "main.goose").as_uri()
        requests = [
            {"id": 1, "method": "initialize", "params": {"capabilities": {}}},
            {"method": "initialized", "params": {}},
            {"method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": uri, "languageId": "goose", "version": 1,
                "text": "import std;\nlet value = clamp(3, 1, 9);\n",
            }}},
            {"id": 2, "method": "textDocument/definition", "params": {
                "textDocument": {"uri": uri}, "position": {"line": 1, "character": 12},
            }},
            {"id": 3, "method": "shutdown"},
            {"method": "exit"},
        ]
        wire = b"".join(frame(dict(message, jsonrpc="2.0")) for message in requests)
        result = subprocess.run(
            [executable, "--stdio"], cwd=directory, input=wire,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True,
        )
        replies = {message["id"]: message for message in messages(result.stdout) if "id" in message}
        definition = replies[2]["result"]
        if isinstance(definition, list):
            assert len(definition) == 1, definition
            definition = definition[0]
        expected = (Path(stdlib) / "std.goose").resolve().as_uri()
        actual = definition["uri"]
        # Resolve the standard-library symlink before comparison.
        assert Path(unquote(urlsplit(actual).path)).resolve().as_uri() == expected, actual
        assert replies[3]["result"] is None, replies[3]


if __name__ == "__main__":
    main()
