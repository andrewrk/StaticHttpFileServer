const std = @import("std");
const StaticHttpFileServer = @import("StaticHttpFileServer");

test "basic usage" {
    const gpa = std.testing.allocator;

    var static_http_file_server = try StaticHttpFileServer.init(.{});

    var http_server = std.http.Server.init(gpa, .{
        .reuse_address = true,
    });
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    try http_server.listen(address);
    const server_port = http_server.socket.listen_address.in.getPort();

    _ = server_port;

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
