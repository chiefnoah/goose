enum TokenKind { Name, Literal, Punct }
enum SymbolKind { Function, Type, Variable, Parameter, Field, Variant, Generic }

struct Source {
    uri: const u8[:],
    path: const u8[:],
    source: const u8[:],
    base: const u8[:] = "",
    first: i64 = 0,
    end: i64 = 0,
    scope: i64 = -1,
    ns: const u8[:] = "",
}
struct Token {
    word: const u8[:],
    start: i64,
    end: i64,
    file: i64,
    scope: i64,
    kind: TokenKind,
    pair: i64 = -1,
    declaration: i64 = -1,
}
struct Scope { parent: i64, file: i64 }
struct Symbol {
    token: i64,
    scope: i64,
    kind: SymbolKind,
    parent: i64 = -1,
    type_name: const u8[:] = "",
    ns: const u8[:] = "",
    header_start: i64,
    header_end: i64,
}
struct Import { from: i64, to: i64, first: i64, last: i64 }
const MAX_FILES = 512;
struct Index {
    files: Source[>..]&,
    tokens: Token[>..]&,
    scopes: Scope[>..]&,
    symbols: Symbol[>..]&,
    imports: Import[>..]&,
    storage: u8[>..]&,
}

fn save_text(ix: Index&, value: u8[:]) -> const u8[:] {
    let start = ix.storage.len;
    ix.storage.append(value);
    return ix.storage[start..];
}

fn source_file(ix: Index&, ws: Workspace&, path: u8[:], base: u8[:]) -> i64 {
    let normalized = normal_path(path);
    for f, i in ix.files { if f.path == normalized { return i; } }
    if ix.files.len >= MAX_FILES { return -1; }
    let uri = path_uri(normalized);
    let open = document(ws, uri);
    var contents: u8[>..] = [];
    if open >= 0 { contents.append(ws.documents[open].source); }
    else if !read_file(normalized, contents) { return -1; }
    let saved_uri = save_text(ix, uri);
    let saved_path = save_text(ix, normalized);
    let saved_source = save_text(ix, contents);
    let saved_base = save_text(ix, base);
    let id = ix.files.len;
    ix.files.push(Source { uri: saved_uri, path: saved_path, source: saved_source, base: saved_base });
    return id;
}

// Follow local and standard-library imports only. Never fetch or execute packages.
fn load_imports(ix: Index&, ws: Workspace&, file: i64) {
    let src = ix.files[file];
    for i in src.first..src.end {
        if word_at(ix, i) != "import" { continue; }
        var path: u8[>..] = [];
        var p = i + 1;
        let relative = word_at(ix, p) == ".";
        if relative { p++; }
        var valid = true;
        while p < src.end && word_at(ix, p) != ";" {
            let t = ix.tokens[p];
            if t.word == "." { path.push('/'); }
            else if t.kind == TokenKind.Name && t.word != "from" { path.append(t.word); }
            else { valid = false; break; }
            p++;
        }
        if !valid || path.len == 0 { continue; }
        path.append(".goose");
        let base = if relative { directory(src.path) } else { src.base };
        var target = source_file(ix, ws, str(base, "/", path), src.base);
        if target < 0 && !relative && ws.stdlib.len > 0 {
            target = source_file(ix, ws, str(ws.stdlib, "/", path), ws.stdlib);
        }
        if target >= 0 { ix.imports.push(Import { from: file, to: target, first: i, last: p }); }
    }
}

fn name_start(c: u8) -> bool { ascii::is_alpha(c) || c == '_' || c >= 0x80 }
fn name_part(c: u8) -> bool { name_start(c) || ascii::is_digit(c) }

