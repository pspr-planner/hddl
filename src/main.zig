const std = @import("std");
const Io = std.Io;

const hddl = @import("hddl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();

    _ = args.next(); // program name
    const domain_path = args.next() orelse {
        try stderr.writeAll("usage: hddl <domain.hddl> [problem.hddl]\n");
        try stderr.flush();
        std.process.exit(2);
    };
    const problem_path = args.next();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const domain_source = std.Io.Dir.cwd().readFileAlloc(io, domain_path, allocator, .unlimited) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ domain_path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    var domain_parser = hddl.Parser.initBorrowed(allocator, domain_source);
    const domain_ast = domain_parser.parse() catch {
        try stderr.print("error: {s}: ", .{domain_path});
        if (domain_parser.diagnostic) |diagnostic| try diagnostic.write(stderr);
        try stderr.writeByte('\n');
        try stderr.flush();
        std.process.exit(1);
    };

    const domain = switch (domain_ast) {
        .domain => |domain| domain,
        .problem => {
            try stderr.print("error: {s}: expected a domain definition\n", .{domain_path});
            try stderr.flush();
            std.process.exit(1);
        },
    };

    var problem: ?hddl.Problem = null;
    if (problem_path) |path| {
        const problem_source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
            try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

        var problem_parser = hddl.Parser.initBorrowed(allocator, problem_source);
        const problem_ast = problem_parser.parse() catch {
            try stderr.print("error: {s}: ", .{path});
            if (problem_parser.diagnostic) |diagnostic| try diagnostic.write(stderr);
            try stderr.writeByte('\n');
            try stderr.flush();
            std.process.exit(1);
        };

        problem = switch (problem_ast) {
            .problem => |parsed| parsed,
            .domain => {
                try stderr.print("error: {s}: expected a problem definition\n", .{path});
                try stderr.flush();
                std.process.exit(1);
            },
        };
    }

    try stdout.print(
        "domain {s}: {d} predicates, {d} tasks, {d} methods, {d} actions, {d} functions\n",
        .{
            domain.name,
            domain.predicates.len,
            domain.compound_tasks.len,
            domain.methods.len,
            domain.actions.len,
            domain.functions.len,
        },
    );
    if (problem) |p| {
        try stdout.print(
            "problem {s} (domain {s}): {d} objects, {d} init facts, goal: {s}\n",
            .{
                p.name,
                p.domain_name,
                p.objects.len,
                p.init_state.len,
                if (p.goal != null) "yes" else "no",
            },
        );
    }

    try stdout.writeAll("\n");
    try domain.write(stdout);
    try stdout.writeByte('\n');
    if (problem) |p| {
        try p.write(stdout);
        try stdout.writeByte('\n');
    }

    try stdout.flush();
}
