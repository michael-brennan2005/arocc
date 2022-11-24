const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Compilation = @import("Compilation.zig");
const Interner = @import("Interner.zig");
const Ir = @import("Ir.zig");
const Builder = Ir.Builder;
const StringId = @import("StringInterner.zig").StringId;
const Tree = @import("Tree.zig");
const NodeIndex = Tree.NodeIndex;
const Type = @import("Type.zig");
const Value = @import("Value.zig");

const CodeGen = @This();

const WipSwitch = struct {
    cases: Cases = .{},
    default: ?Ir.Ref = null,
    size: u64,

    const Cases = std.MultiArrayList(struct {
        val: Interner.Ref,
        label: Ir.Ref,
    });
};

const Symbol = struct {
    name: StringId,
    val: Ir.Ref,
};

const Error = Compilation.Error;

tree: Tree,
comp: *Compilation,
builder: Builder,
node_tag: []const Tree.Tag,
node_data: []const Tree.Node.Data,
node_ty: []const Type,
wip_switch: *WipSwitch = undefined,
cond_dummy_ref: Ir.Ref = undefined,
symbols: std.ArrayListUnmanaged(Symbol) = .{},
continue_label: Ir.Ref = undefined,
break_label: Ir.Ref = undefined,
return_label: Ir.Ref = undefined,

pub fn generateTree(comp: *Compilation, tree: Tree) Compilation.Error!void {
    var c = CodeGen{
        .builder = .{
            .gpa = comp.gpa,
            .arena = std.heap.ArenaAllocator.init(comp.gpa),
        },
        .tree = tree,
        .comp = comp,
        .node_tag = tree.nodes.items(.tag),
        .node_data = tree.nodes.items(.data),
        .node_ty = tree.nodes.items(.ty),
    };
    defer c.symbols.deinit(c.builder.gpa);

    const node_tags = tree.nodes.items(.tag);
    for (tree.root_decls) |decl| {
        c.builder.arena.deinit();
        c.builder.arena = std.heap.ArenaAllocator.init(comp.gpa);
        c.builder.instructions.len = 0;
        c.builder.body.items.len = 0;

        switch (node_tags[@enumToInt(decl)]) {
            .static_assert,
            .typedef,
            .struct_decl_two,
            .union_decl_two,
            .enum_decl_two,
            .struct_decl,
            .union_decl,
            .enum_decl,
            => {},

            .fn_proto,
            .static_fn_proto,
            .inline_fn_proto,
            .inline_static_fn_proto,
            .extern_var,
            .threadlocal_extern_var,
            => {},

            .fn_def,
            .static_fn_def,
            .inline_fn_def,
            .inline_static_fn_def,
            => c.genFn(decl) catch |err| switch (err) {
                error.FatalError => return error.FatalError,
                error.OutOfMemory => return error.OutOfMemory,
            },

            .@"var",
            .static_var,
            .threadlocal_var,
            .threadlocal_static_var,
            => c.genVar(decl) catch |err| switch (err) {
                error.FatalError => return error.FatalError,
                error.OutOfMemory => return error.OutOfMemory,
            },
            else => unreachable,
        }
    }
}

fn genType(c: *CodeGen, base_ty: Type) !Interner.Ref {
    var key: Interner.Key = undefined;
    const ty = base_ty.canonicalize(.standard);
    switch (ty.specifier) {
        .void => return .void,
        .bool => return .i1,
        else => {},
    }
    if (ty.isPtr()) return .ptr;
    if (ty.isFunc()) return .func;
    if (!ty.isReal()) @panic("TODO lower complex types");
    if (ty.isInt()) {
        const bits = ty.bitSizeof(c.comp).?;
        key = .{ .int = @intCast(u16, bits) };
    } else if (ty.isFloat()) {
        const bits = ty.bitSizeof(c.comp).?;
        key = .{ .float = @intCast(u16, bits) };
    } else if (ty.isArray()) {
        const elem = try c.genType(ty.elemType());
        key = .{ .array = .{ .child = elem, .len = ty.arrayLen().? } };
    } else if (ty.specifier == .vector) {
        const elem = try c.genType(ty.elemType());
        key = .{ .vector = .{ .child = elem, .len = @intCast(u32, ty.data.array.len) } };
    }
    return c.builder.pool.put(c.builder.gpa, key);
}

