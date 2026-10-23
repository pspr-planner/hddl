//! Abstract syntax tree for HDDL domains and problems.
//!
//! The shapes mirror the reference parser's syntax tree. All strings in the
//! tree point into the parser's copy of the input, and all nodes are owned by
//! the allocator passed to the parser (an arena is the natural choice).

const std = @import("std");
const tk = @import("token.zig");

pub const TokenPosition = tk.TokenPosition;
pub const Number = tk.Number;
pub const Requirement = tk.Requirement;

/// A named object, variable, type, parameter, task reference, ...
pub const Symbol = struct {
    name: []const u8,
    name_pos: TokenPosition = .{},
    symbol_type: ?[]const u8 = null,
    type_pos: ?TokenPosition = null,

    pub fn write(self: Symbol, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.symbol_type) |symbol_type| {
            try w.print("{s} - {s}", .{ self.name, symbol_type });
        } else {
            try w.writeAll(self.name);
        }
    }
};

pub fn writeSymbolNames(w: *std.Io.Writer, symbols: []const Symbol) std.Io.Writer.Error!void {
    for (symbols, 0..) |symbol, i| {
        if (i != 0) try w.writeByte(' ');
        try w.writeAll(symbol.name);
    }
}

pub fn writeTypedList(w: *std.Io.Writer, symbols: []const Symbol) std.Io.Writer.Error!void {
    for (symbols, 0..) |symbol, i| {
        if (i != 0) try w.writeByte(' ');
        try symbol.write(w);
    }
}

fn writeCall(w: *std.Io.Writer, name: []const u8, args: []const Symbol) std.Io.Writer.Error!void {
    try w.print("({s}", .{name});
    for (args) |arg| try w.print(" {s}", .{arg.name});
    try w.writeByte(')');
}

pub const Predicate = struct {
    name: []const u8,
    name_pos: TokenPosition = .{},
    variables: []Symbol,

    pub fn arity(self: Predicate) usize {
        return self.variables.len;
    }

    pub fn write(self: Predicate, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeCall(w, self.name, self.variables);
    }
};

pub const Task = struct {
    name: []const u8,
    name_pos: TokenPosition = .{},
    parameters: []Symbol,

    pub fn write(self: Task, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(:task {s} :parameters (", .{self.name});
        try writeTypedList(w, self.parameters);
        try w.writeAll("))");
    }
};

pub const Function = struct {
    name: []const u8,
    name_pos: TokenPosition = .{},
    variables: []Symbol,

    pub fn write(self: Function, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeCall(w, self.name, self.variables);
    }
};

pub const Formula = union(enum) {
    empty,
    atom: Predicate,
    not: *Formula,
    and_: []*Formula,
    or_: []*Formula,
    xor: []*Formula,
    imply: struct {
        lhs: *Formula,
        rhs: *Formula,
    },
    exists: struct {
        vars: []Symbol,
        body: *Formula,
    },
    forall: struct {
        vars: []Symbol,
        body: *Formula,
    },
    probabilistic: struct {
        probability: Number,
        formula: *Formula,
    },
    equals: struct {
        lhs: []const u8,
        rhs: []const u8,
    },

    /// An atom, or a negated atom/equality.
    pub fn isLiteral(self: Formula) bool {
        return switch (self) {
            .atom => true,
            .not => |inner| inner.* == .atom or inner.* == .equals,
            else => false,
        };
    }

    /// Whether the formula is a (possibly empty) conjunction of literals.
    pub fn isSimpleConjunction(self: Formula) bool {
        return switch (self) {
            .empty => true,
            .and_ => |terms| blk: {
                for (terms) |term| {
                    if (!term.*.isLiteral()) break :blk false;
                }
                break :blk true;
            },
            else => self.isLiteral(),
        };
    }

    /// The predicates outside of quantifier bodies, in depth-first order.
    pub fn getPropositionalPredicates(
        self: Formula,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]Predicate {
        var predicates = std.ArrayList(Predicate).empty;
        try self.collectPropositionalPredicates(&predicates, allocator);
        return predicates.toOwnedSlice(allocator);
    }

    fn collectPropositionalPredicates(
        self: Formula,
        predicates: *std.ArrayList(Predicate),
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .empty, .equals => {},
            .atom => |predicate| try predicates.append(allocator, predicate),
            .not => |inner| try inner.*.collectPropositionalPredicates(predicates, allocator),
            .and_ => |terms| {
                for (terms) |term| try term.*.collectPropositionalPredicates(predicates, allocator);
            },
            .or_ => |terms| {
                for (terms) |term| try term.*.collectPropositionalPredicates(predicates, allocator);
            },
            .xor => |terms| {
                for (terms) |term| try term.*.collectPropositionalPredicates(predicates, allocator);
            },
            .imply => |implication| {
                try implication.lhs.*.collectPropositionalPredicates(predicates, allocator);
                try implication.rhs.*.collectPropositionalPredicates(predicates, allocator);
            },
            .probabilistic => |branch| {
                try branch.formula.*.collectPropositionalPredicates(predicates, allocator);
            },
            // Not propositional.
            .exists, .forall => {},
        }
    }

    pub fn write(self: Formula, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .empty => try w.writeAll("()"),
            .atom => |predicate| try predicate.write(w),
            .not => |inner| {
                try w.writeAll("(not ");
                try inner.write(w);
                try w.writeByte(')');
            },
            .and_ => |terms| try writeConnective(w, "and", terms),
            .or_ => |terms| try writeConnective(w, "or", terms),
            .xor => |terms| try writeConnective(w, "oneof", terms),
            .imply => |implication| {
                try w.writeAll("(imply ");
                try implication.lhs.write(w);
                try w.writeByte(' ');
                try implication.rhs.write(w);
                try w.writeByte(')');
            },
            .exists => |quantified| {
                try w.writeAll("(exists (");
                try writeTypedList(w, quantified.vars);
                try w.writeAll(") ");
                try quantified.body.write(w);
                try w.writeByte(')');
            },
            .forall => |quantified| {
                try w.writeAll("(forall (");
                try writeTypedList(w, quantified.vars);
                try w.writeAll(") ");
                try quantified.body.write(w);
                try w.writeByte(')');
            },
            .probabilistic => |branch| {
                try w.writeAll("(probabilistic ");
                try branch.probability.write(w);
                try w.writeByte(' ');
                try branch.formula.write(w);
                try w.writeByte(')');
            },
            .equals => |equality| try w.print("(= {s} {s})", .{ equality.lhs, equality.rhs }),
        }
    }
};

