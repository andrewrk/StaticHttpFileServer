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

Blocked by https://github.com/ziglang/zig/issues/14719. After I shave that yak,
I'll come back and finish this project.

## Roadmap

1. https://github.com/ziglang/zig/issues/14719
2. Don't close the connection unnecessarily
3. gzip compression
4. Support more HTTP headers
   * `ETag`
   * `If-None-Match`
   * `If-Modified-Since`
   * `Accept-Encoding`
   * `Content-Encoding`
5. Instead of an Allocator, accept an ArrayList(u8).
