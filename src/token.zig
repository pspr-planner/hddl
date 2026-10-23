//! Token definitions for the HDDL lexical analyzer.
//!
//! Mirrors the token types of the reference HDDL parser
//! (https://github.com/koala-planner/HDDL-Parser).

const std = @import("std");

pub const TokenPosition = struct {
    line: u32 = 1,

    pub fn write(self: TokenPosition, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{self.line});
    }
};

/// Numeric literal.
pub const Number = union(enum) {
    integer: i64,
    real: f64,

    pub fn write(self: Number, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .integer => |value| try w.print("{}", .{value}),
            .real => |value| try w.print("{}", .{value}),
        }
    }
};

pub const Keyword = enum {
    define,
    domain,
    problem,
    requirements,
    objects,
    types,
    task,
    constants,
    predicates,
    functions,
    init,
    htn,
    action,
    parameters,
    method,
    precondition,
    effect,
    subtasks,
    ordered_subtasks,
    ordering,
    constraints,
    goal,

    pub fn text(self: Keyword) []const u8 {
        return switch (self) {
            .define => "define",
            .domain => "domain",
            .problem => "problem",
            .requirements => ":requirements",
            .objects => ":objects",
            .types => ":types",
            .task => ":task",
            .constants => ":constants",
            .predicates => ":predicates",
            .functions => ":functions",
            .init => ":init",
            .htn => ":htn",
            .action => ":action",
            .parameters => ":parameters",
            .method => ":method",
            .precondition => ":precondition",
            .effect => ":effect",
            .subtasks => ":subtasks",
            .ordered_subtasks => ":ordered-subtasks",
            .ordering => ":ordering",
            .constraints => ":constraints",
            .goal => ":goal",
        };
    }
};

pub const Punctuator = enum {
    dash,
    lparen,
    rparen,

    pub fn text(self: Punctuator) []const u8 {
        return switch (self) {
            .dash => "-",
            .lparen => "(",
            .rparen => ")",
        };
    }
};

pub const Operator = enum {
    logical_or,
    logical_not,
    logical_and,
    xor,
    forall,
    exists,
    imply,
    probabilistic,
    equal,
    less_than,
    greater_than,
    less_than_or_equal,
    greater_than_or_equal,

    pub fn text(self: Operator) []const u8 {
        return switch (self) {
            .logical_or => "or",
            .logical_not => "not",
            .logical_and => "and",
            .xor => "oneof",
            .forall => "forall",
            .exists => "exists",
            .imply => "imply",
            .probabilistic => "probabilistic",
            .equal => "=",
            .less_than => "<",
            .greater_than => ">",
            .less_than_or_equal => "<=",
            .greater_than_or_equal => ">=",
        };
    }
};

pub const Requirement = enum {
    method_preconditions,
    hierarchy,
    typing,
    negative_preconditions,
    universal_preconditions,
    existential_preconditions,
    quantified_preconditions,
    equality,
    strips,
    probabilistic_effects,
    conditional_effects,
    domain_axioms,

    pub fn text(self: Requirement) []const u8 {
        return switch (self) {
            .method_preconditions => ":method-preconditions",
            .hierarchy => ":hierarchy",
            .typing => ":typing",
            .negative_preconditions => ":negative-preconditions",
            .universal_preconditions => ":universal-preconditions",
            .existential_preconditions => ":existential-preconditions",
            .quantified_preconditions => ":quantified-preconditions",
            .equality => ":equality",
            .strips => ":strips",
            .probabilistic_effects => ":probabilistic-effects",
            .conditional_effects => ":conditional-effects",
            .domain_axioms => ":domain-axioms",
        };
    }
};

pub const Token = union(enum) {
    keyword: Keyword,
    identifier: []const u8,
    number: Number,
    operator: Operator,
    punctuator: Punctuator,
    requirement: Requirement,
    eof,

    pub fn isPunctuator(self: Token, punct: Punctuator) bool {
        return switch (self) {
            .punctuator => |p| p == punct,
            else => false,
        };
    }

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return switch (self) {
            .keyword => |k| k == keyword,
            else => false,
        };
    }

    pub fn isOperator(self: Token, operator: Operator) bool {
        return switch (self) {
            .operator => |o| o == operator,
            else => false,
        };
    }

    pub const Description = struct {
        kind: []const u8,
        lexeme: ?[]const u8 = null,
        number: ?Number = null,
    };

    pub fn describe(self: Token) Description {
        return switch (self) {
            .keyword => |k| .{ .kind = "keyword", .lexeme = k.text() },
            .identifier => |name| .{ .kind = "identifier", .lexeme = name },
            .number => |n| .{ .kind = "number", .number = n },
            .operator => |o| .{ .kind = "operator", .lexeme = o.text() },
            .punctuator => |p| .{ .kind = "punctuator", .lexeme = p.text() },
            .requirement => |r| .{ .kind = "requirement", .lexeme = r.text() },
            .eof => .{ .kind = "end of file" },
        };
    }

    pub fn write(self: Token, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = self.describe();
        try w.writeAll(d.kind);
        if (d.lexeme) |lexeme| try w.print(" '{s}'", .{lexeme});
        if (d.number) |number| {
            try w.writeByte(' ');
            try number.write(w);
        }
    }
};

test "number formatting" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Number{ .integer = 42 }).write(&w);
    try std.testing.expectEqualStrings("42", w.buffered());
}
