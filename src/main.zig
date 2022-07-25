const std = @import("std");
const http = @import("apple_pie");
pub const io_mode = .evented;
const sqlite3 = @import("sqlite3");

const APP_NAME = "my-notes-app";
const DEFAULT_PORT = 40077;

const Context = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3.SQLite3,
    data_dir: std.fs.Dir,
    notes_dir: std.fs.IterableDir,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const data_dir_path = try std.fs.getAppDataDir(gpa.allocator(), APP_NAME);
    defer gpa.allocator().free(data_dir_path);

    std.log.info("data dir = \"{}\"", .{std.zig.fmtEscapes(data_dir_path)});

    var data_dir = try std.fs.cwd().makeOpenPath(data_dir_path, .{});
    defer data_dir.close();

    const db_path_z = try std.fs.path.joinZ(gpa.allocator(), &.{ data_dir_path, "notes.db" });
    defer gpa.allocator().free(db_path_z);

    std.log.info("opening database = \"{}\"", .{std.zig.fmtEscapes(db_path_z)});
    try sqlite3.config(.{ .log = .{ .logFn = sqliteLogCallback, .userdata = null } });
    var db = try sqlite3.SQLite3.open(db_path_z);
    defer db.close() catch @panic("Couldn't close sqlite database");
    try setupSchema(gpa.allocator(), db);

    var notes_dir = try data_dir.makeOpenPathIterable("notes", .{});
    defer notes_dir.close();

    const notes_dir_path = try notes_dir.dir.realpathAlloc(gpa.allocator(), "./");
    defer gpa.allocator().free(notes_dir_path);

    try http.FileServer.init(gpa.allocator(), .{ .dir_path = notes_dir_path, .base_path = "files" });
    defer http.FileServer.deinit();

    var ctx = Context{
        .allocator = gpa.allocator(),
        .db = db,
        .data_dir = data_dir,
        .notes_dir = notes_dir,
    };

    const builder = http.router.Builder(*Context);

    std.log.info("Serving on http://{s}:{}", .{ "127.0.0.1", DEFAULT_PORT });
    try http.listenAndServe(
        gpa.allocator(),
        try std.net.Address.parseIp("127.0.0.1", DEFAULT_PORT),
        &ctx,
        comptime http.router.Router(*Context, &.{
            builder.get("/", null, index),
            builder.post("/note", null, postNote),
            builder.put("/folder/:folder/note", i64, putNoteInFolder),
            builder.post("/folder", null, postFolder),
            builder.get("/folder/:folder", i64, getFolder),
            builder.post("/files/*", null, serveFs),
            builder.get("/static/:filename", struct { filename: []const u8 }, staticFiles(.{
                .@"style.css" = .{ .css = @embedFile("style.css") },
                .@"tachyons.min.css" = .{ .css = @embedFile("tachyons.min.css") },
                .@"htmx.min.js" = .{ .js = @embedFile("htmx.min.js") },
                .@"_hyperscript.min.js" = .{ .js = @embedFile("_hyperscript.min.js") },
            })),
        }),
    );
}

