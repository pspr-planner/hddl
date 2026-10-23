//! Parse-throughput benchmark over a directory of HDDL files.
//!
//! Usage: zig build bench -Doptimize=ReleaseFast -- [root] [iterations]
//!
//! The parser is run over every `*.hddl` file below `root` (default
//! `test_data/ipc`) for `iterations` rounds (default 5), each round using a
//! fresh arena. Files are read once up front so I/O is not measured.

const std = @import("std");
const Io = std.Io;
const hddl = @import("hddl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next(); // program name

    const root = args.next() orelse "test_data/ipc";
    const iterations = if (args.next()) |text|
        std.fmt.parseInt(usize, text, 10) catch 5
    else
        5;

    var paths = std.ArrayList([]const u8).empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }

    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".hddl")) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var sources = try gpa.alloc([]u8, paths.items.len);
    defer gpa.free(sources);

    var total_bytes: usize = 0;
    for (paths.items, 0..) |path, i| {
        sources[i] = try dir.readFileAlloc(io, path, gpa, .unlimited);
        total_bytes += sources[i].len;
    }
    defer for (sources) |source| gpa.free(source);

    // Warm up the page cache and CPU caches.
    try runOnce(gpa, sources);
    try runOnce(gpa, sources);
    try runLexOnce(gpa, sources);

    const parse_start = Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| try runOnce(gpa, sources);
    const parse_ns = parse_start.untilNow(io).raw.nanoseconds;

    const lex_start = Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| try runLexOnce(gpa, sources);
    const lex_ns = lex_start.untilNow(io).raw.nanoseconds;

    const total_mb = @as(f64, @floatFromInt(total_bytes * iterations)) / (1024.0 * 1024.0);
    const parse_seconds = @as(f64, @floatFromInt(parse_ns)) / std.time.ns_per_s;
    const lex_seconds = @as(f64, @floatFromInt(lex_ns)) / std.time.ns_per_s;

    try stdout.print(
        "{d} files, {d:.2} MiB, {d} iterations\n" ++
            "  lex:   {d:.3} s, {d:.2} MiB/s\n" ++
            "  parse: {d:.3} s, {d:.2} MiB/s, {d:.2} ms/file/iter\n",
        .{
            paths.items.len,
            total_mb,
            iterations,
            lex_seconds,
            total_mb / lex_seconds,
            parse_seconds,
            total_mb / parse_seconds,
            parse_seconds * 1000.0 / @as(f64, @floatFromInt(paths.items.len * iterations)),
        },
    );
    try stdout.flush();
}

fn runOnce(gpa: std.mem.Allocator, sources: []const []u8) !void {
    var bump: std.heap.ArenaAllocator = .init(gpa);
    defer bump.deinit();
    const allocator = bump.allocator();

    for (sources) |source| {
        var parser = try hddl.Parser.init(allocator, source);
        const parsed = try parser.parse();
        std.mem.doNotOptimizeAway(&parsed);
    }
}

fn runLexOnce(gpa: std.mem.Allocator, sources: []const []u8) !void {
    var bump: std.heap.ArenaAllocator = .init(gpa);
    defer bump.deinit();
    const allocator = bump.allocator();

    for (sources) |source| {
        const copy = try allocator.dupe(u8, source);
        var lexer = hddl.Lexer.init(copy);
        var checksum: usize = 0;
        while (true) {
            const token = try lexer.next();
            checksum +%= @intFromEnum(std.meta.activeTag(token));
            if (token == .eof) break;
        }
        std.mem.doNotOptimizeAway(checksum);
    }
}