// Keep source extents even for incomplete code. Ignore names in comments and literals.
fn lex(ix: Index&, file: i64) {
    let source = ix.files[file].source;
    ix.files[file].first = ix.tokens.len;
    var scope = ix.scopes.len;
    ix.scopes.push(Scope { parent: -1, file: file });
    ix.files[file].scope = scope;
    var stack: i64[>..<] = [];
    var at = 0;
    while at < source.len {
        let c = source[at];
        if c == ' ' || c == '\r' || c == '\n' || c == '\t' { at++; continue; }
        if starts_with(source[at..], "//") {
            while at < source.len && source[at] != '\n' { at++; }
            continue;
        }
        if starts_with(source[at..], "/*") {
            at += 2;
            var depth = 1;
            while at < source.len && depth > 0 {
                if starts_with(source[at..], "/*") { depth++; at += 2; }
                else if starts_with(source[at..], "*/") { depth--; at += 2; }
                else { at++; }
            }
            continue;
        }
        let start = at;
        var kind = TokenKind.Punct;
        if name_start(c) {
            kind = TokenKind.Name;
            at++;
            while at < source.len && name_part(source[at]) { at++; }
        } else if c == '"' || c == '\'' {
            kind = TokenKind.Literal;
            if starts_with(source[at..], "\"\"\"") {
                at += 3;
                while at < source.len && !starts_with(source[at..], "\"\"\"") { at++; }
                at = min(at + 3, source.len);
            } else {
                at++;
                while at < source.len {
                    let next = source[at];
                    at++;
                    if next == '\\' { at = min(at + 1, source.len); continue; }
                    if next == c { break; }
                }
            }
        } else if ascii::is_digit(c) {
            kind = TokenKind.Literal;
            at++;
            while at < source.len && (name_part(source[at]) || source[at] == '.') { at++; }
        } else {
            at++;
            for op in ["::", "->", "=>", "..", ".=", "==", "!=", "<=", ">=", "&&", "||"] {
                if starts_with(source[start..], op) { at = start + op.len; break; }
            }
        }
        let word = source[start..at];
        let id = ix.tokens.len;
        ix.tokens.push(Token { word: word, start: start, end: at, file: file, scope: scope, kind: kind });
        if word == "{" || word == "(" || word == "[" {
            stack.push(id);
            if word == "{" {
                let child = ix.scopes.len;
                ix.scopes.push(Scope { parent: scope, file: file });
                scope = child;
            }
        } else if word == "}" || word == ")" || word == "]" {
            if stack.len == 0 { continue; }
            let open = stack[stack.len - 1];
            let opener = ix.tokens[open].word;
            if (opener == "{" && word != "}") || (opener == "(" && word != ")") || (opener == "[" && word != "]") { continue; }
            stack.pop();
            ix.tokens[id].pair = open;
            ix.tokens[open].pair = id;
            if word == "}" { scope = ix.scopes[scope].parent; }
        }
    }
    ix.files[file].end = ix.tokens.len;
}

fn word_at(ix: Index&, i: i64) -> const u8[:] {
    if i < 0 || i >= ix.tokens.len { return ""; }
    return ix.tokens[i].word;
}

fn declare(ix: Index&, token: i64, scope: i64, kind: SymbolKind, parent: i64, start: i64, end: i64) -> i64 {
    let id = ix.symbols.len;
    ix.tokens[token].declaration = id;
    ix.symbols.push(Symbol { token: token, scope: scope, kind: kind, parent: parent,
                            ns: ix.files[ix.tokens[token].file].ns, header_start: start, header_end: end });
    if word_at(ix, token + 1) == ":" {
        var first = token + 2;
        if word_at(ix, first) == "const" { first++; }
        var last = first;
        while word_at(ix, last + 1) == "::" && last + 2 < ix.tokens.len { last += 2; }
        let source = ix.files[ix.tokens[token].file].source;
        if first < ix.tokens.len { ix.symbols[id].type_name = source[ix.tokens[first].start..ix.tokens[last].end]; }
    }
    return id;
}

