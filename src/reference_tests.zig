//! Port of the parse-level tests from the reference HDDL parser
//! (https://github.com/koala-planner/HDDL-Parser, PolyForm Noncommercial
//! License 1.0.0; see test_data/LICENSE.HDDL-Parser.txt).
//!
//! The reference test suite mixes parsing with semantic verification,
//! transpilation, and formula transformations. This file ports the lexer,
//! syntax, flawed-domain, and IPC integration tests that exercise parsing.
//! Semantic-only tests are represented by asserting that the corresponding
//! domain still parses, since semantic analysis is not part of this package.

const std = @import("std");
const tk = @import("token.zig");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

const Lexer = lexer_mod.Lexer;
const Parser = parser_mod.Parser;
const testing = std.testing;

fn parseAst(arena: *std.heap.ArenaAllocator, source: []const u8) !ast.Ast {
    var parser = try Parser.init(arena.allocator(), source);
    return parser.parse();
}

fn parseDomain(arena: *std.heap.ArenaAllocator, source: []const u8) !ast.Domain {
    return switch (try parseAst(arena, source)) {
        .domain => |domain| domain,
        .problem => error.ExpectedDomain,
    };
}

fn parseProblem(arena: *std.heap.ArenaAllocator, source: []const u8) !ast.Problem {
    return switch (try parseAst(arena, source)) {
        .problem => |problem| problem,
        .domain => error.ExpectedProblem,
    };
}

fn parseFailure(arena: *std.heap.ArenaAllocator, source: []const u8) !parser_mod.Diagnostic {
    var parser = try Parser.init(arena.allocator(), source);
    try testing.expectError(error.ParseFailed, parser.parse());
    return parser.diagnostic.?;
}

fn expectToken(lexer: *Lexer, expected: tk.Token) !void {
    try testing.expectEqualDeep(expected, try lexer.next());
}

fn punctuation(p: tk.Punctuator) tk.Token {
    return .{ .punctuator = p };
}

fn keyword(k: tk.Keyword) tk.Token {
    return .{ .keyword = k };
}

fn operator(o: tk.Operator) tk.Token {
    return .{ .operator = o };
}

fn requirement(r: tk.Requirement) tk.Token {
    return .{ .requirement = r };
}

fn identifier(name: []const u8) tk.Token {
    return .{ .identifier = name };
}

// ---------------------------------------------------------------------------
// Lexical analyzer tests (src/lexical_analyzer/tests)
// ---------------------------------------------------------------------------

test "punctuation recognition" {
    var lexer = Lexer.init("-( \n) ");
    try expectToken(&lexer, punctuation(.dash));
    try expectToken(&lexer, punctuation(.lparen));
    try expectToken(&lexer, punctuation(.rparen));
    try expectToken(&lexer, .eof);
}

test "ordering relation recognition" {
    var lexer = Lexer.init("<=  \n> >= < \n");
    try expectToken(&lexer, operator(.less_than_or_equal));
    try expectToken(&lexer, operator(.greater_than));
    try expectToken(&lexer, operator(.greater_than_or_equal));
    try expectToken(&lexer, operator(.less_than));
    try expectToken(&lexer, .eof);
}

test "logical operator recognition" {
    var lexer = Lexer.init("and or oneof not exists forall imply\n");
    try expectToken(&lexer, operator(.logical_and));
    try expectToken(&lexer, operator(.logical_or));
    try expectToken(&lexer, operator(.xor));
    try expectToken(&lexer, operator(.logical_not));
    try expectToken(&lexer, operator(.exists));
    try expectToken(&lexer, operator(.forall));
    try expectToken(&lexer, operator(.imply));
    try expectToken(&lexer, .eof);
}

test "variable recognition" {
    var lexer = Lexer.init("?test_id ?pred-aa ");
    try expectToken(&lexer, identifier("?test_id"));
    try expectToken(&lexer, identifier("?pred-aa"));
}

test "keyword recognition" {
    var lexer = Lexer.init(
        "define domain problem :requirements :objects :types :constants " ++
            ":predicates :init :htn :action :parameters :method :precondition " ++
            ":effect :subtasks :tasks :ordered-tasks :ordered-subtasks :order " ++
            ":ordering :constraints",
    );
    try expectToken(&lexer, keyword(.define));
    try expectToken(&lexer, keyword(.domain));
    try expectToken(&lexer, keyword(.problem));
    try expectToken(&lexer, keyword(.requirements));
    try expectToken(&lexer, keyword(.objects));
    try expectToken(&lexer, keyword(.types));
    try expectToken(&lexer, keyword(.constants));
    try expectToken(&lexer, keyword(.predicates));
    try expectToken(&lexer, keyword(.init));
    try expectToken(&lexer, keyword(.htn));
    try expectToken(&lexer, keyword(.action));
    try expectToken(&lexer, keyword(.parameters));
    try expectToken(&lexer, keyword(.method));
    try expectToken(&lexer, keyword(.precondition));
    try expectToken(&lexer, keyword(.effect));
    try expectToken(&lexer, keyword(.subtasks));
    // `:tasks` is an alias of `:subtasks`.
    try expectToken(&lexer, keyword(.subtasks));
    try expectToken(&lexer, keyword(.ordered_subtasks));
    try expectToken(&lexer, keyword(.ordered_subtasks));
    // `:order` is an alias of `:ordering`.
    try expectToken(&lexer, keyword(.ordering));
    try expectToken(&lexer, keyword(.ordering));
    try expectToken(&lexer, keyword(.constraints));
}

test "number recognition" {
    var lexer = Lexer.init("123.54 42\n");
    try expectToken(&lexer, .{ .number = .{ .real = 123.54 } });
    try expectToken(&lexer, .{ .number = .{ .integer = 42 } });
}

test "identifier recognition" {
    var lexer = Lexer.init("var123 var_3123 te23 v\n");
    try expectToken(&lexer, identifier("var123"));
    try expectToken(&lexer, identifier("var_3123"));
    try expectToken(&lexer, identifier("te23"));
    try expectToken(&lexer, identifier("v"));
}

