//! Lexical analyzer for HDDL.
//!
//! The scanner follows the behavior of the reference implementation:
//! `;` starts a line comment, `?` is part of variable names, identifiers may
//! contain alphanumerics, `_` and `-`, and `:`-prefixed words are keywords or
//! requirements.

const std = @import("std");
const builtin = @import("builtin");
const tk = @import("token.zig");

/// Width of the SIMD lanes used to classify token bytes. 16 bytes fits every
/// supported target (and maps to a single SSE2/NEON register).
const vector_len = 16;
const ByteVector = @Vector(vector_len, u8);
const BoolVector = @Vector(vector_len, bool);
const native_endian = builtin.cpu.arch.endian();

inline fn isWhitespaceVector(chunk: ByteVector) BoolVector {
    return (chunk == @as(ByteVector, @splat(' '))) |
        (chunk == @as(ByteVector, @splat('\t'))) |
        (chunk == @as(ByteVector, @splat('\r'))) |
        (chunk == @as(ByteVector, @splat('\n')));
}

/// Bytes that may appear inside an identifier (the leading `?` is handled
/// separately because it is only valid in the first position).
inline fn isIdentifierBodyVector(chunk: ByteVector) BoolVector {
    const lower = (chunk >= @as(ByteVector, @splat('a'))) & (chunk <= @as(ByteVector, @splat('z')));
    const upper = (chunk >= @as(ByteVector, @splat('A'))) & (chunk <= @as(ByteVector, @splat('Z')));
    const digit = (chunk >= @as(ByteVector, @splat('0'))) & (chunk <= @as(ByteVector, @splat('9')));
    return lower | upper | digit |
        (chunk == @as(ByteVector, @splat('_'))) |
        (chunk == @as(ByteVector, @splat('-')));
}

/// Bytes that terminate a lexeme.
inline fn isDelimiterVector(chunk: ByteVector) BoolVector {
    return isWhitespaceVector(chunk) |
        (chunk == @as(ByteVector, @splat('('))) |
        (chunk == @as(ByteVector, @splat(')')));
}

inline fn firstSetBit(mask: u16) u4 {
    std.debug.assert(mask != 0);
    return if (native_endian == .little)
        @intCast(@ctz(mask))
    else
        @intCast(15 - @clz(mask));
}

/// Mask selecting the bits that correspond to vector lanes `[0, n)`.
inline fn prefixMask(n: u4) u16 {
    if (n == 0) return 0;
    return if (native_endian == .little)
        @intCast((@as(u32, 1) << n) - 1)
    else
        @intCast((@as(u32, 0xffff) << (16 - @as(u32, n))) & 0xffff);
}

pub const Error = error{
    InvalidKeyword,
    InvalidIdentifier,
    InvalidNumber,
    InvalidCharacter,
};

pub const ErrorKind = enum {
    invalid_keyword,
    invalid_identifier,
    invalid_number,
    invalid_character,

    pub fn text(self: ErrorKind) []const u8 {
        return switch (self) {
            .invalid_keyword => "a valid keyword or requirement",
            .invalid_identifier => "a valid identifier",
            .invalid_number => "a valid number",
            .invalid_character => "a valid input token",
        };
    }
};