fn writeConnective(w: *std.Io.Writer, name: []const u8, terms: []const *Formula) std.Io.Writer.Error!void {
    try w.print("({s}", .{name});
    for (terms) |term| {
        try w.writeByte(' ');
        try term.write(w);
    }
    try w.writeByte(')');
}

pub const Action = struct {
    name: []const u8,
    name_pos: TokenPosition = .{},
    parameters: []Symbol,
    preconditions: ?Formula = null,
    effects: ?Formula = null,

    pub fn write(self: Action, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(:action {s} :parameters (", .{self.name});
        try writeTypedList(w, self.parameters);
        try w.writeByte(')');
        if (self.preconditions) |preconditions| {
            try w.writeAll(" :precondition ");
            try preconditions.write(w);
        }
        if (self.effects) |effects| {
            try w.writeAll(" :effect ");
            try effects.write(w);
        }
        try w.writeByte(')');
    }
};

pub const Subtask = struct {
    id: ?Symbol = null,
    task: Symbol,
    terms: []Symbol,

    pub fn write(self: Subtask, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.id) |id| {
            try w.print("({s} ", .{id.name});
            try writeCall(w, self.task.name, self.terms);
            try w.writeByte(')');
        } else {
            try writeCall(w, self.task.name, self.terms);
        }
    }
};

pub const Constraint = union(enum) {
    equal: struct { lhs: []const u8, rhs: []const u8 },
    not_equal: struct { lhs: []const u8, rhs: []const u8 },

    pub fn write(self: Constraint, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .equal => |equality| try w.print("(= {s} {s})", .{ equality.lhs, equality.rhs }),
            .not_equal => |inequality| try w.print("(not (= {s} {s}))", .{ inequality.lhs, inequality.rhs }),
        }
    }
};

pub const Ordering = struct {
    before: []const u8,
    after: []const u8,
};

pub const TaskOrdering = union(enum) {
    total,
    partial: []Ordering,
};

pub const HTN = struct {
    subtasks: []Subtask = &.{},
    ordering_pos: ?TokenPosition = null,
    orderings: TaskOrdering = .{ .partial = &.{} },
    constraints: ?[]Constraint = null,

    pub fn isTotal(self: HTN) bool {
        return self.orderings == .total;
    }

    pub fn write(self: HTN, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const keyword: []const u8 = switch (self.orderings) {
            .total => ":ordered-subtasks",
            .partial => ":subtasks",
        };
        try w.writeAll(keyword);
        if (self.subtasks.len == 0) {
            try w.writeAll(" ()");
        } else {
            try w.writeAll(" (and");
            for (self.subtasks) |subtask| {
                try w.writeByte(' ');
                try subtask.write(w);
            }
            try w.writeByte(')');
        }

        switch (self.orderings) {
            .total => {},
            .partial => |orderings| {
                if (orderings.len != 0) {
                    try w.writeAll(" :ordering (and");
                    for (orderings) |ordering| {
                        try w.print(" (< {s} {s})", .{ ordering.before, ordering.after });
                    }
                    try w.writeByte(')');
                }
            },
        }

        if (self.constraints) |constraints| {
            if (constraints.len == 0) {
                try w.writeAll(" :constraints ()");
            } else {
                try w.writeAll(" :constraints (and");
                for (constraints) |constraint| {
                    try w.writeByte(' ');
                    try constraint.write(w);
                }
                try w.writeByte(')');
            }
        }
    }
};