test "lookahead matches the following token" {
    var lexer = Lexer.init(
        "(:method vDC_to_vPC_2 " ++
            ":parameters (?d1 ?d2 - AbstractDevice ?t - SignalType ?p1 ?p2 - Port) " ++
            ":task (ValidateDeviceConnection ?d1 ?d2 ?t) " ++
            ":precondition (and " ++
            "(isPartOf ?p1 ?d1) " ++
            "(isPartOf ?p2 ?d2) " ++
            "(isPlugDirection ?p1 out) " ++
            "(isPlugDirection ?p2 both) " ++
            "(isSignalSource ?p1 ?t) " ++
            "(isSignalDestination ?p2 ?t) " ++
            ") " ++
            ":subtasks (and (ValidatePortConnection ?p1 ?p2 ?t)) " ++
            ") ",
    );
    while (true) {
        const looked_ahead = try lexer.peek();
        const actual = try lexer.next();
        if (actual == .eof) break;
        try testing.expectEqualDeep(looked_ahead, actual);
    }
}

test "variable name errors" {
    {
        var lexer = Lexer.init("\n\n?ca<sd ");
        try testing.expectError(error.InvalidIdentifier, lexer.next());
        try testing.expectEqual(lexer_mod.ErrorKind.invalid_identifier, lexer.err_kind);
        try testing.expectEqual(@as(u32, 3), lexer.err_line);
        try testing.expectEqualStrings("?ca<sd", lexer.err_lexeme);
    }
    {
        var lexer = Lexer.init("\n\n?rt/asd \n\n\n\n ?f*ta \t %x954s ? ");
        try testing.expectError(error.InvalidIdentifier, lexer.next());
        try testing.expectEqual(lexer_mod.ErrorKind.invalid_identifier, lexer.err_kind);
        try testing.expectEqual(@as(u32, 3), lexer.err_line);
        try testing.expectEqualStrings("?rt/asd", lexer.err_lexeme);
    }
    {
        var lexer = Lexer.init("\n\n\n\n\n\n ?f*ta \t %x954s ? ");
        try testing.expectError(error.InvalidIdentifier, lexer.next());
        try testing.expectEqual(lexer_mod.ErrorKind.invalid_identifier, lexer.err_kind);
        try testing.expectEqual(@as(u32, 7), lexer.err_line);
        try testing.expectEqualStrings("?f*ta", lexer.err_lexeme);
    }
    {
        var lexer = Lexer.init("\n\n\n\n\n\n \t %x954s ? ");
        try testing.expectError(error.InvalidIdentifier, lexer.next());
        try testing.expectEqual(lexer_mod.ErrorKind.invalid_identifier, lexer.err_kind);
        try testing.expectEqual(@as(u32, 7), lexer.err_line);
        try testing.expectEqualStrings("%x954s", lexer.err_lexeme);
    }
}

test "keyword errors" {
    var lexer = Lexer.init("\n\n:cra :pred \n\n\n\n :defne ");
    try testing.expectError(error.InvalidKeyword, lexer.next());
    try testing.expectEqual(lexer_mod.ErrorKind.invalid_keyword, lexer.err_kind);
    try testing.expectEqual(@as(u32, 3), lexer.err_line);
    try testing.expectEqualStrings("cra", lexer.err_lexeme);

    try testing.expectError(error.InvalidKeyword, lexer.next());
    try testing.expectEqual(lexer_mod.ErrorKind.invalid_keyword, lexer.err_kind);
    try testing.expectEqual(@as(u32, 3), lexer.err_line);
    try testing.expectEqualStrings("pred", lexer.err_lexeme);

    try testing.expectError(error.InvalidKeyword, lexer.next());
    try testing.expectEqual(lexer_mod.ErrorKind.invalid_keyword, lexer.err_kind);
    try testing.expectEqual(@as(u32, 7), lexer.err_line);
    try testing.expectEqualStrings("defne", lexer.err_lexeme);
}

// ---------------------------------------------------------------------------
// Syntax analyzer tests (src/syntactic_analyzer/tests/syntax_tests.rs)
// ---------------------------------------------------------------------------

test "objects list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\                (:objects a
        \\                b c
        \\                - d
        \\                s - f t)
        \\              )
    ;
    const problem = try parseProblem(&arena, source);
    try testing.expectEqual(@as(usize, 5), problem.objects.len);

    try testing.expectEqualStrings("a", problem.objects[0].name);
    try testing.expectEqual(@as(u32, 2), problem.objects[0].name_pos.line);
    try testing.expectEqualStrings("d", problem.objects[0].symbol_type.?);
    try testing.expectEqual(@as(u32, 4), problem.objects[0].type_pos.?.line);

    try testing.expectEqualStrings("b", problem.objects[1].name);
    try testing.expectEqual(@as(u32, 3), problem.objects[1].name_pos.line);
    try testing.expectEqualStrings("d", problem.objects[1].symbol_type.?);

    try testing.expectEqualStrings("c", problem.objects[2].name);
    try testing.expectEqual(@as(u32, 3), problem.objects[2].name_pos.line);
    try testing.expectEqualStrings("d", problem.objects[2].symbol_type.?);

    try testing.expectEqualStrings("s", problem.objects[3].name);
    try testing.expectEqual(@as(u32, 5), problem.objects[3].name_pos.line);
    try testing.expectEqualStrings("f", problem.objects[3].symbol_type.?);
    try testing.expectEqual(@as(u32, 5), problem.objects[3].type_pos.?.line);

    try testing.expectEqualStrings("t", problem.objects[4].name);
    try testing.expectEqual(@as(u32, 5), problem.objects[4].name_pos.line);
    try testing.expect(problem.objects[4].symbol_type == null);
    try testing.expect(problem.objects[4].type_pos == null);
}

test "untyped objects list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define
        \\            (problem p1) (domain bal)
        \\            (:objects a b
        \\            c) )
    ;
    const problem = try parseProblem(&arena, source);
    try testing.expectEqual(@as(usize, 3), problem.objects.len);
    try testing.expectEqualStrings("a", problem.objects[0].name);
    try testing.expectEqual(@as(u32, 3), problem.objects[0].name_pos.line);
    try testing.expectEqualStrings("b", problem.objects[1].name);
    try testing.expectEqual(@as(u32, 3), problem.objects[1].name_pos.line);
    try testing.expectEqualStrings("c", problem.objects[2].name);
    try testing.expectEqual(@as(u32, 4), problem.objects[2].name_pos.line);
}

