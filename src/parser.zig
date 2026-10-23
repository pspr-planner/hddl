//! Recursive-descent parser for HDDL domains and problems.
//!
//! The grammar and error behavior follow the reference implementation
//! (https://github.com/koala-planner/HDDL-Parser). The parser produces an
//! `ast.Ast` whose strings point into a copy of the source owned by the
//! allocator handed to `Parser.init`.

const std = @import("std");
const tk = @import("token.zig");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

const Token = tk.Token;
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    line: u32,
    expected: []const u8,
    found_kind: []const u8,
    found_lexeme: ?[]const u8 = null,
    found_number: ?tk.Number = null,

    pub fn write(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("line {d}: expected {s}, found {s}", .{
            self.line,
            self.expected,
            self.found_kind,
        });
        if (self.found_lexeme) |lexeme| try w.print(" '{s}'", .{lexeme});
        if (self.found_number) |number| {
            try w.writeByte(' ');
            try number.write(w);
        }
    }
};

pub const Error = error{ OutOfMemory, ParseFailed };

/// Result of inspecting the first few tokens of a file.
pub const FileVariant = enum {
    domain,
    problem,
    maybe_not_hddl,
};

const ProblemDefinition = struct {
    problem_name: []const u8,
    domain_name: []const u8,
};

const Definition = union(enum) {
    domain: []const u8,
    problem: ProblemDefinition,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lexer: lexer_mod.Lexer,
    diagnostic: ?Diagnostic = null,

    /// Formulas are individually referenced from the tree. Allocate them in
    /// slabs so that a formula-heavy file does not perform one allocator call
    /// per node. All slabs come from `allocator` and live as long as the AST.
    formula_slab: [*]ast.Formula = undefined,
    formula_slab_len: usize = 0,
    formula_slab_used: usize = 0,

    /// Reusable scratch buffer for typed argument lists. Each list is copied
    /// out at its exact final size, so lists no longer pay for incremental
    /// growth and a shrinking `toOwnedSlice` remap.
    args_scratch: std.ArrayList(ast.Symbol) = .empty,
    terms_scratch: std.ArrayList(ast.Symbol) = .empty,
    formula_terms_scratch: std.ArrayList(*ast.Formula) = .empty,
    subtasks_scratch: std.ArrayList(ast.Subtask) = .empty,
    ordering_scratch: std.ArrayList(ast.Ordering) = .empty,
    constraints_scratch: std.ArrayList(ast.Constraint) = .empty,

    pub fn init(allocator: Allocator, source: []const u8) Allocator.Error!Parser {
        const copy = try allocator.dupe(u8, source);
        return .{
            .allocator = allocator,
            .source = copy,
            .lexer = lexer_mod.Lexer.init(copy),
        };
    }

    /// Initialize a parser that borrows `source` instead of copying it.
    ///
    /// All strings in the resulting AST point into `source`, so the caller
    /// must keep it alive and unchanged for at least as long as the AST. This
    /// is useful when the input already lives in the parse arena (for example
    /// after `readFileAlloc`), where it saves a full copy of the file.
    pub fn initBorrowed(allocator: Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .lexer = lexer_mod.Lexer.init(source),
        };
    }

    /// Inspect the file's opening tokens without consuming them, mirroring the
    /// reference parser's `classify`.
    pub fn classify(self: *Parser) FileVariant {
        self.lexer.reset();
        defer self.lexer.reset();

        var variant: FileVariant = .maybe_not_hddl;
        const first = self.lexer.next() catch return variant;
        if (!first.isPunctuator(.lparen)) return variant;
        const second = self.lexer.next() catch return variant;
        if (!second.isKeyword(.define)) return variant;
        const third = self.lexer.next() catch return variant;
        if (!third.isPunctuator(.lparen)) return variant;
        const fourth = self.lexer.next() catch return variant;
        switch (fourth) {
            .keyword => |keyword| switch (keyword) {
                .domain => variant = .domain,
                .problem => variant = .problem,
                else => {},
            },
            else => {},
        }
        return variant;
    }

    // -----------------------------------------------------------------------
    // Token helpers and diagnostics
    // -----------------------------------------------------------------------

    fn next(self: *Parser) Error!Token {
        return self.lexer.next() catch |err| return self.failLex(err);
    }

    fn peek(self: *Parser) Error!Token {
        return self.lexer.peek() catch |err| return self.failLex(err);
    }

    fn failLex(self: *Parser, err: lexer_mod.Error) Error {
        const kind: lexer_mod.ErrorKind = switch (err) {
            error.InvalidKeyword => .invalid_keyword,
            error.InvalidIdentifier => .invalid_identifier,
            error.InvalidNumber => .invalid_number,
            error.InvalidCharacter => .invalid_character,
        };
        self.diagnostic = .{
            .line = self.lexer.err_line,
            .expected = kind.text(),
            .found_kind = "input",
            .found_lexeme = self.lexer.err_lexeme,
        };
        return error.ParseFailed;
    }

    fn fail(self: *Parser, expected: []const u8, token: Token) Error {
        const description = token.describe();
        self.diagnostic = .{
            .line = self.lexer.lastPosition().line,
            .expected = expected,
            .found_kind = description.kind,
            .found_lexeme = description.lexeme,
            .found_number = description.number,
        };
        return error.ParseFailed;
    }

    fn expectPunctuator(self: *Parser, punct: tk.Punctuator, expected: []const u8) Error!void {
        const token = try self.next();
        switch (token) {
            .punctuator => |p| if (p != punct) return self.fail(expected, token),
            else => return self.fail(expected, token),
        }
    }

    fn expectKeyword(self: *Parser, keyword: tk.Keyword, expected: []const u8) Error!void {
        const token = try self.next();
        switch (token) {
            .keyword => |k| if (k != keyword) return self.fail(expected, token),
            else => return self.fail(expected, token),
        }
    }

    fn expectOperator(self: *Parser, operator: tk.Operator, expected: []const u8) Error!void {
        const token = try self.next();
        switch (token) {
            .operator => |o| if (o != operator) return self.fail(expected, token),
            else => return self.fail(expected, token),
        }
    }

    fn expectIdentifier(self: *Parser, expected: []const u8) Error![]const u8 {
        const token = try self.next();
        return switch (token) {
            .identifier => |name| name,
            else => self.fail(expected, token),
        };
    }

    fn box(self: *Parser, formula: ast.Formula) Error!*ast.Formula {
        if (self.formula_slab_used == self.formula_slab_len) {
            const slab = try self.allocator.alloc(ast.Formula, 128);
            self.formula_slab = slab.ptr;
            self.formula_slab_len = slab.len;
            self.formula_slab_used = 0;
        }
        const pointer = &self.formula_slab[self.formula_slab_used];
        self.formula_slab_used += 1;
        pointer.* = formula;
        return pointer;
    }

    /// Copy the scratch region `list.items[start..]` into an exact-size
    /// allocation and rewind the scratch buffer. Nested uses (e.g. recursive
    /// formulas) are supported because the scratch is used as a stack.
    fn takeScratch(
        self: *Parser,
        comptime T: type,
        list: *std.ArrayList(T),
        start: usize,
    ) Error![]T {
        const slice = try self.allocator.dupe(T, list.items[start..]);
        list.shrinkRetainingCapacity(start);
        return slice;
    }

    // -----------------------------------------------------------------------
    // Document entry points
    // -----------------------------------------------------------------------

    /// Parse a whole file (either a domain or a problem).
    pub fn parse(self: *Parser) Error!ast.Ast {
        const first = try self.next();
        if (!first.isPunctuator(.lparen)) {
            return self.fail("'(' at the start of the file", first);
        }
        const definition = try self.parseDocumentType();
        return switch (definition) {
            .domain => |name| .{ .domain = try self.parseDomainBody(name) },
            .problem => |metadata| .{ .problem = try self.parseProblemBody(metadata) },
        };
    }

    fn parseDocumentType(self: *Parser) Error!Definition {
        try self.expectKeyword(.define, "keyword 'define'");
        try self.expectPunctuator(.lparen, "'(' after keyword 'define'");

        const token = try self.next();
        switch (token) {
            .keyword => |keyword| switch (keyword) {
                .domain => return self.parseDomainHeader(),
                .problem => return self.parseProblemHeader(),
                else => return self.fail("either keyword 'domain' or 'problem'", token),
            },
            else => return self.fail("either keyword 'domain' or 'problem'", token),
        }
    }

    fn parseDomainHeader(self: *Parser) Error!Definition {
        const name = try self.expectIdentifier("domain name");
        try self.expectPunctuator(.rparen, "')'");
        return .{ .domain = name };
    }

    fn parseProblemHeader(self: *Parser) Error!Definition {
        const problem_name = try self.expectIdentifier("problem name");
        try self.expectPunctuator(.rparen, "')'");
        try self.expectPunctuator(.lparen, "'('");
        try self.expectKeyword(.domain, "keyword 'domain'");
        const domain_name = try self.expectIdentifier("domain name");
        try self.expectPunctuator(.rparen, "')'");
        return .{ .problem = .{
            .problem_name = problem_name,
            .domain_name = domain_name,
        } };
    }

    fn parseRequirementsInto(self: *Parser, requirements: *std.ArrayList(tk.Requirement)) Error!void {
        while (true) {
            const token = try self.next();
            switch (token) {
                .requirement => |requirement| try requirements.append(self.allocator, requirement),
                .punctuator => |punct| {
                    if (punct == .rparen) return;
                    return self.fail("either a requirement or ')'", token);
                },
                else => return self.fail("either a requirement or ')'", token),
            }
        }
    }

    // -----------------------------------------------------------------------
    // Domain
    // -----------------------------------------------------------------------

    fn parseDomainBody(self: *Parser, name: []const u8) Error!ast.Domain {
        var domain = ast.Domain{ .name = name };

        var types = std.ArrayList(ast.Symbol).empty;
        var has_types = false;
        var constants = std.ArrayList(ast.Symbol).empty;
        var has_constants = false;
        var requirements = std.ArrayList(tk.Requirement).empty;
        var predicates = std.ArrayList(ast.Predicate).empty;
        var compound_tasks = std.ArrayList(ast.Task).empty;
        var methods = std.ArrayList(ast.Method).empty;
        var actions = std.ArrayList(ast.Action).empty;
        var functions = std.ArrayList(ast.Function).empty;

        while (true) {
            const token = try self.next();
            switch (token) {
                .punctuator => |punct| switch (punct) {
                    .rparen => break,
                    .lparen => {},
                    .dash => return self.fail(
                        "either ')' to close the domain, or '(' to start defining new components",
                        token,
                    ),
                },
                else => return self.fail(
                    "either ')' to close the domain, or '(' to start defining new components",
                    token,
                ),
            }

            const component = try self.next();
            switch (component) {
                .keyword => |keyword| switch (keyword) {
                    .predicates => {
                        try predicates.ensureTotalCapacity(self.allocator, 16);
                        try self.parsePredicatesInto(&predicates);
                    },
                    .functions => {
                        try functions.ensureTotalCapacity(self.allocator, 8);
                        try self.parseFunctionsInto(&functions);
                    },
                    .task => {
                        try compound_tasks.ensureTotalCapacity(self.allocator, 8);
                        const task = try self.parseTask();
                        try self.expectPunctuator(.rparen, "')' after the task definition");
                        try compound_tasks.append(self.allocator, task);
                    },
                    .method => {
                        try methods.ensureTotalCapacity(self.allocator, 16);
                        try methods.append(self.allocator, try self.parseMethod());
                    },
                    .action => {
                        try actions.ensureTotalCapacity(self.allocator, 16);
                        try actions.append(self.allocator, try self.parseAction());
                    },
                    .requirements => {
                        try requirements.ensureTotalCapacity(self.allocator, 8);
                        try self.parseRequirementsInto(&requirements);
                    },
                    .types => {
                        try types.ensureTotalCapacity(self.allocator, 8);
                        try self.parseArgsInto(&types);
                        has_types = true;
                    },
                    .constants => {
                        try constants.ensureTotalCapacity(self.allocator, 8);
                        try self.parseArgsInto(&constants);
                        has_constants = true;
                    },
                    else => return self.fail("a keyword", component),
                },
                else => return self.fail("a keyword", component),
            }
        }

        domain.types = if (has_types) try types.toOwnedSlice(self.allocator) else null;
        domain.constants = if (has_constants) try constants.toOwnedSlice(self.allocator) else null;
        domain.requirements = try requirements.toOwnedSlice(self.allocator);
        domain.predicates = try predicates.toOwnedSlice(self.allocator);
        domain.compound_tasks = try compound_tasks.toOwnedSlice(self.allocator);
        domain.methods = try methods.toOwnedSlice(self.allocator);
        domain.actions = try actions.toOwnedSlice(self.allocator);
        domain.functions = try functions.toOwnedSlice(self.allocator);
        return domain;
    }

    /// Parse a typed list of symbols, e.g. `?x ?y - loc ?z`.
    fn parseArgs(self: *Parser) Error![]ast.Symbol {
        self.args_scratch.clearRetainingCapacity();
        try self.parseArgsInto(&self.args_scratch);
        return self.allocator.dupe(ast.Symbol, self.args_scratch.items);
    }

    /// Parse a typed list of symbols into an existing list.
    ///
    /// Symbols are appended directly to the result; when a `- type` suffix is
    /// seen, the type is written over the trailing run of untyped symbols.
    /// This avoids the temporary "pending" list of the naive implementation.
    fn parseArgsInto(self: *Parser, result: *std.ArrayList(ast.Symbol)) Error!void {
        var untyped_start = result.items.len;
        var token = try self.next();
        while (true) {
            while (token == .identifier) {
                try result.append(self.allocator, .{
                    .name = token.identifier,
                    .name_pos = self.lexer.lastPosition(),
                });
                token = try self.next();
            }

            switch (token) {
                .punctuator => |punct| switch (punct) {
                    .dash => {
                        const type_token = try self.next();
                        const type_name = switch (type_token) {
                            .identifier => |name| name,
                            else => return self.fail("the type of the objects", type_token),
                        };
                        const type_pos = self.lexer.lastPosition();
                        for (result.items[untyped_start..]) |*symbol| {
                            symbol.symbol_type = type_name;
                            symbol.type_pos = type_pos;
                        }
                        untyped_start = result.items.len;
                        token = try self.next();
                    },
                    .rparen => return,
                    .lparen => return self.fail("an identifier", token),
                },
                else => return self.fail("an identifier", token),
            }
        }
    }

    fn parsePredicatesInto(self: *Parser, predicates: *std.ArrayList(ast.Predicate)) Error!void {
        while (true) {
            const token = try self.next();
            switch (token) {
                .punctuator => |punct| {
                    if (punct == .rparen) return;
                    if (punct != .lparen) return self.fail("a predicate definition", token);
                },
                else => return self.fail("a predicate definition", token),
            }
            try predicates.append(self.allocator, try self.parsePredicateDefinition());
        }
    }

    fn parsePredicateDefinition(self: *Parser) Error!ast.Predicate {
        const name = try self.expectIdentifier("a predicate name");
        const name_pos = self.lexer.lastPosition();
        return .{
            .name = name,
            .name_pos = name_pos,
            .variables = try self.parseArgs(),
        };
    }

    fn parseFunctionsInto(self: *Parser, functions: *std.ArrayList(ast.Function)) Error!void {
        while (true) {
            const token = try self.next();
            switch (token) {
                .punctuator => |punct| {
                    if (punct == .rparen) return;
                    if (punct != .lparen) return self.fail("a function definition", token);
                },
                else => return self.fail("a function definition", token),
            }
            const name = try self.expectIdentifier("a function name");
            const name_pos = self.lexer.lastPosition();
            try functions.append(self.allocator, .{
                .name = name,
                .name_pos = name_pos,
                .variables = try self.parseArgs(),
            });
        }
    }

    fn parseTask(self: *Parser) Error!ast.Task {
        const name = try self.expectIdentifier("a task/action name (identifier)");
        const name_pos = self.lexer.lastPosition();
        try self.expectKeyword(.parameters, "keyword :parameters");
        try self.expectPunctuator(.lparen, "'(' after keyword :parameters");
        return .{
            .name = name,
            .name_pos = name_pos,
            .parameters = try self.parseArgs(),
        };
    }

    fn parseAction(self: *Parser) Error!ast.Action {
        const task = try self.parseTask();
        var preconditions: ?ast.Formula = null;
        var effects: ?ast.Formula = null;

        const after_parameters = try self.peek();
        switch (after_parameters) {
            .keyword => |keyword| switch (keyword) {
                .precondition => {
                    _ = try self.next();
                    preconditions = try self.parseFormula();
                },
                // The action has no precondition.
                .effect => {},
                else => return self.fail("the (potentially empty) preconditions of the action", after_parameters),
            },
            .punctuator => |punct| {
                if (punct != .rparen) {
                    return self.fail("the (potentially empty) preconditions of the action", after_parameters);
                }
            },
            else => return self.fail("the (potentially empty) preconditions of the action", after_parameters),
        }

        const after_preconditions = try self.peek();
        switch (after_preconditions) {
            .keyword => |keyword| {
                if (keyword != .effect) {
                    return self.fail("the (potentially empty) effects of the action", after_preconditions);
                }
                _ = try self.next();
                effects = try self.parseFormula();
            },
            .punctuator => |punct| {
                // The action has no effects.
                if (punct != .rparen) {
                    return self.fail("the (potentially empty) effects of the action", after_preconditions);
                }
            },
            else => return self.fail("the (potentially empty) effects of the action", after_preconditions),
        }

        try self.expectPunctuator(.rparen, "')' closing the scope of the action");
        return .{
            .name = task.name,
            .name_pos = task.name_pos,
            .parameters = task.parameters,
            .preconditions = preconditions,
            .effects = effects,
        };
    }

    fn parseMethod(self: *Parser) Error!ast.Method {
        const method_name = try self.expectIdentifier("method name");
        const name = ast.Symbol{
            .name = method_name,
            .name_pos = self.lexer.lastPosition(),
        };

        try self.expectKeyword(.parameters, "the parameters of the method");
        try self.expectPunctuator(.lparen, "'(' after keyword :parameters");
        const params = try self.parseArgs();

        try self.expectKeyword(.task, "keyword :task");
        try self.expectPunctuator(.lparen, "'(' after keyword :task");
        const task_name = try self.expectIdentifier("the task that the method decomposes");
        const task = ast.Symbol{
            .name = task_name,
            .name_pos = self.lexer.lastPosition(),
        };
        const task_terms = try self.parseArgs();

        const next_token = try self.peek();
        switch (next_token) {
            .keyword => |keyword| switch (keyword) {
                .precondition => {
                    _ = try self.next();
                    const precondition = try self.parseFormula();
                    const tn = try self.parseHtn();
                    return .{
                        .name = name,
                        .task = task,
                        .task_terms = task_terms,
                        .params = params,
                        .precondition = precondition,
                        .tn = tn,
                    };
                },
                .subtasks, .ordered_subtasks => {
                    const tn = try self.parseHtn();
                    return .{
                        .name = name,
                        .task = task,
                        .task_terms = task_terms,
                        .params = params,
                        .precondition = null,
                        .tn = tn,
                    };
                },
                else => return self.fail("either preconditions or a decomposition for the method", next_token),
            },
            else => return self.fail("either preconditions or a decomposition for the method", next_token),
        }
    }

    // -----------------------------------------------------------------------
    // Formulas
    // -----------------------------------------------------------------------

    fn parseFormula(self: *Parser) Error!ast.Formula {
        const token = try self.next();
        switch (token) {
            .punctuator => |punct| switch (punct) {
                .rparen => return .empty,
                .lparen => {},
                .dash => return self.fail("a (potentially empty) boolean formula", token),
            },
            else => return self.fail("a (potentially empty) boolean formula", token),
        }

        const head = try self.next();
        switch (head) {
            .operator => |operator| switch (operator) {
                .logical_not => {
                    const inner = try self.parseFormula();
                    try self.expectPunctuator(.rparen, "closing the not operator with ')'");
                    return .{ .not = try self.box(inner) };
                },
                .logical_and => return self.parseNaryFormula(.and_),
                .logical_or => return self.parseNaryFormula(.or_),
                .xor => return self.parseNaryFormula(.xor),
                .equal => {
                    const lhs = try self.expectIdentifier("left hand side of the equality");
                    const rhs = try self.expectIdentifier("right hand side of the equality");
                    try self.expectPunctuator(.rparen, "the equality's closing parenthesis");
                    return .{ .equals = .{ .lhs = lhs, .rhs = rhs } };
                },
                .imply => {
                    const lhs = try self.parseFormula();
                    const rhs = try self.parseFormula();
                    try self.expectPunctuator(.rparen, "')' to close the implication");
                    return .{ .imply = .{
                        .lhs = try self.box(lhs),
                        .rhs = try self.box(rhs),
                    } };
                },
                .forall => {
                    try self.expectPunctuator(.lparen, "'(' after forall keyword");
                    const vars = try self.parseArgs();
                    const body = try self.parseFormula();
                    try self.expectPunctuator(.rparen, "')' to close the forall statement");
                    return .{ .forall = .{
                        .vars = vars,
                        .body = try self.box(body),
                    } };
                },
                .exists => {
                    try self.expectPunctuator(.lparen, "'(' after the existential keyword");
                    const vars = try self.parseArgs();
                    const body = try self.parseFormula();
                    try self.expectPunctuator(.rparen, "')' to close the existential statement");
                    return .{ .exists = .{
                        .vars = vars,
                        .body = try self.box(body),
                    } };
                },
                .probabilistic => {
                    const start = self.formula_terms_scratch.items.len;
                    while (true) {
                        const branch_token = try self.next();
                        switch (branch_token) {
                            .punctuator => |punct| {
                                if (punct == .rparen) {
                                    return .{ .and_ = try self.takeScratch(
                                        *ast.Formula,
                                        &self.formula_terms_scratch,
                                        start,
                                    ) };
                                }
                                return self.fail("a probability or ')' to close the probabilistic block", branch_token);
                            },
                            .number => |probability| {
                                const value: f64 = switch (probability) {
                                    .integer => |integer| @floatFromInt(integer),
                                    .real => |real| real,
                                };
                                if (value < 0.0 or value > 1.0) {
                                    return self.fail("a probability in [0, 1]", branch_token);
                                }
                                const inner = try self.parseFormula();
                                if (inner == .empty) {
                                    return self.fail(
                                        "a formula following the probability",
                                        .{ .punctuator = .rparen },
                                    );
                                }
                                const branch = ast.Formula{ .probabilistic = .{
                                    .probability = probability,
                                    .formula = try self.box(inner),
                                } };
                                try self.formula_terms_scratch.append(
                                    self.allocator,
                                    try self.box(branch),
                                );
                            },
                            else => return self.fail(
                                "a probability or ')' to close the probabilistic block",
                                branch_token,
                            ),
                        }
                    }
                },
                .less_than,
                .greater_than,
                .less_than_or_equal,
                .greater_than_or_equal,
                => return self.fail("a boolean formula", head),
            },
            .identifier => |name| {
                const name_pos = self.lexer.lastPosition();
                return .{ .atom = .{
                    .name = name,
                    .name_pos = name_pos,
                    .variables = try self.parseArgs(),
                } };
            },
            .punctuator => |punct| {
                if (punct == .rparen) return .empty;
                return self.fail("a boolean formula", head);
            },
            else => return self.fail("a boolean formula", head),
        }
    }

    /// Parse the tail of `(and ...)`, `(or ...)` or `(oneof ...)`.
    fn parseNaryFormula(self: *Parser, comptime kind: enum { and_, or_, xor }) Error!ast.Formula {
        const start = self.formula_terms_scratch.items.len;
        while (true) {
            const term = try self.parseFormula();
            if (term == .empty) {
                const slice = try self.takeScratch(*ast.Formula, &self.formula_terms_scratch, start);
                return switch (kind) {
                    .and_ => .{ .and_ = slice },
                    .or_ => .{ .or_ = slice },
                    .xor => .{ .xor = slice },
                };
            }
            try self.formula_terms_scratch.append(self.allocator, try self.box(term));
        }
    }

    // -----------------------------------------------------------------------
    // Task networks
    // -----------------------------------------------------------------------

    fn parseInitialTn(self: *Parser) Error!ast.InitialTaskNetwork {
        const token = try self.peek();
        switch (token) {
            .keyword => |keyword| switch (keyword) {
                .parameters => {
                    _ = try self.next();
                    try self.expectPunctuator(.lparen, "'(' after keyword :parameters");
                    const parameters = try self.parseArgs();
                    return .{
                        .parameters = parameters,
                        .tn = try self.parseHtn(),
                    };
                },
                .subtasks, .ordered_subtasks => return .{ .tn = try self.parseHtn() },
                else => return self.fail("the definition of the initial task network", token),
            },
            .punctuator => |punct| {
                // Empty initial task network.
                if (punct == .rparen) return .{};
                return self.fail("the definition of the initial task network", token);
            },
            else => return self.fail("the definition of the initial task network", token),
        }
    }

    fn parseHtn(self: *Parser) Error!ast.HTN {
        const lookahead = try self.peek();
        switch (lookahead) {
            .punctuator => |punct| {
                if (punct == .rparen) return .{};
            },
            else => {},
        }

        const token = try self.next();
        switch (token) {
            .keyword => |keyword| switch (keyword) {
                .subtasks => {
                    const subtasks = try self.parseSubtasks();
                    const ordering_start = self.ordering_scratch.items.len;
                    var ordering_pos: ?tk.TokenPosition = null;
                    var constraints: ?[]ast.Constraint = null;

                    while (true) {
                        const next_token = try self.next();
                        switch (next_token) {
                            .keyword => |inner| switch (inner) {
                                .ordering => {
                                    ordering_pos = self.lexer.lastPosition();
                                    try self.expectPunctuator(.lparen, "'('");
                                    const shape = try self.next();
                                    switch (shape) {
                                        .operator => |operator| switch (operator) {
                                            .logical_and => {
                                                while (true) {
                                                    const item = try self.next();
                                                    switch (item) {
                                                        .punctuator => |punct| {
                                                            if (punct == .rparen) break;
                                                            if (punct != .lparen) {
                                                                return self.fail("'('", item);
                                                            }
                                                            try self.parseOrderingIntoScratch();
                                                        },
                                                        else => return self.fail("'('", item),
                                                    }
                                                }
                                            },
                                            .less_than => {
                                                const first_id = try self.expectIdentifier("a task identifier");
                                                while (true) {
                                                    const item = try self.next();
                                                    switch (item) {
                                                        .identifier => |second_id| {
                                                            try self.ordering_scratch.append(self.allocator, .{
                                                                .before = first_id,
                                                                .after = second_id,
                                                            });
                                                        },
                                                        .punctuator => |punct| {
                                                            if (punct == .rparen) break;
                                                            return self.fail(
                                                                "another task id after the first",
                                                                item,
                                                            );
                                                        },
                                                        else => return self.fail(
                                                            "another task id after the first",
                                                            item,
                                                        ),
                                                    }
                                                }
                                            },
                                            else => return self.fail("ordering constraints", shape),
                                        },
                                        .punctuator => |punct| {
                                            // No ordering constraints.
                                            if (punct != .rparen) {
                                                return self.fail("ordering constraints", shape);
                                            }
                                        },
                                        else => return self.fail("ordering constraints", shape),
                                    }
                                },
                                .constraints => constraints = try self.parseConstraints(),
                                else => return self.fail(
                                    "the (potentially empty) ordering constraints of the task network",
                                    next_token,
                                ),
                            },
                            .punctuator => |punct| {
                                if (punct == .rparen) {
                                    return .{
                                        .subtasks = subtasks,
                                        .ordering_pos = ordering_pos,
                                        .orderings = .{ .partial = try self.takeScratch(
                                            ast.Ordering,
                                            &self.ordering_scratch,
                                            ordering_start,
                                        ) },
                                        .constraints = constraints,
                                    };
                                }
                                return self.fail(
                                    "the (potentially empty) ordering constraints of the task network",
                                    next_token,
                                );
                            },
                            else => return self.fail(
                                "the (potentially empty) ordering constraints of the task network",
                                next_token,
                            ),
                        }
                    }
                },
                .ordered_subtasks => {
                    const subtasks = try self.parseSubtasks();
                    var constraints: ?[]ast.Constraint = null;

                    const next_token = try self.next();
                    switch (next_token) {
                        .keyword => |inner| {
                            if (inner != .constraints) {
                                return self.fail("closing ')' after task network definition", next_token);
                            }
                            constraints = try self.parseConstraints();
                        },
                        .punctuator => |punct| {
                            if (punct != .rparen) {
                                return self.fail("closing ')' after task network definition", next_token);
                            }
                        },
                        else => return self.fail("closing ')' after task network definition", next_token),
                    }

                    return .{
                        .subtasks = subtasks,
                        .orderings = .total,
                        .constraints = constraints,
                    };
                },
                else => return self.fail(":subtasks or :ordered-subtasks keyword", token),
            },
            else => return self.fail(":subtasks or :ordered-subtasks keyword", token),
        }
    }

    /// Parse `< a b c` and append the resulting orderings to the ordering
    /// scratch buffer. The caller copies the whole network's orderings out at
    /// once, so no per-group allocation is needed.
    fn parseOrderingIntoScratch(self: *Parser) Error!void {
        try self.expectOperator(.less_than, "character '<' to start an ordering constraint");
        const first_id = try self.expectIdentifier("a task identifier");
        while (true) {
            const token = try self.next();
            switch (token) {
                .identifier => |second_id| {
                    try self.ordering_scratch.append(self.allocator, .{
                        .before = first_id,
                        .after = second_id,
                    });
                },
                .punctuator => |punct| {
                    if (punct == .rparen) return;
                    return self.fail("the task ids that come after the first", token);
                },
                else => return self.fail("the task ids that come after the first", token),
            }
        }
    }

    fn parseSubtasks(self: *Parser) Error![]ast.Subtask {
        try self.expectPunctuator(.lparen, "'('");

        const start = self.subtasks_scratch.items.len;
        const lookahead = try self.peek();
        switch (lookahead) {
            .operator => |operator| {
                if (operator != .logical_and) {
                    return self.fail("subtask declarations", lookahead);
                }
                _ = try self.next(); // consume 'and'
                while (true) {
                    const token = try self.next();
                    switch (token) {
                        .punctuator => |punct| {
                            if (punct == .rparen) {
                                return self.takeScratch(ast.Subtask, &self.subtasks_scratch, start);
                            }
                            if (punct != .lparen) {
                                return self.fail("subtask declarations", token);
                            }
                            try self.subtasks_scratch.append(self.allocator, try self.parseSubtask());
                        },
                        else => return self.fail("subtask declarations", token),
                    }
                }
            },
            // One subtask.
            .identifier => {
                try self.subtasks_scratch.append(self.allocator, try self.parseSubtask());
                return self.takeScratch(ast.Subtask, &self.subtasks_scratch, start);
            },
            // No subtasks.
            .punctuator => |punct| {
                if (punct == .rparen) {
                    _ = try self.next();
                    return &.{};
                }
                return self.fail("subtask declarations", lookahead);
            },
            else => return self.fail("subtask declarations", lookahead),
        }
    }

    fn parseSubtask(self: *Parser) Error!ast.Subtask {
        const id_name = try self.expectIdentifier("task id");
        const id_symbol = ast.Symbol{
            .name = id_name,
            .name_pos = self.lexer.lastPosition(),
        };

        const token = try self.next();
        switch (token) {
            .punctuator => |punct| switch (punct) {
                .lparen => {
                    const task_name = try self.expectIdentifier("a subtask name");
                    const task_symbol = ast.Symbol{
                        .name = task_name,
                        .name_pos = self.lexer.lastPosition(),
                    };
                    const start = self.terms_scratch.items.len;
                    while (true) {
                        const term_token = try self.next();
                        switch (term_token) {
                            .identifier => |term| try self.terms_scratch.append(self.allocator, .{
                                .name = term,
                                .name_pos = self.lexer.lastPosition(),
                            }),
                            .punctuator => |inner| {
                                if (inner == .rparen) {
                                    try self.expectPunctuator(
                                        .rparen,
                                        "')' to close the subtask block",
                                    );
                                    return .{
                                        .id = id_symbol,
                                        .task = task_symbol,
                                        .terms = try self.takeScratch(
                                            ast.Symbol,
                                            &self.terms_scratch,
                                            start,
                                        ),
                                    };
                                }
                                return self.fail("either a ')' or an identifier", term_token);
                            },
                            else => return self.fail("either a ')' or an identifier", term_token),
                        }
                    }
                },
                .rparen => return .{
                    .id = null,
                    .task = id_symbol,
                    .terms = &.{},
                },
                .dash => return self.fail("subtask definition", token),
            },
            .identifier => |term| {
                const start = self.terms_scratch.items.len;
                try self.terms_scratch.append(self.allocator, .{
                    .name = term,
                    .name_pos = self.lexer.lastPosition(),
                });
                while (true) {
                    const term_token = try self.next();
                    switch (term_token) {
                        .identifier => |next_term| try self.terms_scratch.append(self.allocator, .{
                            .name = next_term,
                            .name_pos = self.lexer.lastPosition(),
                        }),
                        .punctuator => |punct| {
                            if (punct == .rparen) {
                                return .{
                                    .id = null,
                                    .task = id_symbol,
                                    .terms = try self.takeScratch(
                                        ast.Symbol,
                                        &self.terms_scratch,
                                        start,
                                    ),
                                };
                            }
                            return self.fail("either a term or ')'", term_token);
                        },
                        else => return self.fail("either a term or ')'", term_token),
                    }
                }
            },
            else => return self.fail("subtask definition", token),
        }
    }

    fn parseConstraints(self: *Parser) Error![]ast.Constraint {
        try self.expectPunctuator(.lparen, "'('");

        const start = self.constraints_scratch.items.len;
        const lookahead = try self.peek();
        switch (lookahead) {
            .punctuator => |punct| {
                if (punct == .rparen) {
                    _ = try self.next();
                    return self.takeScratch(ast.Constraint, &self.constraints_scratch, start);
                }
                return self.fail("constraint declarations", lookahead);
            },
            .operator => |operator| switch (operator) {
                .logical_and => {
                    _ = try self.next(); // consume 'and'
                    while (true) {
                        const token = try self.next();
                        switch (token) {
                            .punctuator => |punct| {
                                if (punct == .rparen) {
                                    return self.takeScratch(
                                        ast.Constraint,
                                        &self.constraints_scratch,
                                        start,
                                    );
                                }
                                if (punct != .lparen) {
                                    return self.fail("a constraint definition", token);
                                }
                                try self.constraints_scratch.append(
                                    self.allocator,
                                    try self.parseConstraint(),
                                );
                            },
                            else => return self.fail("a constraint definition", token),
                        }
                    }
                },
                .logical_not, .equal => {
                    try self.constraints_scratch.append(self.allocator, try self.parseConstraint());
                    return self.takeScratch(ast.Constraint, &self.constraints_scratch, start);
                },
                else => return self.fail("constraint declarations", lookahead),
            },
            else => return self.fail("constraint declarations", lookahead),
        }
    }

    fn parseConstraint(self: *Parser) Error!ast.Constraint {
        const token = try self.next();
        switch (token) {
            .operator => |operator| switch (operator) {
                .logical_not => {
                    try self.expectPunctuator(.lparen, "'(' after keyword 'not'");
                    try self.expectOperator(.equal, "equality keyword '='");
                    const lhs = try self.expectIdentifier("a task identifier");
                    const rhs = try self.expectIdentifier("the right hand side of the inequality");
                    try self.expectPunctuator(.rparen, "')' to close the inequality constraint");
                    try self.expectPunctuator(.rparen, "')' to close the inequality constraint");
                    return .{ .not_equal = .{ .lhs = lhs, .rhs = rhs } };
                },
                .equal => {
                    const lhs = try self.expectIdentifier("a task identifier");
                    const rhs = try self.expectIdentifier("the right hand side of the equality");
                    try self.expectPunctuator(.rparen, "')' to close the equality constraint");
                    return .{ .equal = .{ .lhs = lhs, .rhs = rhs } };
                },
                else => return self.fail("either an equality or non-equality constraint", token),
            },
            else => return self.fail("either an equality or non-equality constraint", token),
        }
    }

    // -----------------------------------------------------------------------
    // Problem
    // -----------------------------------------------------------------------

    fn parseProblemBody(self: *Parser, metadata: ProblemDefinition) Error!ast.Problem {
        var problem = ast.Problem{
            .name = metadata.problem_name,
            .domain_name = metadata.domain_name,
        };

        var requirements = std.ArrayList(tk.Requirement).empty;
        var objects = std.ArrayList(ast.Symbol).empty;
        var init_state = std.ArrayList(ast.Predicate).empty;

        while (true) {
            const token = try self.next();
            switch (token) {
                .punctuator => |punct| {
                    if (punct == .rparen) break;
                    if (punct != .lparen) {
                        return self.fail("'(' or ')'", token);
                    }
                },
                .eof => break,
                else => return self.fail("'(' or ')'", token),
            }

            const component = try self.next();
            switch (component) {
                .keyword => |keyword| switch (keyword) {
                    .requirements => {
                        try requirements.ensureTotalCapacity(self.allocator, 8);
                        try self.parseRequirementsInto(&requirements);
                    },
                    .objects => {
                        try objects.ensureTotalCapacity(self.allocator, 16);
                        try self.parseArgsInto(&objects);
                    },
                    .htn => problem.init_tn = try self.parseInitialTn(),
                    .goal => problem.goal = try self.parseFormula(),
                    .init => {
                        try init_state.ensureTotalCapacity(self.allocator, 16);
                        try self.parsePredicatesInto(&init_state);
                    },
                    else => return self.fail("a keyword for block definition", component),
                },
                else => return self.fail("a keyword for block definition", component),
            }
        }

        problem.requirements = try requirements.toOwnedSlice(self.allocator);
        problem.objects = try objects.toOwnedSlice(self.allocator);
        problem.init_state = try init_state.toOwnedSlice(self.allocator);
        return problem;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const transport_domain =
    \\(define (domain transport)
    \\  (:requirements :typing :hierarchy :negative-preconditions :method-preconditions)
    \\  (:types
    \\    locatable - object
    \\    pkg vehicle - locatable
    \\    loc - object)
    \\  (:constants depot - loc)
    \\  (:predicates
    \\    (at ?p - pkg ?l - loc)
    \\    (road ?l1 - loc ?l2 - loc)
    \\    (in ?p - pkg ?v - vehicle))
    \\  (:functions (fuel ?v - vehicle) (capacity ?v - vehicle))
    \\  (:task deliver :parameters (?p - pkg ?l - loc))
    \\  (:method m_deliver
    \\    :parameters (?p - pkg ?from - loc ?to - loc ?v - vehicle)
    \\    :task (deliver ?p ?to)
    \\    :precondition (and (at ?p ?from) (not (in ?p ?v)))
    \\    :ordered-subtasks (and (load ?p ?from ?v) (drive ?from ?to ?v) (unload ?p ?to ?v)))
    \\  (:action drive
    \\    :parameters (?v - vehicle ?from - loc ?to - loc)
    \\    :precondition (and (road ?from ?to) (not (= ?from ?to)))
    \\    :effect (and (not (road ?from ?to)) (road ?to ?from)))
    \\)
;

const transport_problem =
    \\(define (problem p1) (:domain transport)
    \\  (:requirements :typing)
    \\  (:objects p1 p2 - pkg l1 l2 - loc truck - vehicle)
    \\  (:htn
    \\    :parameters (?p - pkg)
    \\    :subtasks (and (t1 (deliver ?p l2)) (t2 (deliver p1 l1)) (t3 (deliver p2 l2)))
    \\    :ordering (and (< t1 t2) (< t2 t3))
    \\    :constraints (and (= t1 t2) (not (= t2 t3))))
    \\  (:init (at p1 l1) (road l1 l2))
    \\  (:goal (and (at p1 l2) (forall (?x - pkg) (exists (?y - loc) (at ?x ?y))))))
    \\)