fn genFn(c: *CodeGen, decl: NodeIndex) Error!void {
    const name = c.tree.tokSlice(c.node_data[@enumToInt(decl)].decl.name);
    const func_ty = c.node_ty[@enumToInt(decl)].canonicalize(.standard);
    c.builder.alloc_count = 0;

    // reserve space for arg instructions
    const params = func_ty.data.func.params;
    try c.builder.instructions.ensureUnusedCapacity(c.builder.gpa, params.len);
    c.builder.instructions.len = params.len;

    for (params) |param, i| {
        // TODO handle calling convention here
        const arg = @intToEnum(Ir.Ref, i);
        c.builder.instructions.set(i, .{
            .tag = .arg,
            .data = .{ .arg = @intCast(u32, i) },
            .ty = try c.genType(param.ty),
        });
        const size = @intCast(u32, param.ty.sizeof(c.comp).?); // TODO add error in parser
        const @"align" = param.ty.alignof(c.comp);
        const alloc = try c.builder.addAlloc(size, @"align");
        try c.builder.addStore(alloc, arg);
        try c.symbols.append(c.comp.gpa, .{ .name = param.name, .val = alloc });
    }
    // Generate body
    c.return_label = try c.builder.addLabel("return");
    try c.genStmt(c.node_data[@enumToInt(decl)].decl.node);

    // Relocate returns
    try c.builder.body.append(c.builder.gpa, c.return_label);
    _ = try c.builder.addInst(.ret, undefined, .noreturn);

    var res = Ir{
        .pool = c.builder.pool,
        .instructions = c.builder.instructions,
        .arena = c.builder.arena.state,
        .body = c.builder.body,
    };
    res.dump(name, c.comp.diag.color, std.io.getStdOut().writer()) catch {};
}

fn addUn(c: *CodeGen, tag: Ir.Inst.Tag, operand: Ir.Ref, ty: Type) !Ir.Ref {
    return c.builder.addInst(tag, .{ .un = operand }, try c.genType(ty));
}

fn addBin(c: *CodeGen, tag: Ir.Inst.Tag, lhs: Ir.Ref, rhs: Ir.Ref, ty: Type) !Ir.Ref {
    return c.builder.addInst(tag, .{ .bin = .{ .lhs = lhs, .rhs = rhs } }, try c.genType(ty));
}

