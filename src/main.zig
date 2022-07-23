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

    std.log.info("Serving on http://{s}:{}", .{ "127.0.0.1", DEFAULT_PORT });
    try http.listenAndServe(
        gpa.allocator(),
        try std.net.Address.parseIp("127.0.0.1", DEFAULT_PORT),
        &ctx,
        index,
    );
}

fn index(ctx: *Context, res: *http.Response, req: http.Request) !void {
    const path = req.path();
    if (std.mem.startsWith(u8, path, "/files/")) {
        return try http.FileServer.serve({}, res, req);
    } else if (req.method() == .post and std.mem.eql(u8, path, "/note")) {
        return postNote(ctx, res, req);
    }

    try res.headers.put("Content-Type", "text/html");

    var out = res.writer();
    try out.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <form action="/note" method="POST">
        \\    <input type="text" name="text" />
        \\    <button>Add note</button>
        \\  </form>
        \\
    );

    var stmt = (try ctx.db.prepare_v2("SELECT id, text FROM note", null)) orelse return error.NoStatement;
    defer stmt.finalize() catch {};
    while ((try stmt.step()) != .Done) {
        const id = stmt.columnInt64(0);
        const text = stmt.columnText(1);
        // TODO: Escape note text
        try out.print(
            \\<div>
            \\  <input type="hidden" name="id" value="{}">
            \\  {s}
            \\</div>
        , .{ id, text });
    }

    try out.writeAll(
        \\</body>
        \\</html>
        \\
    );
}

fn postNote(ctx: *Context, res: *http.Response, req: http.Request) !void {
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

/// https://david.rothlis.net/declarative-schema-migration-for-sqlite/
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
        if (current_tables.contains(pristine_table_entry.key_ptr.*)) {
            std.debug.print("not adding table: {}\n", .{std.zig.fmtEscapes(pristine_table_entry.key_ptr.*)});
            // The table already exists, no need to create it
            continue;
        }
        std.debug.print("adding table: {}\n", .{std.zig.fmtEscapes(pristine_table_entry.key_ptr.*)});
        // Create table in current database that is in pristine database
        try db.exec(pristine_table_entry.value_ptr.*, null, null, null);
    }

    // set(db) - set(pristine)  = removed_tables
    var current_table_iter = current_tables.iterator();
    while (current_table_iter.next()) |current_table_entry| {
        if (pristine_tables.contains(current_table_entry.key_ptr.*)) {
            // The table exists in the pristine, no need to drop it
            std.debug.print("not dropping table: {}\n", .{std.zig.fmtEscapes(current_table_entry.key_ptr.*)});
            continue;
        }
        std.debug.print("dropping table: {}\n", .{std.zig.fmtEscapes(current_table_entry.key_ptr.*)});
        // Drop table in current database that is not in pristine database
        const drop_sql = try std.fmt.allocPrintZ(arena.allocator(), "DROP TABLE '{}'", .{std.zig.fmtEscapes(current_table_entry.key_ptr.*)});
        try db.exec(drop_sql, null, null, null);
    }

    try txn.commit();
}

fn dbTables(allocator: std.mem.Allocator, db: *sqlite3.SQLite3) !std.StringHashMap([:0]const u8) {
    var stmt = (try db.prepare_v2(
        \\ SELECT name, sql FROM sqlite_schema
        \\ WHERE type = "table" AND name != "sqlite_sequence"
    , null)).?;
    defer stmt.finalize() catch unreachable;

    var hashmap = std.StringHashMap([:0]const u8).init(allocator);
    errdefer hashmap.deinit();
    while ((try stmt.step()) != .Done) {
        const name = try allocator.dupeZ(u8, stmt.columnText(0));
        const sql = try allocator.dupeZ(u8, stmt.columnText(1));
        try hashmap.putNoClobber(name, sql);
    }

    return hashmap;
}

fn executeScript(db: *sqlite3.SQLite3, sql: []const u8) !void {
    var next_sql = sql;
    var tail_sql = sql;
    while (try db.prepare_v2(next_sql, &tail_sql)) |stmt| : (next_sql = tail_sql) {
        defer stmt.finalize() catch |e| std.debug.panic("could not finalize: {}", .{e});
        std.debug.print(
            \\```sql
            \\{s}
            \\```
            \\
        , .{next_sql[0..@ptrToInt(tail_sql.ptr) -| @ptrToInt(next_sql.ptr)]});
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
