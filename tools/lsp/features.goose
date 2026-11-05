fn location(out: u8[>..]&, ix: Index&, token: i64) {
    let t = ix.tokens[token];
    let file = ix.files[t.file];
    out.append("{\"uri\":");
    json::format_string(out, file.uri);
    out.append(",\"range\":");
    write_range(out, file.source, t.start, t.end);
    out.push('}');
}

fn documentation(source: u8[:], start: i64) -> u8[>..] {
    var line = start;
    while line > 0 && source[line - 1] != '\n' { line--; }
    var first = line;
    while first > 0 {
        var end = first - 1;
        if end > 0 && source[end - 1] == '\r' { end--; }
        var begin = end;
        while begin > 0 && source[begin - 1] != '\n' { begin--; }
        if !starts_with(trim(source[begin..end]), "//") { break; }
        first = begin;
    }
    var out: u8[>..] = [];
    for part in split(source[first..line], "\n") {
        let stripped = trim(part);
        if !starts_with(stripped, "//") { continue; }
        if out.len > 0 { out.push('\n'); }
        out.append(trim(stripped[2..]));
    }
    return out;
}

fn hover(out: u8[>..]&, ix: Index&, token: i64) {
    let id = resolve(ix, token);
    if id < 0 { out.append("null"); return; }
    let symbol = ix.symbols[id];
    let t = ix.tokens[symbol.token];
    let source = ix.files[t.file].source;
    var markdown: u8[>..] = [];
    markdown.append("```goose\n");
    markdown.append(trim(source[symbol.header_start..symbol.header_end]));
    markdown.append("\n```");
    let docs = documentation(source, symbol.header_start);
    if docs.len > 0 { markdown.append("\n\n"); markdown.append(docs); }
    out.append("{\"contents\":{\"kind\":\"markdown\",\"value\":");
    json::format_string(out, markdown);
    out.append("},\"range\":");
    let use = ix.tokens[token];
    write_range(out, ix.files[use.file].source, use.start, use.end);
    out.push('}');
}

fn references(out: u8[>..]&, ix: Index&, token: i64, params: json::Node?) {
    out.push('[');
    let id = resolve(ix, token);
    if id >= 0 {
        let context = json::member(params, "context");
        let include, ok = json::as_bool(json::member(context, "includeDeclaration"));
        var count = 0;
        let name = ix.tokens[ix.symbols[id].token].word;
        for t, i in ix.tokens {
            if t.word != name || (!include && t.declaration >= 0) { continue; }
            if resolve(ix, i) != id { continue; }
            if count > 0 { out.push(','); }
            location(out, ix, i);
            count++;
        }
    }
    out.push(']');
}

// Parameter hints need no speculative type inference.
fn inlay_hints(out: u8[>..]&, ix: Index&, file: i64, params: json::Node?) {
    let range = json::member(params, "range");
    let first = json::member(range, "start");
    let last = json::member(range, "end");
    let source = ix.files[file].source;
    let start = offset_at(source, integer(json::member(first, "line")), integer(json::member(first, "character")));
    let end = offset_at(source, integer(json::member(last, "line")), integer(json::member(last, "character")));
    out.push('[');
    var count = 0;
    let src = ix.files[file];
    for i in src.first..src.end {
        if word_at(ix, i) != "(" || i == src.first { continue; }
        let callee = i - 1;
        if ix.tokens[callee].declaration >= 0 { continue; }
        let fn_id = resolve(ix, callee);
        if fn_id < 0 || ix.symbols[fn_id].kind != SymbolKind.Function { continue; }
        let close = ix.tokens[i].pair;
        if close < 0 { continue; }
        var arg = i + 1;
        for param in ix.symbols {
            if param.parent != fn_id || param.kind != SymbolKind.Parameter { continue; }
            if arg >= close { break; }
            let t = ix.tokens[arg];
            if t.start >= start && t.start < end {
                if count > 0 { out.push(','); }
                out.append("{\"position\":");
                write_position(out, source, t.start);
                out.append(",\"kind\":2,\"paddingRight\":true,\"label\":");
                json::format_string(out, str(ix.tokens[param.token].word, ":"));
                out.push('}');
                count++;
            }
            while arg < close && word_at(ix, arg) != "," {
                if ix.tokens[arg].pair > arg { arg = ix.tokens[arg].pair; }
                arg++;
            }
            arg++;
        }
    }
    out.push(']');
}
