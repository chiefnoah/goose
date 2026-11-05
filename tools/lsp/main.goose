import .protocol;
import .workspace;
import .index;
import .features;

const CAPABILITIES = "{\"capabilities\":{\"positionEncoding\":\"utf-16\",\"textDocumentSync\":{\"openClose\":true,\"change\":2},\"definitionProvider\":true,\"referencesProvider\":true,\"hoverProvider\":true,\"inlayHintProvider\":true},\"serverInfo\":{\"name\":\"goose-in-goose\",\"version\":\"0.1.0\"}}";
enum ServerState { New, Ready, Shutdown }

fn query(ws: Workspace&, method: u8[:], params: json::Node?, out: u8[>..]&) {
    let td = json::member(params, "textDocument");
    let uri = text(json::member(td, "uri"));
    var files: Source[>..] = [];
    var tokens: Token[>..] = [];
    var scopes: Scope[>..] = [];
    var symbols: Symbol[>..] = [];
    var imports: Import[>..] = [];
    var storage: u8[>..] = [];
    var ix = Index { files: files, tokens: tokens, scopes: scopes, symbols: symbols, imports: imports, storage: storage };
    var file = -1;
    for d in ws.documents {
        if !d.active { continue; }
        if d.uri == uri { file = files.len; }
        let path = uri_path(d.uri);
        let saved = save_text(ix, normal_path(path));
        files.push(Source { uri: d.uri, source: d.source, path: saved, base: directory(saved) });
    }
    if file < 0 { out.append(if method == "textDocument/hover" { "null" } else { "[]" }); return; }
    var i = 0;
    while i < files.len {
        lex(ix, i);
        declarations(ix, i);
        load_imports(ix, ws, i);
        i++;
    }
    if method == "textDocument/inlayHint" { inlay_hints(out, ix, file, params); return; }
    let pos = json::member(params, "position");
    let offset = offset_at(files[file].source, integer(json::member(pos, "line")), integer(json::member(pos, "character")));
    let token = token_at(ix, file, offset);
    if token < 0 { out.append(if method == "textDocument/hover" { "null" } else { "[]" }); return; }
    if method == "textDocument/definition" {
        for edge in imports {
            if edge.from != file || token < edge.first || token > edge.last { continue; }
            out.append("[{\"uri\":");
            json::format_string(out, files[edge.to].uri);
            out.append(",\"range\":");
            write_range(out, files[edge.to].source, 0, 0);
            out.append("}]");
            return;
        }
    }
    if method == "textDocument/hover" { hover(out, ix, token); return; }
    if method == "textDocument/references" { references(out, ix, token, params); return; }
    out.push('[');
    let id = resolve(ix, token);
    if id >= 0 { location(out, ix, symbols[id].token); }
    out.push(']');
}

fn handle(ws: Workspace&, root: json::Node?, state: ServerState&) {
    let id = json::member(root, "id");
    let method = text(json::member(root, "method"));
    let params = json::member(root, "params");
    let protocol = text(json::member(root, "jsonrpc"));
    if protocol != "2.0" || method.len == 0 {
        error_reply(id, INVALID_REQUEST, "The message is not a JSON-RPC request.");
        return;
    }
    if method == "exit" { exit(if state == ServerState.Shutdown { 0 } else { 1 }); }
    if method == "initialize" {
        if !id { return; }
        if state != ServerState.New { error_reply(id, INVALID_REQUEST, "The server is already initialized."); return; }
        state = ServerState.Ready;
        reply(id, CAPABILITIES);
        return;
    }
    if state == ServerState.New {
        if id { error_reply(id, NOT_INITIALIZED, "Initialize the server first."); }
        return;
    }
    if state == ServerState.Shutdown {
        if id { error_reply(id, INVALID_REQUEST, "The server is shut down."); }
        return;
    }
    if method == "shutdown" {
        if !id { return; }
        state = ServerState.Shutdown;
        reply(id, "null");
        return;
    }
    if method == "textDocument/didOpen" {
        let td = json::member(params, "textDocument");
        let uri = text(json::member(td, "uri"));
        let value, ok = json::as_string(json::member(td, "text"));
        if uri.len > 0 && ok { open_document(ws, uri, value, integer(json::member(td, "version"))); }
        return;
    }
    if method == "textDocument/didChange" { change_document(ws, params); return; }
    if method == "textDocument/didClose" {
        close_document(ws, text(json::member(json::member(params, "textDocument"), "uri")));
        return;
    }
    if !id { return; }
    if method == "textDocument/definition" || method == "textDocument/references" || method == "textDocument/hover" || method == "textDocument/inlayHint" {
        let td = json::member(params, "textDocument");
        let uri = text(json::member(td, "uri"));
        let pos = json::member(params, "position");
        if uri.len == 0 {
            error_reply(id, INVALID_PARAMS, "The request needs a document URI.");
            return;
        }
        if method != "textDocument/inlayHint" {
            let doc = document(ws, uri);
            let line = integer(json::member(pos, "line"));
            let character = integer(json::member(pos, "character"));
            if line < 0 || character < 0 || (doc >= 0 && offset_at(ws.documents[doc].source, line, character) < 0) {
                error_reply(id, INVALID_PARAMS, "The position is outside the document.");
                return;
            }
        } else {
            let range = json::member(params, "range");
            let first = json::member(range, "start");
            let last = json::member(range, "end");
            let start_line = integer(json::member(first, "line"));
            let start_char = integer(json::member(first, "character"));
            let end_line = integer(json::member(last, "line"));
            let end_char = integer(json::member(last, "character"));
            if start_line < 0 || start_char < 0 || end_line < start_line || end_char < 0 || (start_line == end_line && end_char < start_char) {
                error_reply(id, INVALID_PARAMS, "The hint range is invalid.");
                return;
            }
        }
        var result: u8[>..] = [];
        query(ws, method, params, result);
        reply(id, result);
        return;
    }
    error_reply(id, METHOD_NOT_FOUND, "The server does not support this method.");
}

fn main() {
    var stdlib: u8[>..] = [];
    env("GOOSE_STDLIB", stdlib);
    let arguments = args();
    var at = 1;
    while at < arguments.len {
        if arguments[at] == "--stdio" { at++; continue; }
        if arguments[at] == "--stdlib" && at + 1 < arguments.len {
            stdlib.clear();
            stdlib.append(arguments[at + 1]);
            at += 2;
            continue;
        }
        write_stderr("Usage: goose-lsp [--stdio] [--stdlib DIRECTORY]\n");
        exit(1);
    }
    if stdlib.len == 0 {
        let resources = resource_dir();
        let beside_build = str(resources, "../stdlib");
        let beside_source = str(resources, "../../stdlib");
        if is_dir(beside_build) { stdlib.append(beside_build); }
        else if is_dir(beside_source) { stdlib.append(beside_source); }
    }
    var bytes = slice_pool<u8> { .. };
    var documents: Document[>..] = [];
    var ws = Workspace { bytes: bytes, documents: documents, stdlib: stdlib };
    var state = ServerState.New;
    loop {
        var body: u8[>..] = [];
        if !read_frame(body) { break; }
        var nodes: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, error = json::parse(body, nodes, decoded);
        if !root { error_reply(null, PARSE_ERROR, error); continue; }
        handle(ws, root, state);
    }
    exit(if state == ServerState.Shutdown { 0 } else { 1 });
}