fn index(ctx: *Context, res: *http.Response, req: http.Request, _: ?*const anyopaque) !void {
    _ = req;
    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <meta charset="utf-8">
        \\  <title>My Notes App</title>
        \\
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <script src="/static/htmx.min.js"></script>
        \\  <script src="/static/_hyperscript.min.js"></script>
        \\  <link rel="stylesheet" type="text/css" href="/static/tachyons.min.css">
        \\  <link rel="stylesheet" type="text/css" href="/static/style.css">
        \\  <body>
        \\    <div>
        \\    <h2>Folders</h2>
        \\    <form action="/folder" method="POST">
        \\      <input type="text" name="name" />
        \\      <button>New Folder</button>
        \\    </form>
        \\    <ul hx-include=".selected-note" id="folders" _="
        \\        on dragover or dragenter halt the event
        \\          then set the target's style.background to 'lightgray'
        \\        on dragleave or drop set the target's style.background to ''
        \\        on drop get event.dataTransfer.getData('my-notes-app/note-id')
        \\          then put it into the next <output/>
        \\    ">
    );
    {
        var stmt = (try ctx.db.prepare_v2("SELECT id, name FROM folder", null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        while ((try stmt.step()) != .Done) {
            const id = stmt.columnInt64(0);
            const name = stmt.columnText(1);
            // TODO: Escape note text
            try out.print(
                \\<li hx-put="/folder/{}/note" hx-trigger="drop" hx-swap="none" class="f3">
                \\  <input type="hidden" name="folder_id" value="{}">
                \\  <a class="no-underline" href="/folder/{}">{s}</a>
                \\
            , .{ id, id, id, name });
        }
    }
    try out.writeAll(
        \\    </ul>
        \\    Dropped data: <output></output>
        \\    </div>
        \\    <div>
        \\    <h2>Notes</h2>
        \\    <form action="/note" method="POST">
        \\      <input type="text" name="text" />
        \\      <button>Add note</button>
        \\    </form>
        \\    <div id="notes" class="pa1 flex flex-wrap justify-start" _="
        \\        on dragstart
        \\          add .selected-note to target
        \\          call event.dataTransfer.setData('text/html', target.innerHTML)
        \\          call event.dataTransfer.setData('text/plain', target.innerText)
        \\          set id to <input[name='id']/> in event.target call event.dataTransfer.setData('my-notes-app/note-id', id.value)
        \\    ">
        \\
    );
    {
        var stmt = (try ctx.db.prepare_v2("SELECT id, text FROM note WHERE folder_id = 0", null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        while ((try stmt.step()) != .Done) {
            const id = stmt.columnInt64(0);
            const text = stmt.columnText(1);
            // TODO: Escape note text
            try out.print(
                \\<div class="w5 pa3 ma2 shadow-3" draggable="true">
                \\  <input type="hidden" name="note-id" value="{}">
                \\  {s}
                \\</div>
            , .{ id, text });
        }
    }
    try out.writeAll(
        \\    </div>
        \\    </div>
        \\  </body>
        \\</html>
        \\
    );
}

fn getFolder(ctx: *Context, res: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    _ = req;
    const folder_id = @ptrCast(?*const i64, @alignCast(@alignOf(?*const i64), captures)) orelse return error.hell;
    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <meta charset="utf-8">
        \\  <title>My Notes App</title>
        \\
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <script src="/static/htmx.min.js"></script>
        \\  <script src="/static/_hyperscript.min.js"></script>
        \\  <link rel="stylesheet" type="text/css" href="/static/tachyons.min.css">
        \\  <link rel="stylesheet" type="text/css" href="/static/style.css">
        \\  <body>
        \\    <div>
        \\    <h2>Folders</h2>
        \\    <form action="/folder" method="POST">
        \\      <input type="text" name="name" />
        \\      <button>New Folder</button>
        \\    </form>
        \\    <ul hx-include=".selected-note" id="folders" _="
        \\        on dragover or dragenter halt the event
        \\          then set the target's style.background to 'lightgray'
        \\        on dragleave or drop set the target's style.background to ''
        \\        on drop get event.dataTransfer.getData('my-notes-app/note-id')
        \\          then put it into the next <output/>
        \\    ">
    );
    {
        var stmt = (try ctx.db.prepare_v2("SELECT id, name FROM folder", null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        while ((try stmt.step()) != .Done) {
            const id = stmt.columnInt64(0);
            const name = stmt.columnText(1);
            // TODO: Escape note text
            try out.print(
                \\<li hx-put="/folder/{}/note" hx-trigger="drop" hx-swap="none" class="f3">
                \\  <input type="hidden" name="folder_id" value="{}">
                \\  <a class="no-underline" href="/folder/{}">{s}</a>
                \\
            , .{ id, id, id, name });
        }
    }
    try out.writeAll(
        \\    </ul>
        \\    Dropped data: <output></output>
        \\    </div>
        \\    <div>
        \\    <h2>Notes</h2>
        \\    <form action="/note" method="POST">
        \\      <input type="text" name="text" />
        \\      <button>Add note</button>
        \\    </form>
        \\    <div id="notes" class="pa1 flex flex-wrap justify-start" _="
        \\        on dragstart
        \\          add .selected-note to target
        \\          call event.dataTransfer.setData('text/html', target.innerHTML)
        \\          call event.dataTransfer.setData('text/plain', target.innerText)
        \\          set id to <input[name='id']/> in event.target call event.dataTransfer.setData('my-notes-app/note-id', id.value)
        \\    ">
        \\
    );
    {
        var stmt = (try ctx.db.prepare_v2("SELECT id, text FROM note WHERE folder_id = ?", null)) orelse return error.NoStatement;
        defer stmt.finalize() catch {};
        try stmt.bindInt64(1, folder_id.*);
        while ((try stmt.step()) != .Done) {
            const id = stmt.columnInt64(0);
            const text = stmt.columnText(1);
            // TODO: Escape note text
            try out.print(
                \\<div class="w5 pa3 ma2 shadow-3" draggable="true">
                \\  <input type="hidden" name="note-id" value="{}">
                \\  {s}
                \\</div>
            , .{ id, text });
        }
    }
    try out.writeAll(
        \\    </div>
        \\    </div>
        \\  </body>
        \\</html>
        \\
    );
}

fn postNote(ctx: *Context, res: *http.Response, req: http.Request, _: ?*const anyopaque) !void {
    const text = (try req.formValue(ctx.allocator, "text")) orelse {
        return error.InvalidInput;
    };
    defer ctx.allocator.free(text);

    var stmt = (try ctx.db.prepare_v2("INSERT INTO note(text) VALUES (?)", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    try stmt.bindText(1, text, .transient);
    if ((try stmt.step()) != .Done) {
        return error.UnexpectedReturnCode;
    }

    res.status_code = .see_other;
    try res.headers.put("Location", "/");
    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\Note posted
        \\</body>
        \\</html>
        \\
    );
}

fn postFolder(ctx: *Context, res: *http.Response, req: http.Request, _: ?*const anyopaque) !void {
    const name = (try req.formValue(ctx.allocator, "name")) orelse {
        return error.InvalidInput;
    };
    defer ctx.allocator.free(name);

    var stmt = (try ctx.db.prepare_v2("INSERT INTO folder(name) VALUES (?)", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    try stmt.bindText(1, name, .transient);
    if ((try stmt.step()) != .Done) {
        return error.UnexpectedReturnCode;
    }

    res.status_code = .see_other;
    try res.headers.put("Location", "/");
    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\Folder posted
        \\</body>
        \\</html>
        \\
    );
}

fn putNoteInFolder(ctx: *Context, res: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    const folder_id = (@ptrCast(?*const i64, @alignCast(@alignOf(?*const i64), captures)) orelse return error.hell).*;
    const note_id_str = (try req.formValue(ctx.allocator, "note-id")) orelse {
        std.debug.print("form value = {}\n", .{std.zig.fmtEscapes(req.body())});
        return error.InvalidInput;
    };
    defer ctx.allocator.free(note_id_str);

    const note_id = try std.fmt.parseInt(i64, note_id_str, 10);

    var txn = try Transaction.begin(@src(), ctx.db);
    defer txn.deinit();

    var stmt = (try ctx.db.prepare_v2("UPDATE note SET folder_id = ? WHERE id = ?", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    try stmt.bindInt64(1, folder_id);
    try stmt.bindInt64(2, note_id);
    while ((try stmt.step()) != .Done) {}

    res.status_code = .see_other;
    try res.headers.put("Location", "/");
    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\Note moved to folder
        \\</body>
        \\</html>
        \\
    );

    try txn.commit();
}

/// - https://david.rothlis.net/declarative-schema-migration-for-sqlite/
/// - https://sqlite.org/pragma.html#pragma_table_info
/// - https://www.sqlite.org/lang_altertable.html
///   - alter table cannot move a table to a different attached database
///
/// TODO: Check columns of tables
fn setupSchema(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !void {
    var txn = try Transaction.begin(@src(), db);
    defer txn.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pristine = try sqlite3.SQLite3.open(":memory:");
    defer pristine.close() catch @panic("Couldn't close db connection");
    try executeScript(pristine, @embedFile("./schema.sql"));

    var pristine_tables = try dbTables(arena.allocator(), pristine);
    var current_tables = try dbTables(arena.allocator(), db);

    // set(pristine) - set(db) = new_tables
    var pristine_table_iter = pristine_tables.iterator();
    while (pristine_table_iter.next()) |pristine_table_entry| {
        if (current_tables.get(pristine_table_entry.key_ptr.*)) |current_table_info| {
            // The table already exists
            if (current_table_info.eql(pristine_table_entry.value_ptr.*)) {
                // The tables are identical, nothing needs to change
                continue;
            }
            // The tables are not identical, we need to rebuild it
            try dbRebuildTable(allocator, db, pristine, pristine_table_entry.value_ptr.*);
            continue;
        }
        // Create table in current database that is in pristine database
        try db.exec(pristine_table_entry.value_ptr.sql, null, null, null);
    }

    // set(db) - set(pristine)  = removed_tables
    var current_table_iter = current_tables.iterator();
    while (current_table_iter.next()) |current_table_entry| {
        if (pristine_tables.contains(current_table_entry.key_ptr.*)) {
            // The table exists in the pristine, no need to drop it
            continue;
        }
        // Drop table in current database that is not in pristine database
        const drop_sql = try std.fmt.allocPrintZ(arena.allocator(), "DROP TABLE '{}'", .{std.zig.fmtEscapes(current_table_entry.key_ptr.*)});
        try db.exec(drop_sql, null, null, null);
    }

    try db.exec("INSERT OR IGNORE INTO folder (id, name) VALUES (0, 'Inbox')", null, null, null);

    try txn.commit();
}

const TableInfo = struct {
    schema: [:0]const u8,
    name: [:0]const u8,
    table_type: Type,
    ncol: u32,
    without_rowid: bool,
    strict: bool,
    sql: [:0]const u8,

    const Type = enum {
        table,
        view,
        shadow,
        virtual,
    };

    pub fn eql(a: @This(), b: @This()) bool {
        return std.mem.eql(u8, a.schema, b.schema) and
            std.mem.eql(u8, a.name, b.name) and
            a.table_type == b.table_type and
            a.ncol == b.ncol and
            a.without_rowid == b.without_rowid and
            a.strict == b.strict and
            std.mem.eql(u8, a.sql, b.sql);
    }
};

/// - sqlite 3.37 introduced `PRAGMA table_list`: https://sqlite.org/pragma.html#pragma_table_list
fn dbTables(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !std.StringHashMap(TableInfo) {
    var stmt = (try db.prepare_v2(
        \\ SELECT tl.schema, tl.name, tl.type, tl.ncol, tl.wr, tl.strict, schema.sql
        \\ FROM pragma_table_list AS tl
        \\ JOIN sqlite_schema AS schema ON schema.name = tl.name
    , null)).?;
    defer stmt.finalize() catch unreachable;

    var hashmap = std.StringHashMap(TableInfo).init(allocator);
    errdefer hashmap.deinit();
    while ((try stmt.step()) != .Done) {
        const schema = try allocator.dupeZ(u8, stmt.columnText(0));
        const name = try allocator.dupeZ(u8, stmt.columnText(1));
        const table_type = std.meta.stringToEnum(TableInfo.Type, stmt.columnText(2)).?;
        const ncol = @intCast(u32, stmt.columnInt(3));
        const without_rowid = stmt.columnInt(4) != 0;
        const strict = stmt.columnInt(5) != 0;
        const sql = try allocator.dupeZ(u8, stmt.columnText(6));

        const fullname = try std.fmt.allocPrint(allocator, "\"{}\".\"{}\"", .{ std.zig.fmtEscapes(schema), std.zig.fmtEscapes(name) });
        try hashmap.putNoClobber(fullname, .{
            .schema = schema,
            .name = name,
            .table_type = table_type,
            .ncol = ncol,
            .without_rowid = without_rowid,
            .strict = strict,
            .sql = sql,
        });
    }

    return hashmap;
}

/// - sqlite 3.37 introduced `PRAGMA table_list`: https://sqlite.org/pragma.html#pragma_table_list
fn dbRebuildTable(allocator: std.mem.Allocator, db: *sqlite3.SQLite3, pristine: *sqlite3.SQLite3, new_table_info: TableInfo) !void {
    var common_cols_list = std.StringArrayHashMap(bool).init(allocator);
    defer {
        for (common_cols_list.keys()) |str| {
            allocator.free(str);
        }
        common_cols_list.deinit();
    }

    {
        var stmt = (try db.prepare_v2(
            \\ SELECT name FROM pragma_table_info(?)
        , null)).?;
        defer stmt.finalize() catch unreachable;
        try stmt.bindText(1, new_table_info.name, .transient);
        while ((try stmt.step()) != .Done) {
            try common_cols_list.putNoClobber(try allocator.dupeZ(u8, stmt.columnText(0)), false);
        }
    }

    {
        var stmt = (try pristine.prepare_v2(
            \\ SELECT name FROM pragma_table_info(?)
        , null)).?;
        defer stmt.finalize() catch unreachable;
        try stmt.bindText(1, new_table_info.name, .transient);
        while ((try stmt.step()) != .Done) {
            if (common_cols_list.getPtr(stmt.columnText(0))) |in_both| {
                in_both.* = true;
            }
        }
    }

    var common_cols = std.ArrayList(u8).init(allocator);
    defer common_cols.deinit();
    {
        var common_col_iter = common_cols_list.iterator();
        while (common_col_iter.next()) |entry| {
            const in_both = entry.value_ptr.*;
            if (in_both) {
                const need_comma = common_cols.items.len > 0;
                if (need_comma) {
                    try common_cols.appendSlice(", ");
                }
                try common_cols.appendSlice(entry.key_ptr.*);
            }
        }
    }

    if (new_table_info.table_type != .table) {
        std.log.warn("Skipping table {s}. Tables of type {} not supported. Only regular tables supported ATM.", .{ new_table_info.name, new_table_info.table_type });
        return;
    }
    try db.exec("PRAGMA foreign_keys=OFF;", null, null, null);
    defer db.exec("PRAGMA foreign_keys=ON;", null, null, null) catch {};

    var txn = try Transaction.begin(@src(), db);
    defer txn.deinit();
    const table_migration_name = try std.fmt.allocPrint(allocator,
        \\"{}_migration_new"
    , .{std.zig.fmtEscapes(new_table_info.name)});
    defer allocator.free(table_migration_name);

    const create_sql = try std.mem.replaceOwned(u8, allocator, new_table_info.sql, new_table_info.name, table_migration_name);
    defer allocator.free(create_sql);
    const create_sql_z = try std.fmt.allocPrintZ(allocator, "{s}", .{create_sql});
    defer allocator.free(create_sql_z);
    try db.exec(create_sql_z, null, null, null);

    const insert_sql = try std.fmt.allocPrintZ(allocator,
        \\INSERT INTO "{}".{s} ({s}) SELECT {s} FROM "{}"
    , .{ std.zig.fmtEscapes(new_table_info.schema), table_migration_name, common_cols.items, common_cols.items, std.zig.fmtEscapes(new_table_info.name) });
    defer allocator.free(insert_sql);
    try db.exec(insert_sql, null, null, null);

    const drop_sql = try std.fmt.allocPrintZ(allocator,
        \\DROP TABLE "{}"
    , .{std.zig.fmtEscapes(new_table_info.name)});
    defer allocator.free(drop_sql);
    try db.exec(drop_sql, null, null, null);

    const alter_sql = try std.fmt.allocPrintZ(allocator,
        \\ALTER TABLE {s} RENAME TO "{}"
    , .{ table_migration_name, std.zig.fmtEscapes(new_table_info.name) });
    defer allocator.free(alter_sql);
    try db.exec(alter_sql, null, null, null);

    try db.exec("PRAGMA foreign_keys_check;", null, null, null);

    try txn.commit();
}

fn executeScript(db: *sqlite3.SQLite3, sql: []const u8) !void {
    var next_sql = sql;
    var tail_sql = sql;
    while (try db.prepare_v2(next_sql, &tail_sql)) |stmt| : (next_sql = tail_sql) {
        defer stmt.finalize() catch |e| std.debug.panic("could not finalize: {}", .{e});
        while ((try stmt.step()) != .Done) {}
    }
}

const Transaction = struct {
    db: *sqlite3.SQLite3,
    commit_sql: ?[:0]const u8,
    rollback_sql: ?[:0]const u8,

    pub fn begin(comptime src: std.builtin.SourceLocation, db: *sqlite3.SQLite3) !@This() {
        const SAVEPOINT = comptime std.fmt.comptimePrint("{s}:{}", .{ src.file, src.line });
        try db.exec(comptime std.fmt.comptimePrint("SAVEPOINT \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}), null, null, null);
        return @This(){
            .db = db,
            .commit_sql = comptime std.fmt.comptimePrint("RELEASE \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}),
            .rollback_sql = comptime std.fmt.comptimePrint("ROLLBACK TO \"{}\"", .{std.zig.fmtEscapes(SAVEPOINT)}),
        };
    }

    pub fn deinit(this: *@This()) void {
        if (this.rollback_sql) |rollback| {
            this.db.exec(rollback, null, null, null) catch {};
            this.commit_sql = null;
            this.rollback_sql = null;
        }
        this.db = undefined;
    }

    pub fn commit(this: *@This()) !void {
        if (this.commit_sql) |rollback| {
            try this.db.exec(rollback, null, null, null);
            this.commit_sql = null;
            this.rollback_sql = null;
        }
    }
};

pub const Blob = union(enum) {
    html: []const u8,
    css: []const u8,
    js: []const u8,

    pub fn contentType(this: @This()) []const u8 {
        return switch (this) {
            .html => "text/html",
            .css => "text/css",
            .js => "text/javascript",
        };
    }

    pub fn data(this: @This()) []const u8 {
        return switch (this) {
            .html => |d| d,
            .css => |d| d,
            .js => |d| d,
        };
    }
};

/// Expects an struct where the field names are files, and the values are Blobs
fn staticFiles(comptime static_files: anytype) fn (*Context, *http.Response, http.Request, ?*const anyopaque) http.Response.Error!void {
    const Handler = struct {
        fn handle(_: *Context, res: *http.Response, req: http.Request, captures: ?*const anyopaque) http.Response.Error!void {
            _ = req;

            if (captures == null) return res.notFound();

            const req_filename = @ptrCast(*const struct { filename: []const u8 }, @alignCast(@alignOf(Blob), captures.?)).filename;
            inline for (std.meta.fields(@TypeOf(static_files))) |field| {
                if (std.mem.eql(u8, req_filename, field.name)) {
                    const static_file: Blob = @field(static_files, field.name);
                    try res.headers.put("Content-Type", static_file.contentType());
                    try res.writer().writeAll(static_file.data());
                    return;
                }
            }

            return res.notFound();
        }
    };
    return Handler.handle;
}

/// Serves a file
fn serveFs(ctx: *Context, resp: *http.Response, req: http.Request, captures: ?*const anyopaque) !void {
    std.debug.assert(captures == null);
    _ = ctx;
    try http.FileServer.serve({}, resp, req);
}

fn srcLineStr(comptime src: std.builtin.SourceLocation) *const [srcLineStrLen(src):0]u8 {
    return std.fmt.comptimePrint("{s}:{}", .{ src.file, src.line });
}

fn srcLineStrLen(comptime src: std.builtin.SourceLocation) usize {
    return src.file.len + std.math.log10(src.line) + 2;
}

fn sqliteLogCallback(userdata: *anyopaque, errcode: c_int, msg: ?[*:0]const u8) callconv(.C) void {
    _ = userdata;
    std.log.scoped(.sqlite3).err("{s}: {s}", .{ sqlite3.errstr(errcode), msg });
}