test "requirements parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\                (:requirements :hierarchy :method-preconditions :typing :negative-preconditions)
        \\
        \\             )
    ;
    const problem = try parseProblem(&arena, source);
    try testing.expectEqual(@as(usize, 4), problem.requirements.len);
    try testing.expectEqual(tk.Requirement.hierarchy, problem.requirements[0]);
    try testing.expectEqual(tk.Requirement.method_preconditions, problem.requirements[1]);
    try testing.expectEqual(tk.Requirement.typing, problem.requirements[2]);
    try testing.expectEqual(tk.Requirement.negative_preconditions, problem.requirements[3]);
}

test "predicate parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:predicates
        \\                    (pred_1 ?a_1 ?a_2 - t_1 ?a_3 - t_2)
        \\                    (pred_2)
        \\                    (pred_3 a_1 a_2)
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 3), domain.predicates.len);

    const pred_1 = domain.predicates[0];
    try testing.expectEqualStrings("pred_1", pred_1.name);
    try testing.expectEqual(@as(usize, 3), pred_1.variables.len);
    try testing.expectEqualStrings("?a_1", pred_1.variables[0].name);
    try testing.expectEqualStrings("t_1", pred_1.variables[0].symbol_type.?);
    try testing.expectEqualStrings("?a_2", pred_1.variables[1].name);
    try testing.expectEqualStrings("t_1", pred_1.variables[1].symbol_type.?);
    try testing.expectEqualStrings("?a_3", pred_1.variables[2].name);
    try testing.expectEqualStrings("t_2", pred_1.variables[2].symbol_type.?);
    try testing.expectEqual(@as(u32, 3), pred_1.name_pos.line);

    const pred_2 = domain.predicates[1];
    try testing.expectEqualStrings("pred_2", pred_2.name);
    try testing.expectEqual(@as(usize, 0), pred_2.variables.len);
    try testing.expectEqual(@as(u32, 4), pred_2.name_pos.line);

    const pred_3 = domain.predicates[2];
    try testing.expectEqualStrings("pred_3", pred_3.name);
    try testing.expectEqual(@as(u32, 5), pred_3.name_pos.line);
    try testing.expectEqualStrings("a_1", pred_3.variables[0].name);
    try testing.expect(pred_3.variables[0].symbol_type == null);
    try testing.expectEqualStrings("a_2", pred_3.variables[1].name);
}

test "method parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:method m_1
        \\                    :parameters (?p1 - p ?l1 ?l2 ?l3 - loc)
        \\                    :task (deliver_abs ?p1 ?l1 ?l2)
        \\                    :subtasks (and
        \\                        (pickup ?p1 ?l1)
        \\                        (deliver_abs ?p1 ?l2 ?l3)
        \\                    )
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.methods.len);
    const method = domain.methods[0];

    try testing.expectEqualStrings("m_1", method.name.name);
    try testing.expectEqual(@as(u32, 2), method.name.name_pos.line);
    try testing.expectEqualStrings("deliver_abs", method.task.name);
    try testing.expectEqual(@as(u32, 4), method.task.name_pos.line);
    try testing.expectEqual(@as(usize, 3), method.task_terms.len);
    try testing.expectEqualStrings("?p1", method.task_terms[0].name);
    try testing.expectEqualStrings("?l1", method.task_terms[1].name);
    try testing.expectEqualStrings("?l2", method.task_terms[2].name);

    try testing.expectEqualStrings("pickup", method.tn.subtasks[0].task.name);
    try testing.expectEqual(@as(u32, 6), method.tn.subtasks[0].task.name_pos.line);
    try testing.expectEqual(@as(u32, 6), method.tn.subtasks[0].terms[0].name_pos.line);
    try testing.expectEqual(@as(u32, 6), method.tn.subtasks[0].terms[1].name_pos.line);
    try testing.expectEqualStrings("?p1", method.tn.subtasks[0].terms[0].name);
    try testing.expectEqualStrings("?l1", method.tn.subtasks[0].terms[1].name);

    try testing.expectEqualStrings("deliver_abs", method.tn.subtasks[1].task.name);
    try testing.expectEqual(@as(u32, 7), method.tn.subtasks[1].task.name_pos.line);
    try testing.expectEqual(@as(u32, 7), method.tn.subtasks[1].terms[0].name_pos.line);
    try testing.expectEqual(@as(u32, 7), method.tn.subtasks[1].terms[1].name_pos.line);
    try testing.expectEqual(@as(u32, 7), method.tn.subtasks[1].terms[2].name_pos.line);
    try testing.expectEqualStrings("?p1", method.tn.subtasks[1].terms[0].name);
    try testing.expectEqualStrings("?l2", method.tn.subtasks[1].terms[1].name);
    try testing.expectEqualStrings("?l3", method.tn.subtasks[1].terms[2].name);

    try testing.expect(method.precondition == null);
}

test "method precondition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:method m_1
        \\                    :parameters (?p1 - p ?l1 ?l2 ?l3 - loc)
        \\                    :task (deliver_abs ?p1 ?l1 ?l2)
        \\                    :precondition (and (at ?p1 ?l3)
        \\                    (driver ?l1) (not (= ?l1 ?l2)))
        \\                    :subtasks (and
        \\                        (pickup ?p1 ?l1)
        \\                        (deliver_abs ?p1 ?l2 ?l3)
        \\                    )
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    const method = domain.methods[0];
    try testing.expectEqualStrings("m_1", method.name.name);
    try testing.expectEqualStrings("deliver_abs", method.task.name);
    try testing.expectEqual(@as(usize, 3), method.task_terms.len);
    try testing.expectEqualStrings("pickup", method.tn.subtasks[0].task.name);
    try testing.expectEqualStrings("?p1", method.tn.subtasks[1].terms[0].name);
    try testing.expectEqualStrings("?l2", method.tn.subtasks[1].terms[1].name);
    try testing.expectEqualStrings("?l3", method.tn.subtasks[1].terms[2].name);

    const precondition = method.precondition.?;
    try testing.expect(precondition == .and_);
    try testing.expectEqual(@as(usize, 3), precondition.and_.len);

    try testing.expect(precondition.and_[0].* == .atom);
    try testing.expectEqualStrings("at", precondition.and_[0].atom.name);
    try testing.expectEqual(@as(u32, 5), precondition.and_[0].atom.name_pos.line);
    try testing.expectEqual(@as(usize, 2), precondition.and_[0].atom.variables.len);

    try testing.expect(precondition.and_[1].* == .atom);
    try testing.expectEqualStrings("driver", precondition.and_[1].atom.name);
    try testing.expectEqual(@as(u32, 6), precondition.and_[1].atom.name_pos.line);
    try testing.expectEqual(@as(usize, 1), precondition.and_[1].atom.variables.len);

    try testing.expect(precondition.and_[2].* == .not);
    try testing.expect(precondition.and_[2].not.* == .equals);
    try testing.expectEqualStrings("?l1", precondition.and_[2].not.equals.lhs);
    try testing.expectEqualStrings("?l2", precondition.and_[2].not.equals.rhs);
}

