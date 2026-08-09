const Server = @This();

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.@"static-http-files");

const mime = @import("mime");

const canonical_sep = Dir.path.sep_posix;

/// The key is index into backing_memory, where a HTTP request path is stored.
files: File.Table,
/// Stores file names relative to root directory and file contents, interleaved.
bytes: std.ArrayList(u8),

pub const File = struct {
    mime_type: mime.Type,
    name_start: usize,
    name_len: u16,
    /// Stored separately to make aliases work.
    contents_start: usize,
    contents_len: usize,

    pub const Table = std.HashMapUnmanaged(
        File,
        void,
        FileNameContext,
        std.hash_map.default_max_load_percentage,
    );
};

pub const Options = struct {
    /// Must have been opened with iteration permissions.
    root_dir: Dir,
    cache_control_header: []const u8 = "max-age=0, must-revalidate",
    max_file_size: usize = std.math.maxInt(usize),
    /// Special alias "404" allows setting a particular file as the file sent
    /// for "not found" errors. If this alias is not provided, `serve` returns
    /// `error.FileNotFound` instead, leaving the response's state unmodified.
    aliases: []const Alias = &.{
        .{ .request_path = "/", .file_path = "/index.html" },
        .{ .request_path = "404", .file_path = "/404.html" },
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

pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Server {
    var it = try options.root_dir.walk(gpa);
    defer it.deinit();

    var files: File.Table = .{};
    errdefer files.deinit(gpa);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);

    while (it.next(io) catch |err| {
        log.err("unable to scan root directory: {t}", .{err});
        return error.InitFailed;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                if (options.ignoreFile(entry.path)) continue;

                var file = options.root_dir.openFile(io, entry.path, .{}) catch |err| {
                    log.err("unable to open '{s}': {t}", .{ entry.path, err });
                    return error.InitFailed;
                };
                defer file.close(io);

                const size = file.length(io) catch |err| {
                    log.err("unable to stat '{s}': {t}", .{ entry.path, err });
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
                if (Dir.path.sep != canonical_sep)
                    normalizePath(bytes.items[name_start..][0..name_len]);

                const contents_start = bytes.items.len;
                const contents_len = file.readPositionalAll(io, bytes.unusedCapacitySlice(), 0) catch |e| {
                    log.err("unable to read '{s}': {t}", .{ entry.path, e });
                    return error.InitFailed;
                };
                if (contents_len != size) {
                    log.err("unexpected EOF when reading '{s}'", .{entry.path});
                    return error.InitFailed;
                }
                bytes.items.len += contents_len;

                const ext = Dir.path.extension(entry.basename);

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

pub fn deinit(s: *Server, allocator: Allocator) void {
    s.files.deinit(allocator);
    s.bytes.deinit(allocator);
    s.* = undefined;
}

pub const ServeError = error{ FileNotFound, HttpExpectationFailed, WriteFailed };

pub fn serve(s: *Server, request: *std.http.Server.Request) ServeError!void {
    const path = request.head.target;
    const file_name_adapter: FileNameAdapter = .{ .bytes = s.bytes.items };
    const file, const status: std.http.Status = b: {
        break :b .{
            s.files.getKeyAdapted(path, file_name_adapter) orelse {
                break :b .{
                    s.files.getKeyAdapted(@as([]const u8, "404"), file_name_adapter) orelse
                        return error.FileNotFound,
                    .not_found,
                };
            },
            .ok,
        };
    };
    const content = s.bytes.items[file.contents_start..][0..file.contents_len];

    return request.respond(content, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = @tagName(file.mime_type) },
        },
    });
}

pub fn defaultIgnoreFile(path: []const u8) bool {
    const basename = Dir.path.basename(path);
    return std.mem.startsWith(u8, basename, ".") or
        std.mem.endsWith(u8, basename, "~");
}

fn normalizePath(bytes: []u8) void {
    assert(Dir.path.sep != canonical_sep);
    std.mem.replaceScalar(u8, bytes, Dir.path.sep, canonical_sep);
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
