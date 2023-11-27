/// The key is HTTP request path.
files: std.StringArrayHashMap(File),

pub const File = struct {
    mime_type: mime.Type,
    contents: []u8,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    root_dir: fs.Dir,
    cache_control_header: []const u8 = "max-age=0, must-revalidate",
    max_file_size: usize = std.math.maxInt(usize),
    aliases: []const Alias = &.{ .request_path = "/", .file_path = "/index.html" },
    ignoreFile: *const fn (path: []const u8) bool = &defaultIgnoreFile,

    pub const Alias = struct {
        request_path: []const u8,
        file_path: []const u8,
    };
};

pub const InitError = error{
    OutOfMemory,
    InitFailed,
};

pub fn init(options: Options) InitError!Server {
    const gpa = options.allocator;

    var it = try options.root_dir.walk(gpa);
    defer it.deinit();

    var files = std.StringHashMap(File).init(gpa);
    errdefer files.deinit();

    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (options.ignoreFile(entry.path)) continue;
                const bytes = options.root_dir.readFileAlloc(gpa, entry.path, options.max_file_size) catch |err| {
                    log.err("unable to read '{s}': {s}", .{ entry.path, @errorName(err) });
                    return error.InitFailed;
                };
                errdefer gpa.free(bytes);
                const sub_path = try normalizePathAlloc(gpa, entry.path);
                errdefer gpa.free(sub_path);
                const ext = fs.path.extension(sub_path);
                const file: File = .{
                    .mime_type = mime.extension_map.get(ext) orelse
                        .@"application/octet-stream",
                    .contents = bytes,
                };
                try files.put(sub_path, file);
            },
            else => continue,
        }
    }

    for (options.aliases) |alias| {
        const file = files.get(alias.file_path) orelse {
            log.err("alias '{s}' points to nonexistent file '{s}'", .{
                alias.request_path, alias.file_path,
            });
            return error.InitFailed;
        };
        try files.put(alias.request_path, file);
    }

    return .{
        .files = files,
    };
}

pub fn deinit(s: *Server) void {
    const gpa = s.files.allocator;
    for (s.files.keys(), s.files.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    s.files.deinit();
    s.* = undefined;
}

pub const ServeError = error{
    FileNotFound,
    OutOfMemory,
} || std.http.Server.Connection.WriteError;

pub fn serve(s: *Server, res: *std.http.Server.Response) ServeError!void {
    const path = res.request.target;
    const file = s.files.get(path) orelse return error.FileNotFound;

    res.transfer_encoding = .{ .content_length = file.contents.len };
    try res.headers.append("content-type", @tagName(file.mime_type));
    try res.headers.append("connection", "close");
    try res.send();

    try res.writeAll(file.contents);
    try res.finish();
}

pub fn defaultIgnoreFile(path: []const u8) bool {
    const basename = fs.path.basename(path);
    return std.mem.startsWith(u8, basename, ".") or
        std.mem.endsWith(u8, basename, "~");
}

const Server = @This();
const mime = @import("mime");
const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const log = std.log.scoped(.@"static-http-files");

/// Make a file system path identical independently of operating system path
/// inconsistencies. This converts backslashes into forward slashes.
fn normalizePathAlloc(allocator: std.mem.Allocator, fs_path: []const u8) ![]const u8 {
    const new_buffer = try allocator.alloc(u8, fs_path.len + 1);
    new_buffer[0] = canonical_sep;
    @memcpy(new_buffer[1..], fs_path);
    if (fs.path.sep != canonical_sep)
        normalizePath(new_buffer);
    return new_buffer;
}

const canonical_sep = fs.path.sep_posix;

fn normalizePath(bytes: []u8) void {
    assert(fs.path.sep != canonical_sep);
    std.mem.replaceScalar(u8, bytes, fs.path.sep, canonical_sep);
}