test "universal quantification" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:method m_1
        \\                    :parameters (?p1 - p ?l1 ?l2 ?l3 - loc)
        \\                    :task (deliver_abs ?p1 ?l1 ?l2)
        \\                    :precondition (forall (?l1 ?l2 - loc) (= ?l1 ?l2))
        \\                    :subtasks (and
        \\                        (pickup ?p1 ?l1)
        \\                        (deliver_abs ?p1 ?l2 ?l3)
        \\                    )
        \\                )
        \\             )
    ;
    const method = (try parseDomain(&arena, source)).methods[0];
    try testing.expectEqualStrings("m_1", method.name.name);
    try testing.expectEqualStrings("deliver_abs", method.task.name);
    try testing.expectEqual(@as(usize, 3), method.task_terms.len);

    const precondition = method.precondition.?;
    try testing.expect(precondition == .forall);
    try testing.expectEqual(@as(usize, 2), precondition.forall.vars.len);
    try testing.expectEqualStrings("?l1", precondition.forall.vars[0].name);
    try testing.expectEqualStrings("loc", precondition.forall.vars[0].symbol_type.?);
    try testing.expectEqualStrings("?l2", precondition.forall.vars[1].name);
    try testing.expectEqualStrings("loc", precondition.forall.vars[1].symbol_type.?);
    try testing.expect(precondition.forall.body.* == .equals);
    try testing.expectEqualStrings("?l1", precondition.forall.body.equals.lhs);
    try testing.expectEqualStrings("?l2", precondition.forall.body.equals.rhs);
}

test "init state parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\             (:init
        \\                (pred1 arg1 arg2)
        \\                (pred2 arg1 arg2 arg3)
        \\            )
    ;
    const problem = try parseProblem(&arena, source);
    try testing.expectEqual(@as(usize, 2), problem.init_state.len);

    const pred1 = problem.init_state[0];
    try testing.expectEqualStrings("pred1", pred1.name);
    try testing.expectEqual(@as(usize, 2), pred1.variables.len);
    try testing.expectEqualStrings("arg1", pred1.variables[0].name);
    try testing.expectEqualStrings("arg2", pred1.variables[1].name);

    const pred2 = problem.init_state[1];
    try testing.expectEqualStrings("pred2", pred2.name);
    try testing.expectEqual(@as(usize, 3), pred2.variables.len);
    try testing.expectEqualStrings("arg1", pred2.variables[0].name);
    try testing.expectEqualStrings("arg2", pred2.variables[1].name);
    try testing.expectEqualStrings("arg3", pred2.variables[2].name);
}

test "initial task network parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\             (:htn
        \\                :parameters (?d)
        \\                :subtasks (and
        \\                    (task0 (deliver package_0
        \\                            city_loc_0))
        \\                    (task1 (retrieve package_1
        \\                            city_loc_2 truck3))
        \\                )
        \\                :ordering (and
        \\                    (< task0 task1)
        \\                )
        \\                :constraints (not (= term1 term2))
        \\            )
    ;
    const problem = try parseProblem(&arena, source);
    const init_tn = problem.init_tn.?;

    const parameters = init_tn.parameters.?;
    try testing.expectEqual(@as(usize, 1), parameters.len);
    try testing.expectEqualStrings("?d", parameters[0].name);
    try testing.expect(parameters[0].symbol_type == null);

    const orderings = init_tn.tn.orderings.partial;
    try testing.expectEqual(@as(usize, 1), orderings.len);
    try testing.expectEqualStrings("task0", orderings[0].before);
    try testing.expectEqualStrings("task1", orderings[0].after);

    try testing.expectEqual(@as(usize, 2), init_tn.tn.subtasks.len);

    const task0 = init_tn.tn.subtasks[0];
    try testing.expectEqualStrings("task0", task0.id.?.name);
    try testing.expectEqualStrings("deliver", task0.task.name);
    try testing.expectEqual(@as(usize, 2), task0.terms.len);
    try testing.expectEqual(@as(u32, 5), task0.id.?.name_pos.line);
    try testing.expectEqual(@as(u32, 5), task0.terms[0].name_pos.line);
    try testing.expectEqual(@as(u32, 6), task0.terms[1].name_pos.line);
    try testing.expectEqualStrings("package_0", task0.terms[0].name);
    try testing.expectEqualStrings("city_loc_0", task0.terms[1].name);

    const task1 = init_tn.tn.subtasks[1];
    try testing.expectEqualStrings("task1", task1.id.?.name);
    try testing.expectEqualStrings("retrieve", task1.task.name);
    try testing.expectEqual(@as(usize, 3), task1.terms.len);
    try testing.expectEqual(@as(u32, 7), task1.id.?.name_pos.line);
    try testing.expectEqual(@as(u32, 7), task1.terms[0].name_pos.line);
    try testing.expectEqual(@as(u32, 8), task1.terms[1].name_pos.line);
    try testing.expectEqual(@as(u32, 8), task1.terms[2].name_pos.line);
    try testing.expectEqualStrings("package_1", task1.terms[0].name);
    try testing.expectEqualStrings("city_loc_2", task1.terms[1].name);
    try testing.expectEqualStrings("truck3", task1.terms[2].name);

    const constraints = init_tn.tn.constraints.?;
    try testing.expectEqual(@as(usize, 1), constraints.len);
    try testing.expectEqualStrings("term1", constraints[0].not_equal.lhs);
    try testing.expectEqualStrings("term2", constraints[0].not_equal.rhs);
}