pub const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,
    line: u32 = 1,
    last_pos: tk.TokenPosition = .{},

    err_kind: ErrorKind = .invalid_character,
    err_lexeme: []const u8 = "",
    err_line: u32 = 1,
    /// Cursor position to commit to when a token fails to scan. This matches
    /// the reference lexer, which consumes the offending lexeme and keeps
    /// going on the next call.
    err_cursor: usize = 0,

    /// Cached result of `peek`, so that the common `peek` + `next` pattern
    /// scans each token exactly once.
    peeked: ?Scan = null,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn reset(self: *Lexer) void {
        self.cursor = 0;
        self.line = 1;
        self.last_pos = .{ .line = 1 };
        self.peeked = null;
    }

    /// Position of the most recently returned token.
    pub inline fn lastPosition(self: *const Lexer) tk.TokenPosition {
        return self.last_pos;
    }

    /// Return the next token without advancing.
    pub inline fn peek(self: *Lexer) Error!tk.Token {
        if (self.peeked) |cached| {
            self.last_pos = cached.pos;
            return cached.token;
        }
        const scan_result = try self.scan(self.cursor, self.line);
        // Keep positions meaningful for diagnostics raised about the peeked
        // token.
        self.last_pos = scan_result.pos;
        self.peeked = scan_result;
        return scan_result.token;
    }

    /// Consume and return the next token.
    pub inline fn next(self: *Lexer) Error!tk.Token {
        if (self.peeked) |cached| {
            self.peeked = null;
            self.cursor = cached.cursor;
            self.line = cached.line;
            self.last_pos = cached.pos;
            return cached.token;
        }
        const scan_result = self.scan(self.cursor, self.line) catch |err| {
            // Recovery: the reference lexer advances past the offending
            // lexeme, so later calls can keep tokenizing.
            self.cursor = self.err_cursor;
            self.line = self.err_line;
            self.last_pos = .{ .line = self.err_line };
            return err;
        };
        self.cursor = scan_result.cursor;
        self.line = scan_result.line;
        self.last_pos = scan_result.pos;
        return scan_result.token;
    }

    const Scan = struct {
        token: tk.Token,
        cursor: usize,
        line: u32,
        pos: tk.TokenPosition,
    };

    fn result(token: tk.Token, cursor: usize, line: u32, pos: tk.TokenPosition) Scan {
        return .{ .token = token, .cursor = cursor, .line = line, .pos = pos };
    }

    fn fail(self: *Lexer, kind: ErrorKind, lexeme: []const u8, line: u32, cursor: usize) Error {
        self.err_kind = kind;
        self.err_lexeme = lexeme;
        self.err_line = line;
        self.err_cursor = cursor;
        return switch (kind) {
            .invalid_keyword => error.InvalidKeyword,
            .invalid_identifier => error.InvalidIdentifier,
            .invalid_number => error.InvalidNumber,
            .invalid_character => error.InvalidCharacter,
        };
    }

    inline fn scan(self: *Lexer, start_cursor: usize, start_line: u32) Error!Scan {
        var i = start_cursor;
        var line = start_line;

        // Skip whitespace and comments.
        while (i < self.source.len) {
            const c = self.source[i];
            if (c == ' ' or c == '\t' or c == '\r') {
                i += 1;
            } else if (c == '\n') {
                i += 1;
                line += 1;
            } else if (c == ';') {
                i = std.mem.indexOfScalarPos(u8, self.source, i + 1, '\n') orelse self.source.len;
            } else break;
        }

        const pos = tk.TokenPosition{ .line = line };
        if (i >= self.source.len) {
            return result(.eof, i, line, pos);
        }

        const c = self.source[i];
        switch (c) {
            '-' => return result(.{ .punctuator = .dash }, i + 1, line, pos),
            '(' => return result(.{ .punctuator = .lparen }, i + 1, line, pos),
            ')' => return result(.{ .punctuator = .rparen }, i + 1, line, pos),
            '<' => {
                if (i + 1 < self.source.len and self.source[i + 1] == '=') {
                    return result(.{ .operator = .less_than_or_equal }, i + 2, line, pos);
                }
                return result(.{ .operator = .less_than }, i + 1, line, pos);
            },
            '>' => {
                if (i + 1 < self.source.len and self.source[i + 1] == '=') {
                    return result(.{ .operator = .greater_than_or_equal }, i + 2, line, pos);
                }
                return result(.{ .operator = .greater_than }, i + 1, line, pos);
            },
            '=' => return result(.{ .operator = .equal }, i + 1, line, pos),
            '?' => return self.scanWord(i, line, pos),
            ':' => {
                // The colon itself is not part of the lexeme.
                const lexeme = self.scanLexeme(i + 1);
                if (lexeme.invalid) return self.fail(.invalid_keyword, lexeme.text, line, lexeme.end);
                if (keywordFromColon(lexeme.text)) |token| {
                    return result(token, lexeme.end, line, pos);
                }
                return self.fail(.invalid_keyword, lexeme.text, line, lexeme.end);
            },
            '0'...'9' => return self.scanNumber(i, line, pos),
            else => return self.scanWord(i, line, pos),
        }
    }

    /// Scan a bare word: either an identifier or one of the reserved words.
    inline fn scanWord(self: *Lexer, start: usize, line: u32, pos: tk.TokenPosition) Error!Scan {
        const lexeme = self.scanLexeme(start);
        if (lexeme.invalid) return self.fail(.invalid_identifier, lexeme.text, line, lexeme.end);
        if (wordToken(lexeme.text)) |token| {
            return result(token, lexeme.end, line, pos);
        }
        return result(.{ .identifier = lexeme.text }, lexeme.end, line, pos);
    }

    const Lexeme = struct {
        text: []const u8,
        end: usize,
        invalid: bool,
    };

    inline fn scanLexeme(self: *Lexer, start: usize) Lexeme {
        const source = self.source;
        var i = start;
        var invalid = false;

        if (i >= source.len) return .{ .text = source[start..i], .end = i, .invalid = false };

        // A lexeme starting with a delimiter is empty (e.g. `:` directly
        // followed by `(`). The reference lexer treats this as an empty
        // keyword rather than as an invalid character.
        const first = source[i];
        if (first == '(' or first == ')' or isWhitespace(first)) {
            return .{ .text = source[start..i], .end = i, .invalid = false };
        }

        // `?` is only valid as the first byte of a variable name.
        if (first != '?' and !isIdentifierBody(first)) invalid = true;
        i += 1;

        // Classify 16 bytes at a time. Most lexemes are shorter than the
        // vector width, so this loop usually runs exactly once and finds the
        // terminating delimiter.
        while (i + vector_len <= source.len) {
            const chunk: ByteVector = source[i..][0..vector_len].*;
            const delimiter_bits: u16 = @bitCast(isDelimiterVector(chunk));
            const invalid_bits: u16 = ~@as(u16, @bitCast(isIdentifierBodyVector(chunk)));

            if (delimiter_bits != 0) {
                const n = firstSetBit(delimiter_bits);
                if (invalid_bits & prefixMask(n) != 0) invalid = true;
                i += n;
                return .{ .text = source[start..i], .end = i, .invalid = invalid };
            }
            if (invalid_bits != 0) invalid = true;
            i += vector_len;
        }

        // Scalar tail (or tiny inputs).
        while (i < source.len) {
            const c = source[i];
            if (c == '(' or c == ')' or isWhitespace(c)) break;
            if (!isIdentifierBody(c)) invalid = true;
            i += 1;
        }
        return .{ .text = source[start..i], .end = i, .invalid = invalid };
    }

    fn scanNumber(self: *Lexer, start: usize, line: u32, pos: tk.TokenPosition) Error!Scan {
        var i = start;
        var seen_dot = false;
        while (i < self.source.len) {
            const c = self.source[i];
            if (std.ascii.isDigit(c)) {
                i += 1;
            } else if (c == '.' and !seen_dot) {
                seen_dot = true;
                i += 1;
            } else break;
        }

        const text = self.source[start..i];
        if (seen_dot) {
            const value = std.fmt.parseFloat(f64, text) catch
                return self.fail(.invalid_number, text, line, i);
            return result(.{ .number = .{ .real = value } }, i, line, pos);
        } else {
            const value = std.fmt.parseInt(i64, text, 10) catch
                return self.fail(.invalid_number, text, line, i);
            return result(.{ .number = .{ .integer = value } }, i, line, pos);
        }
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn isIdentifierBody(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Keywords and requirements that appear after a `:`.
const colon_tokens = std.StaticStringMap(tk.Token).initComptime(.{
    // Requirements.
    .{ "negative-preconditions", tk.Token{ .requirement = .negative_preconditions } },
    .{ "strips", tk.Token{ .requirement = .strips } },
    .{ "hierarchy", tk.Token{ .requirement = .hierarchy } },
    .{ "equality", tk.Token{ .requirement = .equality } },
    .{ "method-preconditions", tk.Token{ .requirement = .method_preconditions } },
    .{ "typing", tk.Token{ .requirement = .typing } },
    .{ "universal-preconditions", tk.Token{ .requirement = .universal_preconditions } },
    .{ "existential-preconditions", tk.Token{ .requirement = .existential_preconditions } },
    .{ "quantified-preconditions", tk.Token{ .requirement = .quantified_preconditions } },
    .{ "probabilistic-effects", tk.Token{ .requirement = .probabilistic_effects } },
    .{ "conditional-effects", tk.Token{ .requirement = .conditional_effects } },
    .{ "domain-axioms", tk.Token{ .requirement = .domain_axioms } },

    // Keywords.
    .{ "requirements", tk.Token{ .keyword = .requirements } },
    .{ "objects", tk.Token{ .keyword = .objects } },
    .{ "types", tk.Token{ .keyword = .types } },
    .{ "constants", tk.Token{ .keyword = .constants } },
    .{ "predicates", tk.Token{ .keyword = .predicates } },
    .{ "functions", tk.Token{ .keyword = .functions } },
    .{ "init", tk.Token{ .keyword = .init } },
    .{ "htn", tk.Token{ .keyword = .htn } },
    .{ "task", tk.Token{ .keyword = .task } },
    .{ "action", tk.Token{ .keyword = .action } },
    .{ "parameters", tk.Token{ .keyword = .parameters } },
    .{ "method", tk.Token{ .keyword = .method } },
    .{ "precondition", tk.Token{ .keyword = .precondition } },
    .{ "effect", tk.Token{ .keyword = .effect } },
    .{ "subtasks", tk.Token{ .keyword = .subtasks } },
    .{ "tasks", tk.Token{ .keyword = .subtasks } },
    .{ "ordered-subtasks", tk.Token{ .keyword = .ordered_subtasks } },
    .{ "ordered-tasks", tk.Token{ .keyword = .ordered_subtasks } },
    .{ "ordering", tk.Token{ .keyword = .ordering } },
    .{ "order", tk.Token{ .keyword = .ordering } },
    .{ "constraints", tk.Token{ .keyword = .constraints } },
    .{ "goal", tk.Token{ .keyword = .goal } },
    .{ "domain", tk.Token{ .keyword = .domain } },
    .{ "problem", tk.Token{ .keyword = .problem } },
});

/// Keywords and operators that appear as bare words.
///
/// A length switch beats a hash-map lookup here: the first test rejects
/// almost every identifier with a single compare, and the surviving cases
/// need at most three short `mem.eql` calls.
inline fn wordToken(lexeme: []const u8) ?tk.Token {
    switch (lexeme.len) {
        2 => {
            if (eql(lexeme, "or")) return .{ .operator = .logical_or };
        },
        3 => {
            if (eql(lexeme, "and")) return .{ .operator = .logical_and };
            if (eql(lexeme, "not")) return .{ .operator = .logical_not };
        },
        4 => {
            if (eql(lexeme, "when")) return .{ .operator = .imply };
        },
        5 => {
            if (eql(lexeme, "oneof")) return .{ .operator = .xor };
            if (eql(lexeme, "imply")) return .{ .operator = .imply };
        },
        6 => {
            if (eql(lexeme, "define")) return .{ .keyword = .define };
            if (eql(lexeme, "domain")) return .{ .keyword = .domain };
            if (eql(lexeme, "exists")) return .{ .operator = .exists };
            if (eql(lexeme, "forall")) return .{ .operator = .forall };
        },
        7 => {
            if (eql(lexeme, "problem")) return .{ .keyword = .problem };
        },
        13 => {
            if (eql(lexeme, "probabilistic")) return .{ .operator = .probabilistic };
        },
        else => {},
    }
    return null;
}

fn keywordFromColon(lexeme: []const u8) ?tk.Token {
    return colon_tokens.get(lexeme);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn collectTokens(allocator: std.mem.Allocator, source: []const u8) ![]tk.Token {
    var lexer = Lexer.init(source);
    var tokens = std.ArrayList(tk.Token).empty;
    while (true) {
        const token = try lexer.next();
        try tokens.append(allocator, token);
        if (token == .eof) break;
    }
    return tokens.toOwnedSlice(allocator);
}

test "lex a small domain header" {
    const source =
        \\(define (domain transport)
        \\  (:requirements :typing :hierarchy)
        \\)
    ;
    const tokens = try collectTokens(testing.allocator, source);
    defer testing.allocator.free(tokens);

    try testing.expect(tokens[0].isPunctuator(.lparen));
    try testing.expect(tokens[1].isKeyword(.define));
    try testing.expect(tokens[2].isPunctuator(.lparen));
    try testing.expect(tokens[3].isKeyword(.domain));
    try testing.expectEqualStrings("transport", tokens[4].identifier);
    try testing.expect(tokens[5].isPunctuator(.rparen));
    try testing.expect(tokens[6].isPunctuator(.lparen));
    try testing.expect(tokens[7].isKeyword(.requirements));
    try testing.expectEqual(tk.Requirement.typing, tokens[8].requirement);
    try testing.expectEqual(tk.Requirement.hierarchy, tokens[9].requirement);
    try testing.expect(tokens[10].isPunctuator(.rparen));
    try testing.expect(tokens[11].isPunctuator(.rparen));
    try testing.expectEqual(tk.Token.eof, tokens[12]);
}

test "comments and line positions" {
    var lexer = Lexer.init(
        \\; a comment
        \\(define
        \\  ; another comment
        \\  (domain d))
    );
    try testing.expect(try lexer.next() == .punctuator);
    try testing.expectEqual(@as(u32, 2), lexer.lastPosition().line);
    try testing.expect(try lexer.next() == .keyword);
    try testing.expectEqual(@as(u32, 2), lexer.lastPosition().line);
    try testing.expect(try lexer.next() == .punctuator);
    try testing.expectEqual(@as(u32, 4), lexer.lastPosition().line);
}

test "variables keep their question mark" {
    var lexer = Lexer.init("?object ?x1 ?with-dash");
    const first = try lexer.next();
    try testing.expectEqualStrings("?object", first.identifier);
    const second = try lexer.next();
    try testing.expectEqualStrings("?x1", second.identifier);
    const third = try lexer.next();
    try testing.expectEqualStrings("?with-dash", third.identifier);
}

test "numbers, operators and dashes" {
    var lexer = Lexer.init("42 3.5 <= >= < > = -");
    try testing.expectEqual(@as(i64, 42), (try lexer.next()).number.integer);
    try testing.expectEqual(@as(f64, 3.5), (try lexer.next()).number.real);
    try testing.expectEqual(tk.Operator.less_than_or_equal, (try lexer.next()).operator);
    try testing.expectEqual(tk.Operator.greater_than_or_equal, (try lexer.next()).operator);
    try testing.expectEqual(tk.Operator.less_than, (try lexer.next()).operator);
    try testing.expectEqual(tk.Operator.greater_than, (try lexer.next()).operator);
    try testing.expectEqual(tk.Operator.equal, (try lexer.next()).operator);
    try testing.expectEqual(tk.Punctuator.dash, (try lexer.next()).punctuator);
}

test "invalid keyword" {
    var lexer = Lexer.init(":nonsense");
    try testing.expectError(error.InvalidKeyword, lexer.next());
    try testing.expectEqualStrings("nonsense", lexer.err_lexeme);
}

test "reset rewinds the scanner" {
    var lexer = Lexer.init("(a b)");
    _ = try lexer.next();
    _ = try lexer.next();
    lexer.reset();
    try testing.expect((try lexer.next()).isPunctuator(.lparen));
}

test "peek is cached and does not consume" {
    var lexer = Lexer.init("(foo bar)");
    const first_peek = try lexer.peek();
    const second_peek = try lexer.peek();
    try testing.expectEqualDeep(first_peek, second_peek);
    try testing.expect(first_peek.isPunctuator(.lparen));

    const first_next = try lexer.next();
    try testing.expectEqualDeep(first_peek, first_next);
    try testing.expectEqualStrings("foo", (try lexer.next()).identifier);
}

test "long identifiers span vector-width chunks" {
    const long_name = "abcdefghij" ** 4;
    var lexer = Lexer.init(long_name ++ " next");
    try testing.expectEqualStrings(long_name, (try lexer.next()).identifier);
    try testing.expectEqualStrings("next", (try lexer.next()).identifier);
}

test "invalid bytes after a vector-width prefix" {
    const long_name = "a" ** 24;
    const bad = long_name ++ ".oops";
    var lexer = Lexer.init(bad);
    try testing.expectError(error.InvalidIdentifier, lexer.next());
    try testing.expectEqualStrings(bad, lexer.err_lexeme);
}

test "question mark is only valid at the start of a name" {
    var lexer = Lexer.init("a?b");
    try testing.expectError(error.InvalidIdentifier, lexer.next());
}
