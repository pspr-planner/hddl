//! HDDL (Hierarchical Domain Definition Language) parser.
//!
//! A Zig port of the parser from https://github.com/koala-planner/HDDL-Parser.
//! It lexes and parses HDDL domains and problems into an AST; semantic
//! verification and transpilation are intentionally out of scope.
//!
//! Typical usage:
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(allocator);
//! defer arena.deinit();
//!
//! // Use `Parser.init` instead if `source` is temporary: it copies the input.
//! var parser = hddl.Parser.initBorrowed(arena.allocator(), source);
//! const parsed = try parser.parse(); // hddl.ast.Ast
//! ```
//!
//! Parsing allocates every AST node and string copy from the supplied
//! allocator, so an arena (or another bump-style allocator) is the intended
//! choice. The parser reduces allocator pressure internally by batching
//! formula nodes into slabs and reusing scratch lists for argument lists,
//! subtasks, orderings, and constraints.

const std = @import("std");

pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

pub const Token = token.Token;
pub const TokenPosition = token.TokenPosition;
pub const Keyword = token.Keyword;
pub const Operator = token.Operator;
pub const Punctuator = token.Punctuator;
pub const Requirement = token.Requirement;
pub const Number = token.Number;

pub const Lexer = lexer.Lexer;
pub const Parser = parser.Parser;
pub const Diagnostic = parser.Diagnostic;

pub const Error = parser.Error || error{ExpectedDomain};

/// Parse a single HDDL file (domain or problem).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!ast.Ast {
    var p = try Parser.init(allocator, source);
    return p.parse();
}

/// Parse a domain file.
pub fn parseDomain(allocator: std.mem.Allocator, source: []const u8) Error!ast.Domain {
    return switch (try parse(allocator, source)) {
        .domain => |domain| domain,
        .problem => error.ExpectedDomain,
    };
}

/// Parse a problem file.
pub fn parseProblem(allocator: std.mem.Allocator, source: []const u8) Error!ast.Problem {
    return switch (try parse(allocator, source)) {
        .problem => |problem| problem,
        .domain => error.ExpectedDomain,
    };
}

/// Parse a domain and an optional problem.
pub fn parseProgram(
    allocator: std.mem.Allocator,
    domain_source: []const u8,
    problem_source: ?[]const u8,
) Error!ast.Program {
    const domain = try parseDomain(allocator, domain_source);
    const problem = if (problem_source) |source|
        try parseProblem(allocator, source)
    else
        null;
    return .{ .domain = domain, .problem = problem };
}

// Re-export everything from the AST module for convenience.
pub const Action = ast.Action;
pub const Ast = ast.Ast;
pub const Constraint = ast.Constraint;
pub const Domain = ast.Domain;
pub const Formula = ast.Formula;
pub const Function = ast.Function;
pub const HTN = ast.HTN;
pub const InitialTaskNetwork = ast.InitialTaskNetwork;
pub const Method = ast.Method;
pub const Ordering = ast.Ordering;
pub const Predicate = ast.Predicate;
pub const Problem = ast.Problem;
pub const Program = ast.Program;
pub const Subtask = ast.Subtask;
pub const Symbol = ast.Symbol;
pub const Task = ast.Task;
pub const TaskOrdering = ast.TaskOrdering;

test {
    std.testing.refAllDecls(@This());
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("reference_tests.zig");
}
