import std;
import os;
import json;

const MAX_MESSAGE = 16777216;
const MAX_HEADER_BYTES = 8192;
const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const NOT_INITIALIZED = -32002;

fn text(n: json::Node?) -> const u8[:] {
    let value, ok = json::as_string(n);
    return if ok { value } else { "" };
}

fn integer(n: json::Node?) -> i64 {
    let value, ok = json::as_i64(n);
    return if ok { value } else { -1 };
}

// Bound each frame before allocation. Never write logs to the protocol stream.
fn read_frame(out: u8[>..]&) -> bool {
    var length = -1;
    var header_bytes = 0;
    loop {
        var line: u8[>..] = [];
        loop {
            if header_bytes >= MAX_HEADER_BYTES || !read_stdin(line, 1) { return false; }
            header_bytes++;
            if line[line.len - 1] == '\n' { break; }
        }
        let header = trim(line);
        if header.len == 0 { break; }
        let colon = find(header, ":");
        if colon < 0 { return false; }
        var name = str(trim(header[..colon]));
        to_lower(name);
        if name == "content-length" {
            if length >= 0 { return false; }
            let size, ok = parse_int(trim(header[colon + 1..]));
            if !ok || size < 0 || size > MAX_MESSAGE { return false; }
            length = size;
        }
    }
    if length < 0 { return false; }
    while out.len < length {
        if !read_stdin(out, length - out.len) { return false; }
    }
    return true;
}

fn send_frame(body: u8[:]) {
    write_stdout(str("Content-Length: ", body.len, "\r\n\r\n"));
    write_stdout(body);
    flush_stdout();
}

fn write_id(out: u8[>..]&, id: json::Node?) {
    if id {
        match id.val {
            Int v => { format(out, v.v); return; },
            Str v => { json::format_string(out, v.s); return; },
            _ => {},
        }
    }
    out.append("null");
}

fn reply(id: json::Node?, result: u8[:]) {
    var out: u8[>..] = [];
    out.append("{\"jsonrpc\":\"2.0\",\"id\":");
    write_id(out, id);
    out.append(",\"result\":");
    out.append(result);
    out.push('}');
    send_frame(out);
}

fn error_reply(id: json::Node?, code: i64, message: u8[:]) {
    var out: u8[>..] = [];
    out.append("{\"jsonrpc\":\"2.0\",\"id\":");
    write_id(out, id);
    format(out, ",\"error\":{\"code\":", code, ",\"message\":");
    json::format_string(out, message);
    out.append("}}");
    send_frame(out);
}

// LSP positions count UTF-16 code units, not UTF-8 bytes.
fn utf_width(c: u8) -> i64 {
    if c < 0x80 { return 1; }
    if c < 0xE0 { return 2; }
    if c < 0xF0 { return 3; }
    return 4;
}

fn offset_at(source: u8[:], line: i64, character: i64) -> i64 {
    if line < 0 || character < 0 { return -1; }
    var at = 0;
    var row = 0;
    while at < source.len && row < line {
        if source[at] == '\n' { row++; }
        at++;
    }
    if row != line { return -1; }
    var column = 0;
    while at < source.len && source[at] != '\n' && source[at] != '\r' && column < character {
        let width = utf_width(source[at]);
        column += if width == 4 { 2 } else { 1 };
        at = min(at + width, source.len);
    }
    if column != character { return -1; }
    return at;
}

fn write_position(out: u8[>..]&, source: u8[:], offset: i64) {
    var at = 0;
    var line = 0;
    var column = 0;
    while at < min(offset, source.len) {
        if source[at] == '\n' { line++; column = 0; at++; continue; }
        let width = utf_width(source[at]);
        column += if width == 4 { 2 } else { 1 };
        at = min(at + width, source.len);
    }
    format(out, "{\"line\":", line, ",\"character\":", column, "}");
}

fn write_range(out: u8[>..]&, source: u8[:], start: i64, end: i64) {
    out.append("{\"start\":");
    write_position(out, source, start);
    out.append(",\"end\":");
    write_position(out, source, end);
    out.push('}');
}