fn generic_params(ix: Index&, name: i64, scope: i64, parent: i64) {
    if word_at(ix, name + 1) != "<" { return; }
    var p = name + 2;
    while p < ix.tokens.len && word_at(ix, p) != ">" {
        let prev = word_at(ix, p - 1);
        if ix.tokens[p].kind == TokenKind.Name && (prev == "<" || prev == ",") {
            declare(ix, p, scope, SymbolKind.Generic, parent, ix.tokens[p].start, ix.tokens[p].end);
        }
        p++;
    }
}

fn parameters(ix: Index&, open: i64, close: i64, scope: i64, parent: i64) {
    var p = open + 1;
    while p < close {
        if word_at(ix, p) == "var" { p++; }
        if p >= close || ix.tokens[p].kind != TokenKind.Name { break; }
        declare(ix, p, scope, SymbolKind.Parameter, parent, ix.tokens[p].start, ix.tokens[p].end);
        var angles = 0;
        p++;
        while p < close {
            let t = ix.tokens[p];
            if t.word == "," && angles == 0 { break; }
            if t.word == "<" { angles++; }
            if t.word == ">" && angles > 0 { angles--; }
            if t.pair > p { p = t.pair; }
            p++;
        }
        p++;
    }
}

fn statement_end(ix: Index&, token: i64, limit: i64) -> i64 {
    var i = token;
    while i < limit {
        if word_at(ix, i) == ";" || word_at(ix, i) == "{" { return i; }
        i++;
    }
    return limit;
}

// Declarations precede resolution, so calls can refer to later functions.
fn declarations(ix: Index&, file: i64) {
    let src = ix.files[file];
    for i in src.first..src.end {
        let t = ix.tokens[i];
        let word = t.word;
        if word == "namespace" && i + 1 < src.end { ix.files[file].ns = word_at(ix, i + 1); }
        if word == "fn" || word == "thread_fn" || word == "struct" || word == "enum" || word == "type" {
            let name = i + 1;
            if name >= src.end || ix.tokens[name].kind != TokenKind.Name { continue; }
            let end = statement_end(ix, name, src.end);
            let header_end = if end < src.end { ix.tokens[end].start } else { src.source.len };
            let kind = if word == "fn" || word == "thread_fn" { SymbolKind.Function } else { SymbolKind.Type };
            let id = declare(ix, name, t.scope, kind, -1, t.start, header_end);
            if kind == SymbolKind.Function {
                var open = name + 1;
                while open < end && word_at(ix, open) != "(" { open++; }
                if open >= end || ix.tokens[open].pair < 0 { continue; }
                let close = ix.tokens[open].pair;
                let body_scope = if end + 1 < src.end && word_at(ix, end) == "{" { ix.tokens[end + 1].scope } else { -1 };
                generic_params(ix, name, body_scope, id);
                parameters(ix, open, close, body_scope, id);
            } else if (word == "struct" || word == "enum") && end + 1 < src.end && word_at(ix, end) == "{" {
                let body_scope = ix.tokens[end + 1].scope;
                generic_params(ix, name, body_scope, id);
                let close = if ix.tokens[end].pair >= 0 { ix.tokens[end].pair } else { src.end };
                for p in end + 1..close {
                    if ix.tokens[p].scope != body_scope || ix.tokens[p].kind != TokenKind.Name { continue; }
                    if word_at(ix, p + 1) == ":" {
                        declare(ix, p, body_scope, SymbolKind.Field, id, ix.tokens[p].start, ix.tokens[p].end);
                    } else if word == "enum" && (word_at(ix, p - 1) == "{" || word_at(ix, p - 1) == ",") {
                        declare(ix, p, body_scope, SymbolKind.Variant, id, ix.tokens[p].start, ix.tokens[p].end);
                    }
                }
            }
            continue;
        }
        if word != "let" && word != "var" && word != "const" && word != "for" { continue; }
        if i + 1 >= src.end || ix.tokens[i + 1].declaration >= 0 { continue; }
        if word == "const" && word_at(ix, i + 2) != ":" && word_at(ix, i + 2) != "=" && word_at(ix, i + 2) != "," { continue; }
        var p = i + 1;
        while p < src.end && ix.tokens[p].kind == TokenKind.Name {
            var scope = t.scope;
            if word == "for" {
                let body = statement_end(ix, p, src.end);
                if body + 1 < src.end && word_at(ix, body) == "{" { scope = ix.tokens[body + 1].scope; }
            }
            let end = statement_end(ix, p, src.end);
            let header_end = if end < src.end { ix.tokens[end].start } else { ix.tokens[p].end };
            declare(ix, p, scope, SymbolKind.Variable, -1, t.start, header_end);
            if word_at(ix, p + 1) != "," { break; }
            p += 2;
        }
    }
}

