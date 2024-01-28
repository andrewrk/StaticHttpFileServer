const std = @import("std");
const StaticHttpFileServer = @import("StaticHttpFileServer");

test "basic usage" {
    const gpa = std.testing.allocator;

    var http_server = std.http.Server.init(.{
        .reuse_address = true,
    });
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    try http_server.listen(address);

    const port = http_server.socket.listen_address.in.getPort();

    const server_thread = try std.Thread.spawn(.{}, serverThread, .{&http_server});
    defer server_thread.join();

    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    var h = std.http.Headers{ .allocator = gpa };
    defer h.deinit();

    {
        var req = try client.open(.GET, .{
            .scheme = "http",
            .host = "127.0.0.1",
            .port = port,
            .path = "/",
        }, h, .{});
        defer req.deinit();

        try req.send(.{});
        try req.wait();

        var buf: [4000]u8 = undefined;
        const amt_read = try req.readAll(&buf);
        const body = buf[0..amt_read];

        try std.testing.expectEqualStrings("text/html", req.response.headers.getFirstValue("content-type").?);
        try std.testing.expectEqualStrings("<!doctype html>", body);
    }
}

fn serverThread(http_server: *std.http.Server) anyerror!void {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile2(.{
        .sub_path = "index.html",
        .data = "<!doctype html>",
    });

    var static_http_file_server = try StaticHttpFileServer.init(.{
        .allocator = gpa,
        .root_dir = tmp.dir,
    });
    defer static_http_file_server.deinit(gpa);

    var header_buffer: [1024]u8 = undefined;
    var remaining: usize = 1;
    accept: while (remaining != 0) : (remaining -= 1) {
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