test "no-op action" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a1
        \\                    :parameters (?p1 - p ?l1 ?l2 ?l3 - loc)
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.actions.len);
    try testing.expect(domain.actions[0].preconditions == null);
    try testing.expect(domain.actions[0].effects == null);
}

test "totally ordered initial task network" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\             (:htn
        \\                :ordered-tasks (and
        \\                    (deliver package_0 city_loc_0)
        \\                    (retrieve package_1 city_loc_2 truck3)
        \\                )
        \\            )
    ;
    const init_tn = (try parseProblem(&arena, source)).init_tn.?;
    try testing.expect(init_tn.parameters == null);
    try testing.expect(init_tn.tn.orderings == .total);
    try testing.expectEqual(@as(usize, 2), init_tn.tn.subtasks.len);

    try testing.expect(init_tn.tn.subtasks[0].id == null);
    try testing.expectEqualStrings("deliver", init_tn.tn.subtasks[0].task.name);
    try testing.expectEqual(@as(usize, 2), init_tn.tn.subtasks[0].terms.len);
    try testing.expectEqualStrings("package_0", init_tn.tn.subtasks[0].terms[0].name);
    try testing.expectEqualStrings("city_loc_0", init_tn.tn.subtasks[0].terms[1].name);

    try testing.expect(init_tn.tn.subtasks[1].id == null);
    try testing.expectEqualStrings("retrieve", init_tn.tn.subtasks[1].task.name);
    try testing.expectEqual(@as(usize, 3), init_tn.tn.subtasks[1].terms.len);
    try testing.expectEqualStrings("package_1", init_tn.tn.subtasks[1].terms[0].name);
    try testing.expectEqualStrings("city_loc_2", init_tn.tn.subtasks[1].terms[1].name);
    try testing.expectEqualStrings("truck3", init_tn.tn.subtasks[1].terms[2].name);
}

test "compound task parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:predicates )
        \\                (:task c_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.compound_tasks.len);

    const c_1 = domain.compound_tasks[0];
    try testing.expectEqualStrings("c_1", c_1.name);
    try testing.expectEqual(@as(u32, 3), c_1.name_pos.line);
    try testing.expectEqual(@as(usize, 3), c_1.parameters.len);
    try testing.expectEqualStrings("p_1", c_1.parameters[0].name);
    try testing.expectEqualStrings("p_2", c_1.parameters[1].name);
    try testing.expectEqualStrings("p_3", c_1.parameters[2].name);
    try testing.expectEqualStrings("t1", c_1.parameters[0].symbol_type.?);
    try testing.expectEqualStrings("t1", c_1.parameters[1].symbol_type.?);
    try testing.expectEqualStrings("t2", c_1.parameters[2].symbol_type.?);
    try testing.expectEqual(@as(u32, 4), c_1.parameters[0].type_pos.?.line);
}

test "action parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                 :precondition (not (at p_1))
        \\                 :effect (and (not (hold p_2 p_3))
        \\                 (at p_2))
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.actions.len);
    const action = domain.actions[0];
    try testing.expectEqualStrings("a_1", action.name);
    try testing.expectEqual(@as(usize, 3), action.parameters.len);
    try testing.expectEqualStrings("p_1", action.parameters[0].name);
    try testing.expectEqualStrings("p_2", action.parameters[1].name);
    try testing.expectEqualStrings("p_3", action.parameters[2].name);
    try testing.expectEqualStrings("t1", action.parameters[0].symbol_type.?);
    try testing.expectEqualStrings("t1", action.parameters[1].symbol_type.?);
    try testing.expectEqualStrings("t2", action.parameters[2].symbol_type.?);

    const preconditions = action.preconditions.?;
    try testing.expect(preconditions == .not);
    try testing.expect(preconditions.not.* == .atom);
    try testing.expectEqualStrings("at", preconditions.not.atom.name);
    try testing.expectEqual(@as(usize, 1), preconditions.not.atom.variables.len);
    try testing.expectEqualStrings("p_1", preconditions.not.atom.variables[0].name);

    const effects = action.effects.?;
    try testing.expect(effects == .and_);
    try testing.expectEqual(@as(usize, 2), effects.and_.len);
    try testing.expect(effects.and_[0].* == .not);
    try testing.expect(effects.and_[0].not.* == .atom);
    try testing.expectEqualStrings("hold", effects.and_[0].not.atom.name);
    try testing.expectEqual(@as(usize, 2), effects.and_[0].not.atom.variables.len);
    try testing.expectEqualStrings("p_2", effects.and_[0].not.atom.variables[0].name);
    try testing.expectEqualStrings("p_3", effects.and_[0].not.atom.variables[1].name);
    try testing.expect(effects.and_[1].* == .atom);
    try testing.expectEqualStrings("at", effects.and_[1].atom.name);
    try testing.expectEqual(@as(usize, 1), effects.and_[1].atom.variables.len);
    try testing.expectEqualStrings("p_2", effects.and_[1].atom.variables[0].name);
}

test "quantifier parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                 :precondition (and
        \\                    (not (at p_1))
        \\                    (exists (?num1 ?num2 - number) (smaller ?num1 ?num2))
        \\                 )
        \\                 :effect (and
        \\                    (not (hold p_2 p_3))
        \\                    (at p_2)
        \\                    (forall (?loc - s) (and (pred1 ?loc) (pred2 ?loc)))
        \\                 )
        \\                )
        \\             )
    ;
    const action = (try parseDomain(&arena, source)).actions[0];
    try testing.expectEqualStrings("a_1", action.name);

    const preconditions = action.preconditions.?;
    try testing.expect(preconditions == .and_);
    try testing.expectEqual(@as(usize, 2), preconditions.and_.len);
    try testing.expect(preconditions.and_[0].* == .not);
    try testing.expectEqualStrings("at", preconditions.and_[0].not.atom.name);
    try testing.expect(preconditions.and_[1].* == .exists);
    try testing.expectEqual(@as(usize, 2), preconditions.and_[1].exists.vars.len);
    try testing.expectEqualStrings("?num1", preconditions.and_[1].exists.vars[0].name);
    try testing.expectEqualStrings("?num2", preconditions.and_[1].exists.vars[1].name);
    {
        const predicates = try preconditions.and_[1].exists.body.*.getPropositionalPredicates(arena.allocator());
        try testing.expectEqual(@as(usize, 1), predicates.len);
    }

    const effects = action.effects.?;
    try testing.expect(effects == .and_);
    try testing.expectEqual(@as(usize, 3), effects.and_.len);
    try testing.expect(effects.and_[0].* == .not);
    try testing.expectEqualStrings("hold", effects.and_[0].not.atom.name);
    try testing.expect(effects.and_[1].* == .atom);
    try testing.expectEqualStrings("at", effects.and_[1].atom.name);
    try testing.expect(effects.and_[2].* == .forall);
    try testing.expectEqual(@as(usize, 1), effects.and_[2].forall.vars.len);
    try testing.expectEqualStrings("?loc", effects.and_[2].forall.vars[0].name);
    {
        const predicates = try effects.and_[2].forall.body.*.getPropositionalPredicates(arena.allocator());
        try testing.expectEqual(@as(usize, 2), predicates.len);
    }
}

