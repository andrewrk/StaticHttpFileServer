/// The key is index into backing_memory, where a HTTP request path is stored.
files: FileTable,
/// Stores file names relative to root directory and file contents, interleaved.
bytes: std.ArrayListUnmanaged(u8),

pub const FileTable = std.HashMapUnmanaged(
    File,
    void,
    FileNameContext,
    std.hash_map.default_max_load_percentage,
);

pub const File = struct {
    mime_type: mime.Type,
    name_start: usize,
    name_len: u16,
    /// Stored separately to make aliases work.
    contents_start: usize,
    contents_len: usize,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    /// Must have been opened with iteration permissions.
    root_dir: fs.Dir,
    cache_control_header: []const u8 = "max-age=0, must-revalidate",
    max_file_size: usize = std.math.maxInt(usize),
    aliases: []const Alias = &.{
        .{ .request_path = "/", .file_path = "/index.html" },
    },
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

    var files: FileTable = .{};
    errdefer files.deinit(gpa);

    var bytes: std.ArrayListUnmanaged(u8) = .{};
    errdefer bytes.deinit(gpa);

    while (it.next() catch |err| {
        log.err("unable to scan root directory: {s}", .{@errorName(err)});
        return error.InitFailed;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                if (options.ignoreFile(entry.path)) continue;

                var file = options.root_dir.openFile(entry.path, .{}) catch |err| {
                    log.err("unable to open '{s}': {s}", .{ entry.path, @errorName(err) });
                    return error.InitFailed;
                };
                defer file.close();

                const size = file.getEndPos() catch |err| {
                    log.err("unable to stat '{s}': {s}", .{ entry.path, @errorName(err) });
                    return error.InitFailed;
                };

                if (size > options.max_file_size) {
                    log.err("file exceeds maximum size: '{s}'", .{entry.path});
                    return error.InitFailed;
                }

                const name_len = 1 + entry.path.len;
                try bytes.ensureUnusedCapacity(gpa, name_len + size);

                // Make the file system path identical independently of
                // operating system path inconsistencies. This converts
                // backslashes into forward slashes.
                const name_start = bytes.items.len;
                bytes.appendAssumeCapacity(canonical_sep);
                bytes.appendSliceAssumeCapacity(entry.path);
                if (fs.path.sep != canonical_sep)
                    normalizePath(bytes.items[name_start..][0..name_len]);

                const contents_start = bytes.items.len;
                const contents_len = file.readAll(bytes.unusedCapacitySlice()) catch |e| {
                    log.err("unable to read '{s}': {s}", .{ entry.path, @errorName(e) });
                    return error.InitFailed;
                };
                if (contents_len != size) {
                    log.err("unexpected EOF when reading '{s}'", .{entry.path});
                    return error.InitFailed;
                }
                bytes.items.len += contents_len;

                const ext = fs.path.extension(entry.basename);

                try files.putNoClobberContext(gpa, .{
                    .mime_type = mime.extension_map.get(ext) orelse .@"application/octet-stream",
                    .name_start = name_start,
                    .name_len = @intCast(name_len),
                    .contents_start = contents_start,
                    .contents_len = contents_len,
                }, {}, FileNameContext{
                    .bytes = bytes.items,
                });
            },
            else => continue,
        }
    }

    try files.ensureUnusedCapacityContext(gpa, @intCast(options.aliases.len), FileNameContext{
        .bytes = bytes.items,
    });

    for (options.aliases) |alias| {
        const file = files.getKeyAdapted(alias.file_path, FileNameAdapter{
            .bytes = bytes.items,
        }) orelse {
            log.err("alias '{s}' points to nonexistent file '{s}'", .{
                alias.request_path, alias.file_path,
            });
            return error.InitFailed;
        };

        const name_start = bytes.items.len;
        try bytes.appendSlice(gpa, alias.request_path);

        if (files.getOrPutAssumeCapacityContext(.{
            .mime_type = file.mime_type,
            .name_start = name_start,
            .name_len = @intCast(alias.request_path.len),
            .contents_start = file.contents_start,
            .contents_len = file.contents_len,
        }, FileNameContext{
            .bytes = bytes.items,
        }).found_existing) {
            log.err("alias '{s}'->'{s}' clobbers existing file or alias", .{
                alias.request_path, alias.file_path,
            });
            return error.InitFailed;
        }
    }

    return .{
        .files = files,
        .bytes = bytes,
    };
}

pub fn deinit(s: *Server, allocator: std.mem.Allocator) void {
    s.files.deinit(allocator);
    s.bytes.deinit(allocator);
    s.* = undefined;
}

pub const ServeError = error{
    FileNotFound,
    OutOfMemory,
} || std.http.Server.Connection.WriteError;

pub fn serve(s: *Server, res: *std.http.Server.Response) ServeError!void {
    const path = res.request.target;
    const file = s.files.getKeyAdapted(path, FileNameAdapter{
        .bytes = s.bytes.items,
    }) orelse return error.FileNotFound;

    res.transfer_encoding = .{ .content_length = file.contents_len };
    try res.headers.append("content-type", @tagName(file.mime_type));
    try res.headers.append("connection", "close");
    res.send() catch |err| switch (err) {
        error.InvalidContentLength => unreachable,
        error.UnsupportedTransferEncoding => unreachable,
        else => |e| return e,
    };

    const contents = s.bytes.items[file.contents_start..][0..file.contents_len];

    res.writeAll(contents) catch |err| switch (err) {
        error.NotWriteable => unreachable,
        error.MessageTooLong => unreachable,
        else => |e| return e,
    };
    res.finish() catch |err| switch (err) {
        error.NotWriteable => unreachable,
        error.MessageTooLong => unreachable,
        error.MessageNotCompleted => unreachable,
        else => |e| return e,
    };
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

const canonical_sep = fs.path.sep_posix;

fn normalizePath(bytes: []u8) void {
    assert(fs.path.sep != canonical_sep);
    std.mem.replaceScalar(u8, bytes, fs.path.sep, canonical_sep);
}

const FileNameContext = struct {
    bytes: []const u8,

    pub fn eql(self: @This(), a: File, b: File) bool {
        const a_name = self.bytes[a.name_start..][0..a.name_len];
        const b_name = self.bytes[b.name_start..][0..b.name_len];
        return std.mem.eql(u8, a_name, b_name);
    }

    pub fn hash(self: @This(), x: File) u64 {
        const name = self.bytes[x.name_start..][0..x.name_len];
        return std.hash_map.hashString(name);
    }
};

const FileNameAdapter = struct {
    bytes: []const u8,

    pub fn eql(self: @This(), a_name: []const u8, b: File) bool {
        const b_name = self.bytes[b.name_start..][0..b.name_len];
        return std.mem.eql(u8, a_name, b_name);
    }

    pub fn hash(self: @This(), adapted_key: []const u8) u64 {
        _ = self;
        return std.hash_map.hashString(adapted_key);
    }
};
