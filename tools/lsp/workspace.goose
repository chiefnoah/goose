import slice_pool;

struct Document {
    uri: u8[:],
    source: u8[:],
    version: i64,
    active: bool = true,
}

struct Workspace {
    bytes: slice_pool<u8>&,
    documents: Document[>..]&,
    stdlib: const u8[:],
}

fn document(ws: Workspace&, uri: u8[:]) -> i64 {
    for d, i in ws.documents {
        if d.active && d.uri == uri { return i; }
    }
    return -1;
}

fn open_document(ws: Workspace&, uri: u8[:], source: u8[:], version: i64) {
    let existing = document(ws, uri);
    if existing >= 0 {
        let copy = ws.bytes.alloc_copy(source);
        ws.bytes.free_slice(ws.documents[existing].source);
        ws.documents[existing].source = copy;
        ws.documents[existing].version = version;
        return;
    }
    let saved_uri = ws.bytes.alloc_copy(uri);
    let saved_source = ws.bytes.alloc_copy(source);
    for &d in ws.documents {
        if d.active { continue; }
        d = Document { uri: saved_uri, source: saved_source, version: version };
        return;
    }
    ws.documents.push(Document { uri: saved_uri, source: saved_source, version: version });
}

fn close_document(ws: Workspace&, uri: u8[:]) {
    let i = document(ws, uri);
    if i < 0 { return; }
    ws.bytes.free_slice(ws.documents[i].source);
    ws.bytes.free_slice(ws.documents[i].uri);
    ws.documents[i].active = false;
}

fn change_document(ws: Workspace&, params: json::Node?) {
    let td = json::member(params, "textDocument");
    let i = document(ws, text(json::member(td, "uri")));
    let version = integer(json::member(td, "version"));
    if i < 0 || version <= ws.documents[i].version { return; }
    let changes = json::member(params, "contentChanges");
    if !changes { return; }

    // Apply the batch to a temporary value. Invalid edits leave the document intact.
    var current: u8[>..<] = [];
    current.append(ws.documents[i].source);
    var edit = changes.first;
    while edit {
        let replacement = json::member(edit, "text");
        let value, ok = json::as_string(replacement);
        if !ok { return; }
        let range = json::member(edit, "range");
        var start = 0;
        var end = current.len;
        if range {
            let first = json::member(range, "start");
            let last = json::member(range, "end");
            start = offset_at(current, integer(json::member(first, "line")), integer(json::member(first, "character")));
            end = offset_at(current, integer(json::member(last, "line")), integer(json::member(last, "character")));
        }
        if start < 0 || end < start { return; }
        var next: u8[>..] = [];
        next.append(current[..start]);
        next.append(value);
        next.append(current[end..]);
        current.clear();
        current.append(next);
        edit .= edit.next;
    }
    let copy = ws.bytes.alloc_copy(current);
    ws.bytes.free_slice(ws.documents[i].source);
    ws.documents[i].source = copy;
    ws.documents[i].version = version;
}

fn uri_path(uri: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if !starts_with(uri, "file:///") { return out; }
    var at = 7;
    while at < uri.len {
        if uri[at] == '%' && at + 2 < uri.len {
            let hi = ascii::hex_value(uri[at + 1]);
            let lo = ascii::hex_value(uri[at + 2]);
            if hi < 0 || lo < 0 { return []; }
            let c = (hi * 16 + lo) as u8;
            if c == 0 { return []; }
            out.push(c);
            at += 3;
        } else { out.push(uri[at]); at++; }
    }
    return out;
}

fn path_uri(path: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("file://");
    const HEX = "0123456789ABCDEF";
    for c in path {
        if ascii::is_alpha(c) || ascii::is_digit(c) || find("/-_.~:", [c]) >= 0 {
            out.push(c);
        } else {
            out.push('%'); out.push(HEX[c >> 4]); out.push(HEX[c & 15]);
        }
    }
    return out;
}

fn directory(path: u8[:]) -> u8[:] {
    var at = path.len;
    while at > 0 && path[at - 1] != '/' { at--; }
    return path[..at];
}

fn normal_path(path: u8[:]) -> u8[>..] {
    var parts: (const u8[:])[>..<] = [];
    for part in split(path, "/") {
        if part.len == 0 || part == "." { continue; }
        if part == ".." {
            if parts.len > 0 { parts.pop(); }
        } else { parts.push(part); }
    }
    var out: u8[>..] = [];
    for part in parts { out.push('/'); out.append(part); }
    return out;
}