test "non-deterministic action parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                 :precondition (at p1)
        \\                 :effect (oneof (not (hold p_2 p_3)) (at p_2))
        \\                )
        \\             )
    ;
    const action = (try parseDomain(&arena, source)).actions[0];
    try testing.expectEqualStrings("a_1", action.name);

    const effects = action.effects.?;
    try testing.expect(effects == .xor);
    try testing.expectEqual(@as(usize, 2), effects.xor.len);
    try testing.expect(effects.xor[0].* == .not);
    try testing.expectEqualStrings("hold", effects.xor[0].not.atom.name);
    try testing.expectEqual(@as(usize, 2), effects.xor[0].not.atom.variables.len);
    try testing.expectEqualStrings("p_2", effects.xor[0].not.atom.variables[0].name);
    try testing.expectEqualStrings("p_3", effects.xor[0].not.atom.variables[1].name);
    try testing.expect(effects.xor[1].* == .atom);
    try testing.expectEqualStrings("at", effects.xor[1].atom.name);
    try testing.expectEqual(@as(usize, 1), effects.xor[1].atom.variables.len);
    try testing.expectEqualStrings("p_2", effects.xor[1].atom.variables[0].name);
}

test "probabilistic action parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                :precondition (at p1)
        \\                :effect (probabilistic
        \\                    0.8 (and (not (at p_2 p_3)) (at p_2))
        \\                    0.2 (probabilistic
        \\                            0.5 (hold p_2 p_3)
        \\                            0.5 (not (at p_2))
        \\                        )
        \\                    )
        \\                )
        \\            )
    ;
    const action = (try parseDomain(&arena, source)).actions[0];
    try testing.expectEqualStrings("a_1", action.name);

    const effects = action.effects.?;
    try testing.expect(effects == .and_);
    try testing.expectEqual(@as(usize, 2), effects.and_.len);

    const first = effects.and_[0].*;
    try testing.expect(first == .probabilistic);
    try testing.expectEqualDeep(tk.Number{ .real = 0.8 }, first.probabilistic.probability);
    const first_formula = first.probabilistic.formula.*;
    try testing.expect(first_formula == .and_);
    try testing.expectEqual(@as(usize, 2), first_formula.and_.len);
    try testing.expect(first_formula.and_[0].* == .not);
    try testing.expectEqualStrings("at", first_formula.and_[0].not.atom.name);
    try testing.expectEqual(@as(usize, 2), first_formula.and_[0].not.atom.variables.len);
    try testing.expectEqualStrings("p_2", first_formula.and_[0].not.atom.variables[0].name);
    try testing.expectEqualStrings("p_3", first_formula.and_[0].not.atom.variables[1].name);
    try testing.expect(first_formula.and_[1].* == .atom);
    try testing.expectEqualStrings("at", first_formula.and_[1].atom.name);
    try testing.expectEqual(@as(usize, 1), first_formula.and_[1].atom.variables.len);
    try testing.expectEqualStrings("p_2", first_formula.and_[1].atom.variables[0].name);

    const second = effects.and_[1].*;
    try testing.expect(second == .probabilistic);
    try testing.expectEqualDeep(tk.Number{ .real = 0.2 }, second.probabilistic.probability);
    const nested = second.probabilistic.formula.*;
    try testing.expect(nested == .and_);
    try testing.expectEqual(@as(usize, 2), nested.and_.len);

    const nested_first = nested.and_[0].*;
    try testing.expect(nested_first == .probabilistic);
    try testing.expectEqualDeep(tk.Number{ .real = 0.5 }, nested_first.probabilistic.probability);
    try testing.expect(nested_first.probabilistic.formula.* == .atom);
    try testing.expectEqualStrings("hold", nested_first.probabilistic.formula.atom.name);
    try testing.expectEqual(@as(usize, 2), nested_first.probabilistic.formula.atom.variables.len);

    const nested_second = nested.and_[1].*;
    try testing.expect(nested_second == .probabilistic);
    try testing.expectEqualDeep(tk.Number{ .real = 0.5 }, nested_second.probabilistic.probability);
    try testing.expect(nested_second.probabilistic.formula.* == .not);
    try testing.expectEqualStrings("at", nested_second.probabilistic.formula.not.atom.name);
    try testing.expectEqual(@as(usize, 1), nested_second.probabilistic.formula.not.atom.variables.len);
    try testing.expectEqualStrings("p_2", nested_second.probabilistic.formula.not.atom.variables[0].name);
}

test "out of range probability" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                :parameters (p_1 p_2 - t1)
        \\                :precondition (at p_1)
        \\                :effect (probabilistic
        \\                    1.5 (at p_2)
        \\                    )
        \\                )
        \\            )
    ;
    const diagnostic = try parseFailure(&arena, source);
    try testing.expectEqualStrings("a probability in [0, 1]", diagnostic.expected);
    try testing.expectEqualDeep(tk.Number{ .real = 1.5 }, diagnostic.found_number.?);
}