fn genStmt(c: *CodeGen, node: NodeIndex) Error!void {
    std.debug.assert(node != .none);
    const ty = c.node_ty[@enumToInt(node)];
    const data = c.node_data[@enumToInt(node)];
    switch (c.node_tag[@enumToInt(node)]) {
        .fn_def,
        .static_fn_def,
        .inline_fn_def,
        .inline_static_fn_def,
        .invalid,
        .threadlocal_var,
        => unreachable,
        .static_assert,
        .fn_proto,
        .static_fn_proto,
        .inline_fn_proto,
        .inline_static_fn_proto,
        .extern_var,
        .threadlocal_extern_var,
        .typedef,
        .struct_decl_two,
        .union_decl_two,
        .enum_decl_two,
        .struct_decl,
        .union_decl,
        .enum_decl,
        .enum_field_decl,
        .record_field_decl,
        .indirect_record_field_decl,
        .struct_forward_decl,
        .union_forward_decl,
        .enum_forward_decl,
        .null_stmt,
        => {},
        .static_var,
        .implicit_static_var,
        .threadlocal_static_var,
        => try c.genVar(node), // TODO
        .@"var" => {
            const size = @intCast(u32, ty.sizeof(c.comp).?); // TODO add error in parser
            const @"align" = ty.alignof(c.comp);
            const alloc = try c.builder.addAlloc(size, @"align");
            const name = try c.comp.intern(c.tree.tokSlice(data.decl.name));
            try c.symbols.append(c.comp.gpa, .{ .name = name, .val = alloc });
            if (data.decl.node != .none) {
                const res = try c.genExpr(data.decl.node);
                try c.builder.addStore(alloc, res);
            }
        },
        .labeled_stmt => {
            const label = try c.builder.addLabel("label");
            try c.builder.body.append(c.comp.gpa, label);
            try c.genStmt(data.decl.node);
        },
        .compound_stmt_two => {
            const old_sym_len = c.symbols.items.len;
            c.symbols.items.len = old_sym_len;

            if (data.bin.lhs != .none) try c.genStmt(data.bin.lhs);
            if (data.bin.rhs != .none) try c.genStmt(data.bin.rhs);
        },
        .compound_stmt => {
            const old_sym_len = c.symbols.items.len;
            c.symbols.items.len = old_sym_len;

            for (c.tree.data[data.range.start..data.range.end]) |stmt| try c.genStmt(stmt);
        },
        .if_then_else_stmt => {
            const then_label = try c.builder.addLabel("if.then");
            const else_label = try c.builder.addLabel("if.else");
            const end_label = try c.builder.addLabel("if.end");

            {
                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = else_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(data.if3.cond);
            }

            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(c.tree.data[data.if3.body]); // then
            try c.builder.addJump(end_label);

            try c.builder.body.append(c.builder.gpa, else_label);
            try c.genStmt(c.tree.data[data.if3.body + 1]); // else

            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .if_then_stmt => {
            const then_label = try c.builder.addLabel("if.then");
            const end_label = try c.builder.addLabel("if.end");

            {
                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = end_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(data.bin.lhs);
            }
            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(data.bin.rhs); // then
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .switch_stmt => {
            var wip_switch = WipSwitch{
                .size = c.node_ty[@enumToInt(data.bin.lhs)].sizeof(c.comp).?,
            };
            defer wip_switch.cases.deinit(c.builder.gpa);

            const old_wip_switch = c.wip_switch;
            defer c.wip_switch = old_wip_switch;
            c.wip_switch = &wip_switch;

            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;
            const end_ref = try c.builder.addLabel("switch.end");
            c.break_label = end_ref;

            const cond = try c.genExpr(data.bin.lhs);
            const switch_index = c.builder.instructions.len;
            _ = try c.builder.addInst(.@"switch", undefined, .noreturn);

            try c.genStmt(data.bin.rhs); // body

            try c.builder.body.append(c.comp.gpa, end_ref);
            const default_ref = wip_switch.default orelse end_ref;
            try c.builder.body.append(c.builder.gpa, end_ref);

            const a = c.builder.arena.allocator();
            const switch_data = try a.create(Ir.Inst.Switch);
            switch_data.* = .{
                .target = cond,
                .cases_len = @intCast(u32, wip_switch.cases.len),
                .case_vals = (try a.dupe(Interner.Ref, wip_switch.cases.items(.val))).ptr,
                .case_labels = (try a.dupe(Ir.Ref, wip_switch.cases.items(.label))).ptr,
                .default = default_ref,
            };
            c.builder.instructions.items(.data)[switch_index] = .{ .@"switch" = switch_data };
        },
        .case_stmt => {
            const val = c.tree.value_map.get(data.bin.lhs).?;
            const label = try c.builder.addLabel("case");
            try c.builder.body.append(c.comp.gpa, label);
            try c.wip_switch.cases.append(c.builder.gpa, .{
                .val = try c.builder.pool.put(c.builder.gpa, .{ .value = val }),
                .label = label,
            });
            try c.genStmt(data.bin.rhs);
        },
        .default_stmt => {
            const default = try c.builder.addLabel("default");
            try c.builder.body.append(c.comp.gpa, default);
            c.wip_switch.default = default;
            try c.genStmt(data.un);
        },
        .while_stmt => {
            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;

            const old_continue_label = c.continue_label;
            defer c.continue_label = old_continue_label;

            const cond_label = try c.builder.addLabel("while.cond");
            const then_label = try c.builder.addLabel("while.then");
            const end_label = try c.builder.addLabel("while.end");

            c.continue_label = cond_label;
            c.break_label = end_label;

            try c.builder.body.append(c.builder.gpa, cond_label);
            {
                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = end_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(data.bin.lhs);
            }
            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(data.bin.rhs);
            try c.builder.addJump(cond_label);
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .do_while_stmt => {
            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;

            const old_continue_label = c.continue_label;
            defer c.continue_label = old_continue_label;

            const then_label = try c.builder.addLabel("do.then");
            const cond_label = try c.builder.addLabel("do.cond");
            const end_label = try c.builder.addLabel("do.end");

            c.continue_label = cond_label;
            c.break_label = end_label;

            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(data.bin.rhs);
            try c.builder.body.append(c.builder.gpa, cond_label);
            {
                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = end_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(data.bin.lhs);
            }
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .for_decl_stmt => {
            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;

            const old_continue_label = c.continue_label;
            defer c.continue_label = old_continue_label;

            const for_decl = data.forDecl(c.tree);
            for (for_decl.decls) |decl| try c.genStmt(decl);

            const then_label = try c.builder.addLabel("for.then");
            var cond_label = then_label;
            const cont_label = try c.builder.addLabel("for.cont");
            const end_label = try c.builder.addLabel("for.end");

            c.continue_label = cont_label;
            c.break_label = end_label;

            if (for_decl.cond != .none) {
                cond_label = try c.builder.addLabel("for.cond");
                try c.builder.body.append(c.builder.gpa, cond_label);

                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = end_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(for_decl.cond);
            }
            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(for_decl.body);
            if (for_decl.incr != .none) {
                _ = try c.genExpr(for_decl.incr);
            }
            try c.builder.addJump(cond_label);
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .forever_stmt => {
            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;

            const old_continue_label = c.continue_label;
            defer c.continue_label = old_continue_label;

            const then_label = try c.builder.addLabel("for.then");
            const end_label = try c.builder.addLabel("for.end");

            c.continue_label = then_label;
            c.break_label = end_label;

            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(data.un);
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .for_stmt => {
            const old_break_label = c.break_label;
            defer c.break_label = old_break_label;

            const old_continue_label = c.continue_label;
            defer c.continue_label = old_continue_label;

            const for_stmt = data.forStmt(c.tree);
            if (for_stmt.init != .none) _ = try c.genExpr(for_stmt.init);

            const then_label = try c.builder.addLabel("for.then");
            var cond_label = then_label;
            const cont_label = try c.builder.addLabel("for.cont");
            const end_label = try c.builder.addLabel("for.end");

            c.continue_label = cont_label;
            c.break_label = end_label;

            if (for_stmt.cond != .none) {
                cond_label = try c.builder.addLabel("for.cond");
                try c.builder.body.append(c.builder.gpa, cond_label);

                c.builder.branch = .{
                    .true_label = then_label,
                    .false_label = end_label,
                };
                defer c.builder.branch = null;
                try c.genBoolExpr(for_stmt.cond);
            }
            try c.builder.body.append(c.builder.gpa, then_label);
            try c.genStmt(for_stmt.body);
            if (for_stmt.incr != .none) {
                _ = try c.genExpr(for_stmt.incr);
            }
            try c.builder.addJump(cond_label);
            try c.builder.body.append(c.builder.gpa, end_label);
        },
        .continue_stmt => try c.builder.addJump(c.continue_label),
        .break_stmt => try c.builder.addJump(c.break_label),
        .return_stmt => {
            if (data.un != .none) {
                const operand = try c.genExpr(data.un);
                _ = try c.builder.addInst(.ret_value, .{ .un = operand }, .void);
            }
            try c.builder.addJump(c.return_label);
        },
        .implicit_return => {
            if (data.return_zero) {
                const operand = try c.builder.addConstant(Value.int(0), try c.genType(ty));
                _ = try c.builder.addInst(.ret_value, .{ .un = operand }, .void);
            }
            // No need to emit a jump since implicit_return is always the last instruction.
        },
        .case_range_stmt,
        .goto_stmt,
        .computed_goto_stmt,
        => return c.comp.diag.fatalNoSrc("TODO CodeGen.genStmt {}\n", .{c.node_tag[@enumToInt(node)]}),
        else => _ = try c.genExpr(node),
    }
}

fn genExpr(c: *CodeGen, node: NodeIndex) Error!Ir.Ref {
    std.debug.assert(node != .none);
    const ty = c.node_ty[@enumToInt(node)];
    if (c.tree.value_map.get(node)) |val| {
        return c.builder.addConstant(val, try c.genType(ty));
    }
    const data = c.node_data[@enumToInt(node)];
    switch (c.node_tag[@enumToInt(node)]) {
        .enumeration_ref,
        .int_literal,
        .char_literal,
        .float_literal,
        .double_literal,
        .imaginary_literal,
        .string_literal_expr,
        => unreachable, // These should have an entry in value_map.
        .comma_expr => {
            _ = try c.genExpr(data.bin.lhs);
            return c.genExpr(data.bin.rhs);
        },
        .assign_expr => {
            const rhs = try c.genExpr(data.bin.rhs);
            const lhs = try c.genLval(data.bin.lhs);
            try c.builder.addStore(lhs, rhs);
            return rhs;
        },
        .mul_assign_expr => return c.genCompoundAssign(node, .mul),
        .div_assign_expr => return c.genCompoundAssign(node, .div),
        .mod_assign_expr => return c.genCompoundAssign(node, .mod),
        .add_assign_expr => return c.genCompoundAssign(node, .add),
        .sub_assign_expr => return c.genCompoundAssign(node, .sub),
        .shl_assign_expr => return c.genCompoundAssign(node, .bit_shl),
        .shr_assign_expr => return c.genCompoundAssign(node, .bit_shr),
        .bit_and_assign_expr => return c.genCompoundAssign(node, .bit_and),
        .bit_xor_assign_expr => return c.genCompoundAssign(node, .bit_xor),
        .bit_or_assign_expr => return c.genCompoundAssign(node, .bit_or),
        .bit_or_expr => return c.genBinOp(node, .bit_or),
        .bit_xor_expr => return c.genBinOp(node, .bit_xor),
        .bit_and_expr => return c.genBinOp(node, .bit_and),
        .equal_expr => {
            const cmp = try c.genComparison(node, .cmp_eq);
            return c.addUn(.zext, cmp, ty);
        },
        .not_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_ne);
            return c.addUn(.zext, cmp, ty);
        },
        .less_than_expr => {
            const cmp = try c.genComparison(node, .cmp_lt);
            return c.addUn(.zext, cmp, ty);
        },
        .less_than_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_lte);
            return c.addUn(.zext, cmp, ty);
        },
        .greater_than_expr => {
            const cmp = try c.genComparison(node, .cmp_gt);
            return c.addUn(.zext, cmp, ty);
        },
        .greater_than_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_gte);
            return c.addUn(.zext, cmp, ty);
        },
        .shl_expr => return c.genBinOp(node, .bit_shl),
        .shr_expr => return c.genBinOp(node, .bit_shr),
        .add_expr => {
            if (ty.isPtr()) {
                const lhs_ty = c.node_ty[@enumToInt(data.bin.lhs)];
                if (lhs_ty.isPtr()) {
                    const ptr = try c.genExpr(data.bin.lhs);
                    const offset = try c.genExpr(data.bin.rhs);
                    const offset_ty = c.node_ty[@enumToInt(data.bin.rhs)];
                    return c.genPtrArithmetic(ptr, offset, offset_ty, ty);
                } else {
                    const offset = try c.genExpr(data.bin.lhs);
                    const ptr = try c.genExpr(data.bin.rhs);
                    const offset_ty = lhs_ty;
                    return c.genPtrArithmetic(ptr, offset, offset_ty, ty);
                }
            }
            return c.genBinOp(node, .add);
        },
        .sub_expr => {
            if (ty.isPtr()) {
                const ptr = try c.genExpr(data.bin.lhs);
                const offset = try c.genExpr(data.bin.rhs);
                const offset_ty = c.node_ty[@enumToInt(data.bin.rhs)];
                return c.genPtrArithmetic(ptr, offset, offset_ty, ty);
            }
            return c.genBinOp(node, .sub);
        },
        .mul_expr => return c.genBinOp(node, .mul),
        .div_expr => return c.genBinOp(node, .div),
        .mod_expr => return c.genBinOp(node, .mod),
        .addr_of_expr => return try c.genLval(data.un),
        .deref_expr => {
            const un_data = c.node_data[@enumToInt(data.un)];
            if (c.node_tag[@enumToInt(data.un)] == .implicit_cast and un_data.cast.kind == .function_to_pointer) {
                return c.genExpr(data.un);
            }
            const operand = try c.genLval(data.un);
            return c.addUn(.load, operand, ty);
        },
        .plus_expr => return c.genExpr(data.un),
        .negate_expr => {
            const zero = try c.builder.addConstant(Value.int(0), try c.genType(ty));
            const operand = try c.genExpr(data.un);
            return c.addBin(.sub, zero, operand, ty);
        },
        .bit_not_expr => {
            const operand = try c.genExpr(data.un);
            return c.addUn(.bit_not, operand, ty);
        },
        .bool_not_expr => {
            const zero = try c.builder.addConstant(Value.int(0), try c.genType(ty));
            const operand = try c.genExpr(data.un);
            return c.addBin(.cmp_ne, zero, operand, ty);
        },
        .pre_inc_expr => {
            const operand = try c.genExpr(data.un);
            const val = try c.addUn(.load, operand, ty);
            const one = try c.builder.addConstant(Value.int(1), try c.genType(ty));
            const plus_one = try c.addBin(.add, val, one, ty);
            try c.builder.addStore(operand, plus_one);
            return plus_one;
        },
        .pre_dec_expr => {
            const operand = try c.genExpr(data.un);
            const val = try c.addUn(.load, operand, ty);
            const one = try c.builder.addConstant(Value.int(1), try c.genType(ty));
            const plus_one = try c.addBin(.sub, val, one, ty);
            try c.builder.addStore(operand, plus_one);
            return plus_one;
        },
        .post_inc_expr => {
            const operand = try c.genExpr(data.un);
            const val = try c.addUn(.load, operand, ty);
            const one = try c.builder.addConstant(Value.int(1), try c.genType(ty));
            const plus_one = try c.addBin(.add, val, one, ty);
            try c.builder.addStore(operand, plus_one);
            return val;
        },
        .post_dec_expr => {
            const operand = try c.genExpr(data.un);
            const val = try c.addUn(.load, operand, ty);
            const one = try c.builder.addConstant(Value.int(1), try c.genType(ty));
            const plus_one = try c.addBin(.sub, val, one, ty);
            try c.builder.addStore(operand, plus_one);
            return val;
        },
        .paren_expr => return c.genExpr(data.un),
        .decl_ref_expr => unreachable, // Lval expression.
        .explicit_cast, .implicit_cast => switch (data.cast.kind) {
            .no_op => return c.genExpr(data.cast.operand),
            .to_void => unreachable, // Not an expression.
            .lval_to_rval => {
                const operand = try c.genLval(data.cast.operand);
                return c.addUn(.load, operand, ty);
            },
            .function_to_pointer, .array_to_pointer => {
                return c.genLval(data.cast.operand);
            },
            .int_cast => {
                const operand = try c.genExpr(data.cast.operand);
                const src_ty = c.node_ty[@enumToInt(data.cast.operand)];
                const src_bits = src_ty.bitSizeof(c.comp).?;
                const dest_bits = ty.bitSizeof(c.comp).?;
                if (src_bits == dest_bits) {
                    return operand;
                } else if (src_bits < dest_bits) {
                    if (src_ty.isUnsignedInt(c.comp))
                        return c.addUn(.zext, operand, ty)
                    else
                        return c.addUn(.sext, operand, ty);
                } else {
                    return c.addUn(.trunc, operand, ty);
                }
            },
            .bool_to_int => {
                const operand = try c.genExpr(data.cast.operand);
                return c.addUn(.zext, operand, ty);
            },
            .pointer_to_bool, .int_to_bool, .float_to_bool => {
                const lhs = try c.genExpr(data.cast.operand);
                const rhs = try c.builder.addConstant(Value.int(0), try c.genType(c.node_ty[@enumToInt(node)]));
                return c.builder.addInst(.cmp_ne, .{ .bin = .{ .lhs = lhs, .rhs = rhs } }, .i1);
            },
            .bitcast,
            .pointer_to_int,
            .bool_to_float,
            .bool_to_pointer,
            .int_to_float,
            .complex_int_to_complex_float,
            .int_to_pointer,
            .float_to_int,
            .complex_float_to_complex_int,
            .complex_int_cast,
            .complex_int_to_real,
            .real_to_complex_int,
            .float_cast,
            .complex_float_cast,
            .complex_float_to_real,
            .real_to_complex_float,
            .null_to_pointer,
            .union_cast,
            .vector_splat,
            => return c.comp.diag.fatalNoSrc("TODO CodeGen gen CastKind {}\n", .{data.cast.kind}),
        },
        .binary_cond_expr => {
            const cond = try c.genExpr(data.if3.cond);
            const then = then: {
                const old_cond_dummy_ref = c.cond_dummy_ref;
                defer c.cond_dummy_ref = old_cond_dummy_ref;
                c.cond_dummy_ref = cond;

                break :then try c.genExpr(c.tree.data[data.if3.body]);
            };
            const @"else" = try c.genExpr(c.tree.data[data.if3.body + 1]);

            const branch = try c.builder.arena.allocator().create(Ir.Inst.Branch);
            branch.* = .{ .cond = cond, .then = then, .@"else" = @"else" };
            // TODO can't use select here
            return c.builder.addInst(.select, .{ .branch = branch }, try c.genType(ty));
        },
        .cond_dummy_expr => return c.cond_dummy_ref,
        .cond_expr => {
            const cond = try c.genExpr(data.if3.cond);
            const then = try c.genExpr(c.tree.data[data.if3.body]);
            const @"else" = try c.genExpr(c.tree.data[data.if3.body + 1]);

            const branch = try c.builder.arena.allocator().create(Ir.Inst.Branch);
            branch.* = .{ .cond = cond, .then = then, .@"else" = @"else" };
            // TODO can't use select here
            return c.builder.addInst(.select, .{ .branch = branch }, try c.genType(ty));
        },
        .call_expr_one => if (data.bin.rhs == .none) {
            return c.genCall(data.bin.lhs, &.{}, ty);
        } else {
            return c.genCall(data.bin.lhs, &.{data.bin.rhs}, ty);
        },
        .call_expr => {
            return c.genCall(c.tree.data[data.range.start], c.tree.data[data.range.start + 1 .. data.range.end], ty);
        },
        .bool_or_expr,
        .bool_and_expr,
        .addr_of_label,
        .imag_expr,
        .real_expr,
        .array_access_expr,
        .builtin_call_expr_one,
        .builtin_call_expr,
        .member_access_expr,
        .member_access_ptr_expr,
        .sizeof_expr,
        .alignof_expr,
        .generic_expr_one,
        .generic_expr,
        .generic_association_expr,
        .generic_default_expr,
        .builtin_choose_expr,
        .stmt_expr,
        .array_init_expr_two,
        .array_init_expr,
        .struct_init_expr_two,
        .struct_init_expr,
        .union_init_expr,
        .compound_literal_expr,
        .array_filler_expr,
        .default_init_expr,
        => return c.comp.diag.fatalNoSrc("TODO CodeGen.genExpr {}\n", .{c.node_tag[@enumToInt(node)]}),
        else => unreachable, // Not an expression.
    }
}

