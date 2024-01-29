const std = @import("std");
const StaticHttpFileServer = @import("StaticHttpFileServer");

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(arena);

    var listen_port: u16 = 0;
    var opt_root_dir_path: ?[]const u8 = null;

    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "-p")) {
                    i += 1;
                    if (i >= args.len) fatal("expected arg after '{s}'", .{arg});
                    listen_port = std.fmt.parseInt(u16, args[i], 10) catch |err| {
                        fatal("unable to parse port '{s}': {s}", .{ args[i], @errorName(err) });
                    };
                } else {
                    fatal("unrecognized argument: '{s}'", .{arg});
                }
            } else if (opt_root_dir_path == null) {
                opt_root_dir_path = arg;
            } else {
                fatal("unexpected positional argument: '{s}'", .{arg});
            }
        }
    }

    const root_dir_path = opt_root_dir_path orelse fatal("missing root dir path", .{});

    var root_dir = std.fs.cwd().openDir(root_dir_path, .{ .iterate = true }) catch |err|
        fatal("unable to open directory '{s}': {s}", .{ root_dir_path, @errorName(err) });
    defer root_dir.close();

    var static_http_file_server = try StaticHttpFileServer.init(.{
        .allocator = gpa,
        .root_dir = root_dir,
    });
    defer static_http_file_server.deinit(gpa);

    var http_server = std.http.Server.init(.{
        .reuse_address = true,
    });
    const address = try std.net.Address.parseIp("127.0.0.1", listen_port);
    try http_server.listen(address);
    const port = http_server.socket.listen_address.in.getPort();
    std.debug.print("Listening at http://127.0.0.1:{d}/\n", .{port});

    var header_buffer: [1024]u8 = undefined;
    accept: while (true) {
        var res = try http_server.accept(.{
            .allocator = gpa,
            .header_strategy = .{ .static = &header_buffer },
        });
        defer res.deinit();

        while (res.reset() != .closing) {
            res.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :accept,
                error.EndOfStream => continue,
                else => return err,
            };
            try static_http_file_server.serve(&res);
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}