test "type declarations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain blahblah)
        \\                (:types
        \\                    Port AbstractDevice - Object
        \\                    AbstractCable Device - AbstractDevice
        \\                    PlugType PlugFace PlugDirection SignalType - Enum
        \\                )
        \\             )
    ;
    const types = (try parseDomain(&arena, source)).types.?;
    const expected_names = [_][]const u8{
        "Port",     "AbstractDevice", "AbstractCable", "Device",
        "PlugType", "PlugFace",       "PlugDirection", "SignalType",
    };
    const expected_types = [_][]const u8{
        "Object", "Object", "AbstractDevice", "AbstractDevice",
        "Enum",   "Enum",   "Enum",           "Enum",
    };
    try testing.expectEqual(expected_names.len, types.len);
    for (types, expected_names, expected_types) |symbol, name, symbol_type| {
        try testing.expectEqualStrings(name, symbol.name);
        try testing.expectEqualStrings(symbol_type, symbol.symbol_type.?);
    }
}

test "function parsing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain rover-domain)
        \\            (:functions
        \\                (battery-amount ?r - rover)
        \\                (recharge-rate ?r - rover)
        \\                (battery-capacity)
        \\                (distance ?wp1 - waypoint ?wp2 - waypoint)
        \\            )
        \\        )
    ;
    const functions = (try parseDomain(&arena, source)).functions;
    try testing.expectEqual(@as(usize, 4), functions.len);

    try testing.expectEqualStrings("battery-amount", functions[0].name);
    try testing.expectEqual(@as(usize, 1), functions[0].variables.len);
    try testing.expectEqualStrings("?r", functions[0].variables[0].name);
    try testing.expectEqualStrings("rover", functions[0].variables[0].symbol_type.?);

    try testing.expectEqualStrings("recharge-rate", functions[1].name);
    try testing.expectEqual(@as(usize, 1), functions[1].variables.len);
    try testing.expectEqualStrings("?r", functions[1].variables[0].name);
    try testing.expectEqualStrings("rover", functions[1].variables[0].symbol_type.?);

    try testing.expectEqualStrings("battery-capacity", functions[2].name);
    try testing.expectEqual(@as(usize, 0), functions[2].variables.len);

    try testing.expectEqualStrings("distance", functions[3].name);
    try testing.expectEqual(@as(usize, 2), functions[3].variables.len);
    try testing.expectEqualStrings("?wp1", functions[3].variables[0].name);
    try testing.expectEqualStrings("waypoint", functions[3].variables[0].symbol_type.?);
    try testing.expectEqualStrings("?wp2", functions[3].variables[1].name);
    try testing.expectEqualStrings("waypoint", functions[3].variables[1].symbol_type.?);
}

test "comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\;author: me
        \\            ; domain bal
        \\            (define (domain bal)
        \\                ;task c_1
        \\                (:task c_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2) ;task parameters are defined here
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.compound_tasks.len);
    const c_1 = domain.compound_tasks[0];
    try testing.expectEqualStrings("c_1", c_1.name);
    try testing.expectEqual(@as(usize, 3), c_1.parameters.len);
    try testing.expectEqualStrings("p_1", c_1.parameters[0].name);
    try testing.expectEqualStrings("p_2", c_1.parameters[1].name);
    try testing.expectEqualStrings("p_3", c_1.parameters[2].name);
    try testing.expectEqualStrings("t1", c_1.parameters[0].symbol_type.?);
    try testing.expectEqualStrings("t1", c_1.parameters[1].symbol_type.?);
    try testing.expectEqualStrings("t2", c_1.parameters[2].symbol_type.?);
}

test "constants declaration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain blahblah)
        \\                (:constants
        \\                    Port AbstractDevice - Object
        \\                    AbstractCable Device - AbstractDevice
        \\                    PlugType PlugFace PlugDirection SignalType - Enum
        \\                )
        \\             )
    ;
    const constants = (try parseDomain(&arena, source)).constants.?;
    const expected_names = [_][]const u8{
        "Port",     "AbstractDevice", "AbstractCable", "Device",
        "PlugType", "PlugFace",       "PlugDirection", "SignalType",
    };
    const expected_types = [_][]const u8{
        "Object", "Object", "AbstractDevice", "AbstractDevice",
        "Enum",   "Enum",   "Enum",           "Enum",
    };
    try testing.expectEqual(expected_names.len, constants.len);
    for (constants, expected_names, expected_types) |symbol, name, symbol_type| {
        try testing.expectEqualStrings(name, symbol.name);
        try testing.expectEqualStrings(symbol_type, symbol.symbol_type.?);
    }
}

test "last character of the file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                 :precondition (not (at p_1))
        \\                 :effect (and (not (hold p_2 p_3))
        \\                 (at p_2))
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.actions.len);
}

test "last character of the file followed by whitespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1 p_3 - t2)
        \\                 :precondition (not (at p_1))
        \\                 :effect (and (not (hold p_2 p_3))
        \\                 (at p_2))
        \\                )
        \\             )             
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 1), domain.actions.len);
}

test "empty task network" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (problem p1) (domain bal)
        \\             (:htn )
    ;
    const init_tn = (try parseProblem(&arena, source)).init_tn.?;
    try testing.expect(init_tn.parameters == null);
    try testing.expectEqual(@as(usize, 0), init_tn.tn.subtasks.len);
}

test "file classification" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const domain_source =
        \\(define (domain blahblah)
        \\                (:constants Port AbstractDevice - Object)
        \\             )
    ;
    var domain_parser = try Parser.init(arena.allocator(), domain_source);
    try testing.expectEqual(parser_mod.FileVariant.domain, domain_parser.classify());

    const problem_source = "(define (problem p1) (domain bal) (:init))";
    var problem_parser = try Parser.init(arena.allocator(), problem_source);
    try testing.expectEqual(parser_mod.FileVariant.problem, problem_parser.classify());

    const other_source = "(this is not hddl)";
    var other_parser = try Parser.init(arena.allocator(), other_source);
    try testing.expectEqual(parser_mod.FileVariant.maybe_not_hddl, other_parser.classify());
}

// ---------------------------------------------------------------------------
// Formula tests that exercise parsed formulas
// (src/syntactic_analyzer/tests/formula_tests.rs)
// ---------------------------------------------------------------------------