fn genLval(c: *CodeGen, node: NodeIndex) Error!Ir.Ref {
    std.debug.assert(node != .none);
    assert(Tree.isLval(c.tree.nodes, c.tree.data, c.tree.value_map, node));
    const data = c.node_data[@enumToInt(node)];
    switch (c.node_tag[@enumToInt(node)]) {
        .string_literal_expr => {
            const val = c.tree.value_map.get(node).?.data.bytes;

            // TODO generate anonymous global
            const name = try std.fmt.allocPrintZ(c.builder.arena.allocator(), "\"{}\"", .{std.fmt.fmtSliceEscapeLower(val)});
            return c.builder.addInst(.symbol, .{ .label = name }, .ptr);
        },
        .paren_expr => return c.genLval(data.un),
        .decl_ref_expr => {
            const slice = c.tree.tokSlice(data.decl_ref);
            const name = try c.comp.intern(slice);
            var i = c.symbols.items.len;
            while (i > 0) {
                i -= 1;
                if (c.symbols.items[i].name == name) {
                    return c.symbols.items[i].val;
                }
            }

            const duped_name = try c.builder.arena.allocator().dupeZ(u8, slice);
            return c.builder.addInst(.symbol, .{ .label = duped_name }, .ptr);
        },
        .deref_expr => return c.genExpr(data.un),
        else => return c.comp.diag.fatalNoSrc("TODO CodeGen.genLval {}\n", .{c.node_tag[@enumToInt(node)]}),
    }
}