;

fn parseWithArena(arena: *std.heap.ArenaAllocator, source: []const u8) !ast.Ast {
    var parser = try Parser.init(arena.allocator(), source);
    return parser.parse();
}

test "parse domain structure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseWithArena(&arena, transport_domain);
    const domain = parsed.domain;

    try testing.expectEqualStrings("transport", domain.name);

    // Requirements.
    try testing.expectEqual(@as(usize, 4), domain.requirements.len);
    try testing.expectEqual(tk.Requirement.typing, domain.requirements[0]);
    try testing.expectEqual(tk.Requirement.hierarchy, domain.requirements[1]);
    try testing.expectEqual(tk.Requirement.negative_preconditions, domain.requirements[2]);
    try testing.expectEqual(tk.Requirement.method_preconditions, domain.requirements[3]);

    // Types: `locatable - object`, `pkg vehicle - locatable`, `loc - object`.
    const types = domain.types.?;
    try testing.expectEqual(@as(usize, 4), types.len);
    try testing.expectEqualStrings("locatable", types[0].name);
    try testing.expectEqualStrings("object", types[0].symbol_type.?);
    try testing.expectEqualStrings("pkg", types[1].name);
    try testing.expectEqualStrings("locatable", types[1].symbol_type.?);
    try testing.expectEqualStrings("vehicle", types[2].name);
    try testing.expectEqualStrings("loc", types[3].name);
    try testing.expectEqualStrings("object", types[3].symbol_type.?);
    // `pkg` and `vehicle` share the type position.
    try testing.expectEqual(types[1].type_pos.?.line, types[2].type_pos.?.line);

    // Constants.
    const constants = domain.constants.?;
    try testing.expectEqual(@as(usize, 1), constants.len);
    try testing.expectEqualStrings("depot", constants[0].name);
    try testing.expectEqualStrings("loc", constants[0].symbol_type.?);

    // Predicates and functions.
    try testing.expectEqual(@as(usize, 3), domain.predicates.len);
    try testing.expectEqualStrings("at", domain.predicates[0].name);
    try testing.expectEqual(@as(usize, 2), domain.predicates[0].arity());
    try testing.expectEqualStrings("?p", domain.predicates[0].variables[0].name);
    try testing.expectEqual(@as(usize, 2), domain.functions.len);
    try testing.expectEqualStrings("fuel", domain.functions[0].name);

    // Compound tasks.
    try testing.expectEqual(@as(usize, 1), domain.compound_tasks.len);
    try testing.expectEqualStrings("deliver", domain.compound_tasks[0].name);
    try testing.expectEqual(@as(usize, 2), domain.compound_tasks[0].parameters.len);

    // Methods.
    try testing.expectEqual(@as(usize, 1), domain.methods.len);
    const method = domain.methods[0];
    try testing.expectEqualStrings("m_deliver", method.name.name);
    try testing.expectEqualStrings("deliver", method.task.name);
    try testing.expectEqual(@as(usize, 2), method.task_terms.len);
    try testing.expectEqual(@as(usize, 4), method.params.len);
    try testing.expect(method.precondition != null);
    try testing.expect(method.precondition.? == .and_);
    try testing.expectEqual(@as(usize, 2), method.precondition.?.and_.len);
    try testing.expect(method.precondition.?.and_[1].* == .not);
    try testing.expectEqual(ast.TaskOrdering.total, method.tn.orderings);
    try testing.expectEqual(@as(usize, 3), method.tn.subtasks.len);
    try testing.expectEqualStrings("load", method.tn.subtasks[0].task.name);
    // `(load ?p ?from ?v)` has no explicit subtask id; `(t1 (deliver ...))`
    // in a problem does.
    try testing.expect(method.tn.subtasks[0].id == null);

    // Actions.
    try testing.expectEqual(@as(usize, 1), domain.actions.len);
    const action = domain.actions[0];
    try testing.expectEqualStrings("drive", action.name);
    try testing.expectEqual(@as(usize, 3), action.parameters.len);
    try testing.expect(action.preconditions != null);
    try testing.expect(action.effects != null);
    try testing.expect(action.preconditions.?.and_[1].* == .not);
    try testing.expect(action.preconditions.?.and_[1].not.* == .equals);
    try testing.expectEqualStrings("?from", action.preconditions.?.and_[1].not.equals.lhs);

    // Every symbol carries a line number from the source.
    try testing.expect(types[0].name_pos.line > 0);
}