pub const InitialTaskNetwork = struct {
    parameters: ?[]Symbol = null,
    tn: HTN = .{},

    pub fn write(self: InitialTaskNetwork, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(:htn");
        if (self.parameters) |parameters| {
            try w.writeAll(" :parameters (");
            try writeTypedList(w, parameters);
            try w.writeByte(')');
        }
        try w.writeByte(' ');
        try self.tn.write(w);
        try w.writeByte(')');
    }
};

pub const Method = struct {
    name: Symbol,
    task: Symbol,
    task_terms: []Symbol,
    params: []Symbol,
    precondition: ?Formula = null,
    tn: HTN,

    pub fn write(self: Method, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(:method {s} :parameters (", .{self.name.name});
        try writeTypedList(w, self.params);
        try w.writeAll(") :task ");
        try writeCall(w, self.task.name, self.task_terms);
        if (self.precondition) |precondition| {
            try w.writeAll(" :precondition ");
            try precondition.write(w);
        }
        try w.writeByte(' ');
        try self.tn.write(w);
        try w.writeByte(')');
    }
};

pub const Domain = struct {
    name: []const u8,
    types: ?[]Symbol = null,
    constants: ?[]Symbol = null,
    requirements: []Requirement = &.{},
    predicates: []Predicate = &.{},
    compound_tasks: []Task = &.{},
    methods: []Method = &.{},
    actions: []Action = &.{},
    functions: []Function = &.{},

    pub fn write(self: Domain, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(define (domain {s})", .{self.name});
        if (self.requirements.len != 0) {
            try w.writeAll(" (:requirements");
            for (self.requirements) |requirement| try w.print(" {s}", .{requirement.text()});
            try w.writeByte(')');
        }
        if (self.types) |types| {
            try w.writeAll(" (:types");
            for (types) |symbol| {
                try w.writeByte(' ');
                try symbol.write(w);
            }
            try w.writeByte(')');
        }
        if (self.constants) |constants| {
            try w.writeAll(" (:constants");
            for (constants) |symbol| {
                try w.writeByte(' ');
                try symbol.write(w);
            }
            try w.writeByte(')');
        }
        if (self.predicates.len != 0) {
            try w.writeAll(" (:predicates");
            for (self.predicates) |predicate| {
                try w.writeByte(' ');
                try predicate.write(w);
            }
            try w.writeByte(')');
        }
        if (self.functions.len != 0) {
            try w.writeAll(" (:functions");
            for (self.functions) |function| {
                try w.writeByte(' ');
                try function.write(w);
            }
            try w.writeByte(')');
        }
        for (self.compound_tasks) |task| {
            try w.writeByte(' ');
            try task.write(w);
        }
        for (self.methods) |method| {
            try w.writeByte(' ');
            try method.write(w);
        }
        for (self.actions) |action| {
            try w.writeByte(' ');
            try action.write(w);
        }
        try w.writeByte(')');
    }
};

pub const Problem = struct {
    name: []const u8,
    domain_name: []const u8,
    requirements: []Requirement = &.{},
    init_tn: ?InitialTaskNetwork = null,
    init_state: []Predicate = &.{},
    goal: ?Formula = null,
    objects: []Symbol = &.{},

    pub fn write(self: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("(define (problem {s}) (:domain {s})", .{ self.name, self.domain_name });
        if (self.requirements.len != 0) {
            try w.writeAll(" (:requirements");
            for (self.requirements) |requirement| try w.print(" {s}", .{requirement.text()});
            try w.writeByte(')');
        }
        if (self.objects.len != 0) {
            try w.writeAll(" (:objects");
            for (self.objects) |object| {
                try w.writeByte(' ');
                try object.write(w);
            }
            try w.writeByte(')');
        }
        if (self.init_tn) |init_tn| {
            try w.writeByte(' ');
            try init_tn.write(w);
        }
        if (self.init_state.len != 0) {
            try w.writeAll(" (:init");
            for (self.init_state) |fact| {
                try w.writeByte(' ');
                try fact.write(w);
            }
            try w.writeByte(')');
        }
        if (self.goal) |goal| {
            try w.writeAll(" (:goal ");
            try goal.write(w);
            try w.writeByte(')');
        }
        try w.writeByte(')');
    }
};

pub const Ast = union(enum) {
    domain: Domain,
    problem: Problem,

    pub fn write(self: Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .domain => |domain| try domain.write(w),
            .problem => |problem| try problem.write(w),
        }
    }
};

pub const Program = struct {
    domain: Domain,
    problem: ?Problem = null,

    pub fn writeDomain(self: Program, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.domain.write(w);
    }

    pub fn writeProblem(self: Program, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.problem) |problem| try problem.write(w);
    }
};
