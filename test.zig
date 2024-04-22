const std = @import("std");
const StaticHttpFileServer = @import("StaticHttpFileServer");

test "basic usage" {
    const gpa = std.testing.allocator;

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var http_server = try address.listen(.{
        .reuse_address = true,
    });

    const port = http_server.listen_address.in.getPort();

    const server_thread = try std.Thread.spawn(.{}, serverThread, .{&http_server});
    defer server_thread.join();

    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    {
        var headers_buffer: [1024]u8 = undefined;
        var req = try client.open(.GET, .{
            .scheme = "http",
            .host = .{ .percent_encoded = "127.0.0.1" },
            .port = port,
            .path = .{ .percent_encoded = "/" },
        }, .{
            .server_header_buffer = &headers_buffer,
        });
        defer req.deinit();

        try req.send();
        try req.wait();

        var buf: [4000]u8 = undefined;
        const amt_read = try req.readAll(&buf);
        const body = buf[0..amt_read];

        try std.testing.expectEqualStrings("text/html", req.response.content_type.?);
        try std.testing.expectEqualStrings("<!doctype html>", body);
    }
}

fn serverThread(net_server: *std.net.Server) anyerror!void {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile2(.{
        .sub_path = "index.html",
        .data = "<!doctype html>",
    });

    try tmp.dir.writeFile2(.{
        .sub_path = "404.html",
        .data = "<!doctype html>404",
    });

    var static_http_file_server = try StaticHttpFileServer.init(.{
        .allocator = gpa,
        .root_dir = tmp.dir,
    });
    defer static_http_file_server.deinit(gpa);

    var read_buffer: [1024]u8 = undefined;
    var remaining: usize = 1;
    while (remaining != 0) : (remaining -= 1) {
        var connection = try net_server.accept();
        defer connection.stream.close();

        var http_server = std.http.Server.init(connection, &read_buffer);

        try std.testing.expect(http_server.state == .ready);
        var request = try http_server.receiveHead();
        try static_http_file_server.serve(&request);
        try std.testing.expect(http_server.state == .ready);
        try std.testing.expectError(error.HttpConnectionClosing, http_server.receiveHead());
    }
}