fn genBoolExpr(c: *CodeGen, base: NodeIndex) Error!void {
    var node = base;
    while (true) switch (c.node_tag[@enumToInt(node)]) {
        .paren_expr => {
            node = c.node_data[@enumToInt(node)].un;
        },
        else => break,
    };

    const data = c.node_data[@enumToInt(node)];
    switch (c.node_tag[@enumToInt(node)]) {
        .bool_or_expr => {
            if (c.tree.value_map.get(data.bin.lhs)) |lhs| {
                const cond = lhs.getBool();
                if (cond) {
                    return c.builder.addJump(c.builder.branch.?.true_label);
                }
                return c.genBoolExpr(data.bin.rhs);
            }
            const old_bool_ctx = c.builder.branch;
            defer c.builder.branch = old_bool_ctx;

            const false_label = try c.builder.addLabel("bool_or.false");
            c.builder.branch = .{
                .true_label = c.builder.branch.?.true_label,
                .false_label = false_label,
            };
            try c.genBoolExpr(data.bin.lhs);
            try c.builder.body.append(c.builder.gpa, false_label);
            c.builder.branch = .{
                .true_label = c.builder.branch.?.true_label,
                .false_label = old_bool_ctx.?.false_label,
            };
            return c.genBoolExpr(data.bin.rhs);
        },
        .bool_and_expr => {
            if (c.tree.value_map.get(data.bin.lhs)) |lhs| {
                const cond = lhs.getBool();
                if (!cond) {
                    return c.builder.addJump(c.builder.branch.?.false_label);
                }
                return c.genBoolExpr(data.bin.rhs);
            }
            const old_bool_ctx = c.builder.branch;
            defer c.builder.branch = old_bool_ctx;

            const true_label = try c.builder.addLabel("bool_and.true");
            c.builder.branch = .{
                .true_label = true_label,
                .false_label = c.builder.branch.?.false_label,
            };
            try c.genBoolExpr(data.bin.lhs);
            try c.builder.body.append(c.builder.gpa, true_label);
            c.builder.branch = .{
                .true_label = old_bool_ctx.?.true_label,
                .false_label = c.builder.branch.?.false_label,
            };
            return c.genBoolExpr(data.bin.rhs);
        },
        .bool_not_expr => {
            const old_bool_ctx = c.builder.branch;
            defer c.builder.branch = old_bool_ctx;

            c.builder.branch = .{
                .true_label = c.builder.branch.?.false_label,
                .false_label = c.builder.branch.?.true_label,
            };
            return c.genBoolExpr(data.un);
        },
        .equal_expr => {
            const cmp = try c.genComparison(node, .cmp_eq);
            return c.builder.addBranch(cmp);
        },
        .not_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_ne);
            return c.builder.addBranch(cmp);
        },
        .less_than_expr => {
            const cmp = try c.genComparison(node, .cmp_lt);
            return c.builder.addBranch(cmp);
        },
        .less_than_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_lte);
            return c.builder.addBranch(cmp);
        },
        .greater_than_expr => {
            const cmp = try c.genComparison(node, .cmp_gt);
            return c.builder.addBranch(cmp);
        },
        .greater_than_equal_expr => {
            const cmp = try c.genComparison(node, .cmp_gte);
            return c.builder.addBranch(cmp);
        },
        .explicit_cast, .implicit_cast => switch (data.cast.kind) {
            .bool_to_int => {
                const operand = try c.genExpr(data.cast.operand);
                return c.builder.addBranch(operand);
            },
            else => {},
        },
        else => {},
    }

    // Assume int operand.
    const lhs = try c.genExpr(node);
    const rhs = try c.builder.addConstant(Value.int(0), try c.genType(c.node_ty[@enumToInt(node)]));
    const cmp = try c.builder.addInst(.cmp_ne, .{ .bin = .{ .lhs = lhs, .rhs = rhs } }, .i1);
    try c.builder.body.append(c.comp.gpa, cmp);
    try c.builder.addBranch(cmp);
}