test "parsed precondition conjunction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const source =
        \\(define (domain bal)
        \\                (:action a_1
        \\                 :parameters (p_1 p_2 - t1)
        \\                 :precondition (and (at p_1) (not (at p_2)))
        \\                 :effect (at p_2)
        \\                )
        \\                (:action a_2
        \\                 :parameters (p_1 p_2 - t1)
        \\                 :precondition (or (at p_1) (at p_2))
        \\                 :effect (at p_2)
        \\                )
        \\             )
    ;
    const domain = try parseDomain(&arena, source);
    try testing.expectEqual(@as(usize, 2), domain.actions.len);
    try testing.expect(domain.actions[0].preconditions.?.isSimpleConjunction());
    try testing.expect(domain.actions[0].effects.?.isSimpleConjunction());
    try testing.expect(!domain.actions[1].preconditions.?.isSimpleConjunction());
}

// ---------------------------------------------------------------------------
// Integration tests (tests/integration_flawed.rs, tests/integration_ipc.rs)
// ---------------------------------------------------------------------------

const FlawedOutcome = enum {
    parses,
    syntax_error,
};

const FlawedCase = struct {
    file: []const u8,
    outcome: FlawedOutcome,
    /// Expected diagnostic line for syntax errors.
    line: u32 = 0,
    found_lexeme: ?[]const u8 = null,
};

// The reference suite runs these through semantic verification; only the
// syntactic cases can fail here.
const flawed_cases = [_]FlawedCase{
    .{ .file = "abstract-task-without-decomposition-domain.hddl", .outcome = .parses },
    .{ .file = "abstract-task-without-refinement-domain.hddl", .outcome = .parses },
    .{ .file = "complementary-effects-domain.hddl", .outcome = .parses },
    .{ .file = "complementary-preconditions-domain.hddl", .outcome = .parses },
    .{ .file = "cyclic-ordering-for-subtasks-domain.hddl", .outcome = .parses },
    .{ .file = "directly-cyclic-subtypes-domain.hddl", .outcome = .parses },
    .{ .file = "duplicate-action-domain.hddl", .outcome = .parses },
    .{ .file = "duplicate-compound-task-domain.hddl", .outcome = .parses },
    .{ .file = "duplicate-decomposition-method-domain.hddl", .outcome = .parses },
    .{ .file = "duplicate-parameters-domain.hddl", .outcome = .parses },
    .{ .file = "duplicate-predicate-domain.hddl", .outcome = .parses },
    // Reference test expects a syntactic error; known gap in the reference.
    .{ .file = "forgotten-dash-domain.hddl", .outcome = .parses },
    .{ .file = "extra-parentheses-domain.hddl", .outcome = .syntax_error, .line = 67, .found_lexeme = ":effect" },
    .{ .file = "forgotten-entries-domain.hddl", .outcome = .syntax_error, .line = 63, .found_lexeme = ":precondition" },
    // Reference test expects a syntactic error; known gap in the reference.
    .{ .file = "forgotten-question-mark-domain.hddl", .outcome = .parses },
    .{ .file = "inconsistent-num-parameters-predicate-domain.hddl", .outcome = .parses },
    .{ .file = "inconsistent-num-parameters-task-domain.hddl", .outcome = .parses },
    .{ .file = "inconsistent-type-parameters-predicate-domain.hddl", .outcome = .parses },
    .{ .file = "inconsistent-type-parameters-task-domain.hddl", .outcome = .parses },
    .{ .file = "indirectly-cyclic-subtypes-domain.hddl", .outcome = .parses },
    .{ .file = "possible-complementary-effects-domain.hddl", .outcome = .parses },
    .{ .file = "undeclared-method-parameter-domain.hddl", .outcome = .parses },
    .{ .file = "undeclared-task-parameter-domain.hddl", .outcome = .parses },
    .{ .file = "undefined-predicate-domain.hddl", .outcome = .parses },
    .{ .file = "undefined-task-domain.hddl", .outcome = .parses },
    .{ .file = "undefined-type-domain.hddl", .outcome = .parses },
};

test "flawed domains" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (flawed_cases) |case| {
        const path = try std.fmt.allocPrint(arena.allocator(), "test_data/flawed_domains/{s}", .{case.file});
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .unlimited);

        var parser = try Parser.init(arena.allocator(), source);
        if (case.outcome == .parses) {
            const parsed = parser.parse() catch |err| {
                std.debug.print("expected {s} to parse, got {s}\n", .{ case.file, @errorName(err) });
                return err;
            };
            try testing.expect(parsed == .domain);
        } else {
            try testing.expectError(error.ParseFailed, parser.parse());
            const diagnostic = parser.diagnostic.?;
            try testing.expectEqual(case.line, diagnostic.line);
            if (case.found_lexeme) |lexeme| {
                try testing.expectEqualStrings(lexeme, diagnostic.found_lexeme.?);
            }
        }
    }
}

test "IPC domains and problems" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try std.Io.Dir.cwd().openDir(io, "test_data/ipc", .{ .iterate = true });
    defer root.close(io);

    var domains: usize = 0;
    var problems: usize = 0;

    var root_iterator = root.iterate();
    while (try root_iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        var directory = try root.openDir(io, entry.name, .{ .iterate = true });
        defer directory.close(io);

        const domain_source = try directory.readFileAlloc(io, "domain.hddl", allocator, .unlimited);
        var domain_parser = try Parser.init(allocator, domain_source);
        const domain_ast = domain_parser.parse() catch |err| {
            std.debug.print("failed to parse {s}/domain.hddl: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        try testing.expect(domain_ast == .domain);
        domains += 1;

        var directory_iterator = directory.iterate();
        while (try directory_iterator.next(io)) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (std.mem.eql(u8, file_entry.name, "domain.hddl")) continue;
            if (!std.mem.endsWith(u8, file_entry.name, ".hddl")) continue;

            const problem_source = try directory.readFileAlloc(io, file_entry.name, allocator, .unlimited);
            var problem_parser = try Parser.init(allocator, problem_source);
            const problem_ast = problem_parser.parse() catch |err| {
                std.debug.print("failed to parse {s}/{s}: {s}\n", .{ entry.name, file_entry.name, @errorName(err) });
                return err;
            };
            try testing.expect(problem_ast == .problem);
            problems += 1;
        }
    }

    // Guard against silently testing nothing if the data directory moves.
    try testing.expect(domains > 40);
    try testing.expect(problems > 700);
}
