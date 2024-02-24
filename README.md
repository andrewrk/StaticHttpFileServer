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

Initialize:

```zig
const StaticHttpFileServer = @import("StaticHttpFileServer");

var static_http_file_server = try StaticHttpFileServer.init(.{
    .allocator = gpa,
    .root_dir = tmp.dir,
});
defer static_http_file_server.deinit(gpa);
```

Then hand off a request to be serviced:

```zig
try static_http_file_server.serve(&http_request);
```

See also `serve.zig` for a standalone example.

## Roadmap

1. gzip compression
2. Support more HTTP headers
   * `ETag`
   * `If-None-Match`
   * `If-Modified-Since`
   * `Accept-Encoding`
   * `Content-Encoding`

## Testing

Standard unit tests:

```
zig build test
```

There is also this:

```
zig build serve -- [path]
```

Starts listening on localhost and serves static files at [path] so you can poke
around manually.