fn genCall(c: *CodeGen, fn_node: NodeIndex, arg_nodes: []const NodeIndex, ty: Type) Error!Ir.Ref {
    // Detect direct calls.
    const fn_ref = blk: {
        const data = c.node_data[@enumToInt(fn_node)];
        if (c.node_tag[@enumToInt(fn_node)] != .implicit_cast or data.cast.kind != .function_to_pointer) {
            break :blk try c.genExpr(fn_node);
        }

        var cur = @enumToInt(data.cast.operand);
        while (true) switch (c.node_tag[cur]) {
            .paren_expr, .addr_of_expr, .deref_expr => {
                cur = @enumToInt(c.node_data[cur].un);
            },
            .implicit_cast => {
                const cast = c.node_data[cur].cast;
                if (cast.kind != .function_to_pointer) {
                    break :blk try c.genExpr(fn_node);
                }
                cur = @enumToInt(cast.operand);
            },
            .decl_ref_expr => {
                const slice = c.tree.tokSlice(c.node_data[cur].decl_ref);
                const name = try c.comp.intern(slice);
                var i = c.symbols.items.len;
                while (i > 0) {
                    i -= 1;
                    if (c.symbols.items[i].name == name) {
                        break :blk try c.genExpr(fn_node);
                    }
                }

                break :blk try c.builder.addInst(.symbol, .{ .label = try c.builder.arena.allocator().dupeZ(u8, slice) }, .func);
            },
            else => break :blk try c.genExpr(fn_node),
        };
    };

    const args = try c.builder.arena.allocator().alloc(Ir.Ref, arg_nodes.len);
    for (arg_nodes) |node, i| {
        // TODO handle calling convention here
        args[i] = try c.genExpr(node);
    }
    // TODO handle variadic call
    const call = try c.builder.arena.allocator().create(Ir.Inst.Call);
    call.* = .{
        .func = fn_ref,
        .args_len = @intCast(u32, args.len),
        .args_ptr = args.ptr,
    };
    return c.builder.addInst(.call, .{ .call = call }, try c.genType(ty));
}