test "parse problem structure" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseWithArena(&arena, transport_problem);
    const problem = parsed.problem;

    try testing.expectEqualStrings("p1", problem.name);
    try testing.expectEqualStrings("transport", problem.domain_name);
    try testing.expectEqual(@as(usize, 1), problem.requirements.len);
    try testing.expectEqual(@as(usize, 5), problem.objects.len);
    try testing.expectEqualStrings("truck", problem.objects[4].name);
    try testing.expectEqualStrings("vehicle", problem.objects[4].symbol_type.?);

    // Initial task network.
    const init_tn = problem.init_tn.?;
    try testing.expectEqual(@as(usize, 1), init_tn.parameters.?.len);
    try testing.expectEqual(@as(usize, 3), init_tn.tn.subtasks.len);
    try testing.expectEqualStrings("t1", init_tn.tn.subtasks[0].id.?.name);
    try testing.expectEqualStrings("deliver", init_tn.tn.subtasks[0].task.name);

    // Partial order.
    const orderings = init_tn.tn.orderings.partial;
    try testing.expectEqual(@as(usize, 2), orderings.len);
    try testing.expectEqualStrings("t1", orderings[0].before);
    try testing.expectEqualStrings("t2", orderings[0].after);

    // Constraints: `(= t1 t2)` and `(not (= t2 t3))`.
    const constraints = init_tn.tn.constraints.?;
    try testing.expectEqual(@as(usize, 2), constraints.len);
    try testing.expectEqualStrings("t1", constraints[0].equal.lhs);
    try testing.expectEqualStrings("t2", constraints[1].not_equal.lhs);

    // Initial state and goal.
    try testing.expectEqual(@as(usize, 2), problem.init_state.len);
    try testing.expectEqualStrings("at", problem.init_state[0].name);
    const goal = problem.goal.?;
    try testing.expect(goal == .and_);
    try testing.expect(goal.and_[1].* == .forall);
    try testing.expect(goal.and_[1].forall.body.* == .exists);
}

