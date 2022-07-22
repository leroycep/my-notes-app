const std = @import("std");
const http = @import("apple_pie");
pub const io_mode = .evented;

const APP_NAME = "my-notes-app";
const DEFAULT_PORT = 40077;

const Context = struct {
    data_dir: std.fs.Dir,
    notes_dir: std.fs.IterableDir,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var data_dir = open_data_dir: {
        const app_data_dir = try std.fs.getAppDataDir(gpa.allocator(), APP_NAME);
        errdefer gpa.allocator().free(app_data_dir);

        std.log.info("data dir = \"{}\"", .{std.zig.fmtEscapes(app_data_dir)});

        break :open_data_dir try std.fs.cwd().makeOpenPath(app_data_dir, .{});
    };
    defer data_dir.close();

    var notes_dir = try data_dir.makeOpenPathIterable("notes", .{});
    defer notes_dir.close();

    const notes_dir_path = try notes_dir.dir.realpathAlloc(gpa.allocator(), "./");
    defer gpa.allocator().free(notes_dir_path);

    try http.FileServer.init(gpa.allocator(), .{ .dir_path = notes_dir_path, .base_path = "files" });
    defer http.FileServer.deinit();

    var ctx = Context{
        .data_dir = data_dir,
        .notes_dir = notes_dir,
    };

    std.log.info("Serving on http://{s}:{}", .{ "0.0.0.0", DEFAULT_PORT });
    try http.listenAndServe(
        gpa.allocator(),
        try std.net.Address.parseIp("0.0.0.0", DEFAULT_PORT),
        &ctx,
        index,
    );
}

fn index(ctx: *Context, res: *http.Response, req: http.Request) !void {
    const path = req.path();
    if (std.mem.startsWith(u8, path, "/files/")) {
        return try http.FileServer.serve({}, res, req);
    }

    _ = req;
    try res.writer().writeAll("Hello, Zig!\n");

    try res.headers.put("Content-Type", "text/html");

    var iter = ctx.notes_dir.iterate();
    while (try iter.next()) |entry| {
        // TODO: format escapes for html specifically
        try res.writer().print("<div><img src=\"/files/{}\"></div>\n", .{std.zig.fmtEscapes(entry.name)});
    }
}
