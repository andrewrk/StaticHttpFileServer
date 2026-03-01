const std = @import("std");
const Io = std.Io;

const StaticHttpFileServer = @import("StaticHttpFileServer");

test "basic usage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var http_server = try address.listen(io, .{
        .reuse_address = true,
    });

    const port = http_server.socket.address.ip4.port;

    var server_task = try io.concurrent(serverTask, .{ io, &http_server });
    defer server_task.cancel(io) catch {};

    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
    };
    defer client.deinit();

    {
        var req = try client.request(.GET, .{
            .scheme = "http",
            .host = .{ .percent_encoded = "127.0.0.1" },
            .port = port,
            .path = .{ .percent_encoded = "/" },
        }, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [1000]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        try std.testing.expectEqualStrings("text/html", response.head.content_type.?);

        var response_buf: [1000]u8 = undefined;
        const reader = response.reader(&response_buf);

        var body_buf: [1000]u8 = undefined;
        const amt_read = try reader.readSliceShort(&body_buf);
        const body = body_buf[0..amt_read];

        try std.testing.expectEqualStrings("<!doctype html>", body);
    }

    try server_task.await(io);
}

fn serverTask(io: Io, net_server: *Io.net.Server) anyerror!void {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<!doctype html>",
    });

    try tmp.dir.writeFile(io, .{
        .sub_path = "404.html",
        .data = "<!doctype html>404",
    });

    var static_http_file_server = try StaticHttpFileServer.init(gpa, io, .{
        .root_dir = tmp.dir,
    });
    defer static_http_file_server.deinit(gpa);

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var remaining: usize = 1;
    while (remaining != 0) : (remaining -= 1) {
        var stream = try net_server.accept(io);
        defer stream.close(io);

        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);

        var request = try http_server.receiveHead();
        try static_http_file_server.serve(&request);
    }
}