test "parse all formula connectives" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem formulas) (:domain d)
        \\  (:init)
        \\  (:goal (and
        \\    (at a b)
        \\    (not (at a b))
        \\    (or (p) (q))
        \\    (oneof (p) (q) (r))
        \\    (imply (p) (q))
        \\    (exists (?x - t) (p ?x))
        \\    (forall (?x - t) (or (p ?x) (q ?x)))
        \\    (= a a)
        \\    (probabilistic 0.5 (p)) (probabilistic 1 (q)))))
        \\)
    ;
    const parsed = try parseWithArena(&arena, source);
    const goal = parsed.problem.goal.?;
    try testing.expectEqual(@as(usize, 10), goal.and_.len);

    const or_formula = goal.and_[2].*;
    try testing.expect(or_formula == .or_);
    try testing.expectEqual(@as(usize, 2), or_formula.or_.len);

    const oneof = goal.and_[3].*;
    try testing.expect(oneof == .xor);
    try testing.expectEqual(@as(usize, 3), oneof.xor.len);

    const implication = goal.and_[4].*;
    try testing.expect(implication == .imply);

    const existential = goal.and_[5].*;
    try testing.expect(existential == .exists);
    try testing.expectEqual(@as(usize, 1), existential.exists.vars.len);

    const universal = goal.and_[6].*;
    try testing.expect(universal == .forall);
    try testing.expectEqual(@as(usize, 1), universal.forall.vars.len);

    try testing.expect(goal.and_[7].* == .equals);

    // Probabilistic branches are represented as a conjunction of branches.
    const probabilistic = goal.and_[8].*;
    try testing.expect(probabilistic == .and_);
    try testing.expectEqual(@as(usize, 1), probabilistic.and_.len);
    try testing.expect(probabilistic.and_[0].* == .probabilistic);

    const second_probabilistic = goal.and_[9].*;
    try testing.expect(second_probabilistic == .and_);
    try testing.expect(second_probabilistic.and_[0].* == .probabilistic);
}

