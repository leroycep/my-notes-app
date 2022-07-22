const std = @import("std");
const http = @import("apple_pie");

pub const io_mode = .evented;

const DEFAULT_PORT = 40077;

const Context = struct {
    path: []const u8,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ctx = Context{
        .path = "/home/geemili/.local/share/my-notes-app",
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
    _ = req;
    try res.writer().writeAll("Hello, Zig!\n");
    try res.writer().print("directory is {s}\n", .{ctx.path});
}