fn token_at(ix: Index&, file: i64, offset: i64) -> i64 {
    let src = ix.files[file];
    for i in src.first..src.end {
        let t = ix.tokens[i];
        if t.start <= offset && offset < t.end { return i; }
    }
    return -1;
}

fn reachable(ix: Index&, from: i64, to: i64) -> bool {
    var seen: i64[>..] = [];
    seen.push(from);
    var at = 0;
    while at < seen.len {
        let file = seen[at];
        at++;
        if file == to { return true; }
        for edge in ix.imports {
            if edge.from != file { continue; }
            var found = false;
            for prior in seen { if prior == edge.to { found = true; break; } }
            if !found { seen.push(edge.to); }
        }
    }
    return false;
}

fn lookup(ix: Index&, token: i64, name: u8[:]) -> i64 {
    let use = ix.tokens[token];
    var local_name: const u8[:] = name;
    var qualifier: const u8[:] = name[..0];
    let separator = find(name, "::");
    if separator >= 0 { qualifier = name[..separator]; local_name = name[separator + 2..]; }
    else if token >= ix.files[use.file].first + 2 && word_at(ix, token - 1) == "::" {
        qualifier = word_at(ix, token - 2);
    }
    var scope = use.scope;
    while scope >= 0 {
        var found = -1;
        for s, id in ix.symbols {
            if s.scope != scope || ix.tokens[s.token].word != local_name { continue; }
            if qualifier.len > 0 && s.ns != qualifier { continue; }
            if s.kind == SymbolKind.Variable && ix.tokens[s.token].start > use.start { continue; }
            if found >= 0 && s.kind != SymbolKind.Variable { return -1; }
            found = id;
        }
        if found >= 0 { return found; }
        scope = ix.scopes[scope].parent;
    }
    var found = -1;
    for s, id in ix.symbols {
        let decl = ix.tokens[s.token];
        if decl.word != local_name || s.scope != ix.files[decl.file].scope { continue; }
        if qualifier.len > 0 && s.ns != qualifier { continue; }
        if qualifier.len == 0 && s.ns.len > 0 && s.ns != ix.files[use.file].ns { continue; }
        if !reachable(ix, use.file, decl.file) { continue; }
        if found >= 0 { return -1; }
        found = id;
    }
    return found;
}

fn resolve(ix: Index&, token: i64) -> i64 {
    let t = ix.tokens[token];
    if t.declaration >= 0 { return t.declaration; }
    if t.kind != TokenKind.Name { return -1; }
    for s, id in ix.symbols {
        if s.kind != SymbolKind.Generic || ix.tokens[s.token].word != t.word || s.parent < 0 { continue; }
        let owner = ix.symbols[s.parent];
        if ix.tokens[owner.token].file == t.file && t.start >= owner.header_start && t.end <= owner.header_end { return id; }
    }
    if token >= ix.files[t.file].first + 2 && word_at(ix, token - 1) == "." {
        let object = lookup(ix, token - 2, word_at(ix, token - 2));
        if object < 0 { return -1; }
        let s = ix.symbols[object];
        let owner = if s.kind == SymbolKind.Type { object } else { lookup(ix, token, s.type_name) };
        if owner < 0 { return -1; }
        for field, id in ix.symbols {
            if field.parent == owner && ix.tokens[field.token].word == t.word { return id; }
        }
        return -1;
    }
    return lookup(ix, token, t.word);
}