test "parse empty task network and empty blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem empty) (:domain d)
        \\  (:objects)
        \\  (:htn)
        \\  (:init)
        \\)
    ;
    const problem = (try parseWithArena(&arena, source)).problem;
    try testing.expectEqual(@as(usize, 0), problem.objects.len);
    try testing.expectEqual(@as(usize, 0), problem.init_state.len);
    const init_tn = problem.init_tn.?;
    try testing.expectEqual(@as(usize, 0), init_tn.tn.subtasks.len);
    try testing.expect(init_tn.tn.orderings == .partial);
    try testing.expectEqual(@as(usize, 0), init_tn.tn.orderings.partial.len);
}

test "render and reparse are stable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try parseWithArena(&arena, transport_domain);
    var first_buffer: std.Io.Writer.Allocating = .init(allocator);
    try first.domain.write(&first_buffer.writer);
    const first_rendering = first_buffer.writer.buffered();

    var parser = try Parser.init(allocator, first_rendering);
    const reparsed = try parser.parse();
    var second_buffer: std.Io.Writer.Allocating = .init(allocator);
    try reparsed.domain.write(&second_buffer.writer);
    const second_rendering = second_buffer.writer.buffered();

    try testing.expectEqualStrings(first_rendering, second_rendering);

    // And the rendered problem parses back to the same rendering.
    const problem_ast = try parseWithArena(&arena, transport_problem);
    var problem_buffer: std.Io.Writer.Allocating = .init(allocator);
    try problem_ast.problem.write(&problem_buffer.writer);
    const problem_rendering = problem_buffer.writer.buffered();

    var problem_parser = try Parser.init(allocator, problem_rendering);
    const reparsed_problem = try problem_parser.parse();
    var problem_buffer2: std.Io.Writer.Allocating = .init(allocator);
    try reparsed_problem.problem.write(&problem_buffer2.writer);
    try testing.expectEqualStrings(problem_rendering, problem_buffer2.writer.buffered());
}

test "report a syntax error with a position" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var parser = try Parser.init(arena.allocator(),
        \\(define (domain broken)
        \\  (:predicates (at ?x))
        \\  (:action move :parameters (?x) :effect (at ?x) :precondition (at ?x))
        \\)
    );
    try testing.expectError(error.ParseFailed, parser.parse());
    const diagnostic = parser.diagnostic.?;
    try testing.expectEqual(@as(u32, 3), diagnostic.line);
    try testing.expectEqualStrings("keyword", diagnostic.found_kind);
    try testing.expectEqualStrings(":precondition", diagnostic.found_lexeme.?);
}

test "report an invalid keyword lexically" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var parser = try Parser.init(arena.allocator(), "(define (domain d) (:nonsense))");
    try testing.expectError(error.ParseFailed, parser.parse());
    const diagnostic = parser.diagnostic.?;
    try testing.expectEqualStrings("a valid keyword or requirement", diagnostic.expected);
    try testing.expectEqualStrings("nonsense", diagnostic.found_lexeme.?);
}