fn genCompoundAssign(c: *CodeGen, node: NodeIndex, tag: Ir.Inst.Tag) Error!Ir.Ref {
    const bin = c.node_data[@enumToInt(node)].bin;
    const ty = c.node_ty[@enumToInt(node)];
    const rhs = try c.genExpr(bin.rhs);
    const lhs = try c.genLval(bin.lhs);
    const res = try c.addBin(tag, lhs, rhs, ty);
    try c.builder.addStore(lhs, res);
    return res;
}

fn genBinOp(c: *CodeGen, node: NodeIndex, tag: Ir.Inst.Tag) Error!Ir.Ref {
    const bin = c.node_data[@enumToInt(node)].bin;
    const ty = c.node_ty[@enumToInt(node)];
    const lhs = try c.genExpr(bin.lhs);
    const rhs = try c.genExpr(bin.rhs);
    return c.addBin(tag, lhs, rhs, ty);
}

fn genComparison(c: *CodeGen, node: NodeIndex, tag: Ir.Inst.Tag) Error!Ir.Ref {
    const bin = c.node_data[@enumToInt(node)].bin;
    const lhs = try c.genExpr(bin.lhs);
    const rhs = try c.genExpr(bin.rhs);

    return c.builder.addInst(tag, .{ .bin = .{ .lhs = lhs, .rhs = rhs } }, .i1);
}

fn genPtrArithmetic(c: *CodeGen, ptr: Ir.Ref, offset: Ir.Ref, offset_ty: Type, ty: Type) Error!Ir.Ref {
    // TODO consider adding a getelemptr instruction
    const size = ty.elemType().sizeof(c.comp).?;
    if (size == 1) {
        return c.builder.addInst(.add, .{ .bin = .{ .lhs = ptr, .rhs = offset } }, try c.genType(ty));
    }

    const size_inst = try c.builder.addConstant(Value.int(size), try c.genType(offset_ty));
    const offset_inst = try c.addBin(.mul, offset, size_inst, offset_ty);
    return c.addBin(.add, ptr, offset_inst, offset_ty);
}

fn genVar(c: *CodeGen, decl: NodeIndex) Error!void {
    _ = decl;
    return c.comp.diag.fatalNoSrc("TODO CodeGen.genVar\n", .{});
}