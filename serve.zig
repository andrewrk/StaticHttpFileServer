const std = @import("std");
const StaticHttpFileServer = @import("StaticHttpFileServer");

const EPOLL = std.os.linux.EPOLL;

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

    const epoll = std.posix.epoll_create1(0) catch |err|
        fatal("unable to create an epoll: {s}", .{@errorName(err)});

    const address = try std.net.Address.parseIp("127.0.0.1", listen_port);
    var http_server = try address.listen(.{
        .reuse_address = true,
    });
    const port = http_server.listen_address.in.getPort();
    std.debug.print("Listening at http://127.0.0.1:{d}/\n", .{port});

    var events: [10]std.os.linux.epoll_event = undefined;
    {
        var ctl_ev = std.os.linux.epoll_event{
            .events = EPOLL.IN,
            .data = .{ .fd = http_server.stream.handle },
        };
        std.posix.epoll_ctl(epoll, EPOLL.CTL_ADD, http_server.stream.handle, &ctl_ev) catch |err|
            fatal("unable to add listener to epoll: {s}", .{@errorName(err)});
    }

    var read_buffer: [8000]u8 = undefined;
    var conns = std.AutoArrayHashMap(std.posix.fd_t, std.http.Server).init(gpa);
    defer conns.deinit();
    while (true) {
        const nfds = std.posix.epoll_wait(epoll, &events, -1);
        events: for (0..nfds) |i| {
            const ev = events[i];
            if (ev.data.fd == http_server.stream.handle) {
                const conn = try http_server.accept();
                var ctl_ev = std.os.linux.epoll_event{
                    .events = EPOLL.IN,
                    .data = .{ .fd = conn.stream.handle },
                };
                std.posix.epoll_ctl(epoll, EPOLL.CTL_ADD, conn.stream.handle, &ctl_ev) catch |err| {
                    std.debug.print(
                        "could not epoll peer '{}': {s}\n",
                        .{ conn.address, @errorName(err) },
                    );
                    continue :events;
                };
                try conns.put(conn.stream.handle, .init(conn, &read_buffer));
            } else {
                const server = conns.getPtr(ev.data.fd).?;
                defer {
                    std.posix.epoll_ctl(epoll, EPOLL.CTL_DEL, server.connection.stream.handle, null) catch |err| {
                        std.debug.print(
                            "could not remove peer '{}' from epoll: {s}\n",
                            .{ server.connection.address, @errorName(err) },
                        );
                    };
                    server.connection.stream.close();
                    _ = conns.swapRemove(ev.data.fd);
                }

                if (server.state == .ready) {
                    var request = server.receiveHead() catch |err| {
                        std.debug.print(
                            "recv error with peer {}: {s}\n",
                            .{ server.connection.address, @errorName(err) },
                        );
                        continue :events;
                    };
                    try static_http_file_server.serve(&request);
                }
            }
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
}
