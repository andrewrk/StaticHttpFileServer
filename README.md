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

Depends on unmerged Zig changes: https://github.com/ziglang/zig/pull/18160

## Roadmap

1. Don't close the connection unnecessarily
2. gzip compression
3. Support more HTTP headers
   * `ETag`
   * `If-None-Match`
   * `If-Modified-Since`
   * `Accept-Encoding`
   * `Content-Encoding`
