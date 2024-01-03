# Simple Static HTTP File Server Zig Module

Upon initialization, this module recursively walks the specified directory and
permanently caches all file contents to memory. When handling an HTTP request,
this module will never touch the file system.

As part of this process, it will compress the file contents using gzip, and
then choose whether to keep the compressed version or uncompressed version
based on a configurable compression ratio (defaulting to 95%).

This module is well-suited for web applications that have a fixed set of
unchanging assets that have no problem fitting into memory.

I have a
[similar project for Node.js](https://github.com/andrewrk/connect-static).

## Status

Basic features work, but see the roadmap below for planned enhancements.

## Synopsis

```zig
const StaticHttpFileServer = @import("StaticHttpFileServer");

var static_http_file_server = try StaticHttpFileServer.init(.{
    .allocator = gpa,
    .root_dir = tmp.dir,
});
defer static_http_file_server.deinit(gpa);

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
```

## Roadmap

1. Don't close the connection unnecessarily
2. gzip compression
3. Support more HTTP headers
   * `ETag`
   * `If-None-Match`
   * `If-Modified-Since`
   * `Accept-Encoding`
   * `Content-Encoding`
