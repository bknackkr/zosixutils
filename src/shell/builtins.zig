//! Shell builtins and their current-environment effects.
const std = @import("std");
const process = @import("process.zig");
const alias = @import("../commands/alias.zig");
const Allocator = std.mem.Allocator;
const Outcome = @import("runtime.zig").Outcome;

pub const Kind = enum {
    colon,
    dot,
    break_loop,
    continue_loop,
    exec,
    exit,
    export_vars,
    readonly_vars,
    return_fn,
    set,
    shift,
    unset,
    cd,
    read,
    command,
    alias,
    unalias,
    kill,
    wait,

    pub fn special(self: Kind) bool {
        return switch (self) {
            .colon, .dot, .break_loop, .continue_loop, .exec, .exit, .export_vars, .readonly_vars, .return_fn, .set, .shift, .unset => true,
            else => false,
        };
    }
};

pub fn find(name: []const u8) ?Kind {
    const names = .{
        .{ ":", Kind.colon },                .{ ".", Kind.dot },                  .{ "break", Kind.break_loop },
        .{ "continue", Kind.continue_loop }, .{ "exec", Kind.exec },              .{ "exit", Kind.exit },
        .{ "export", Kind.export_vars },     .{ "readonly", Kind.readonly_vars }, .{ "return", Kind.return_fn },
        .{ "set", Kind.set },                .{ "shift", Kind.shift },            .{ "unset", Kind.unset },
        .{ "cd", Kind.cd },                  .{ "read", Kind.read },              .{ "command", Kind.command },
        .{ "alias", Kind.alias },            .{ "unalias", Kind.unalias },        .{ "kill", Kind.kill },
        .{ "wait", Kind.wait },
    };
    inline for (names) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn number(arg: []const u8) !usize {
    if (arg.len == 0) return error.InvalidOperand;
    for (arg) |c| if (!std.ascii.isDigit(c)) return error.InvalidOperand;
    return std.fmt.parseUnsigned(usize, arg, 10) catch error.InvalidOperand;
}

fn statusArg(args: []const [:0]const u8, default: u8) !u8 {
    if (args.len > 1) return error.InvalidOperand;
    if (args.len == 0) return default;
    const value = std.fmt.parseInt(i64, args[0], 10) catch return error.InvalidOperand;
    return @truncate(@as(u64, @bitCast(value)));
}

fn quoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}

fn declarations(ctx: anytype, args: []const [:0]const u8, kind: Kind) !Outcome {
    const is_export = kind == .export_vars;
    var index: usize = 0;
    var print = args.len == 0;
    if (index < args.len and std.mem.eql(u8, args[index], "-p")) {
        print = true;
        index += 1;
    }
    if (index < args.len and std.mem.eql(u8, args[index], "--")) index += 1;
    if (print) {
        if (index != args.len) return error.InvalidOperand;
        const io = std.Io.Threaded.global_single_threaded.io();
        var buffer: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(io, &buffer);
        const writer = &output.interface;
        var iter = ctx.vars.iterator();
        while (iter.next()) |entry| {
            const variable = entry.value_ptr.*;
            if (if (is_export) !variable.exported else !variable.readonly) continue;
            try writer.print("{s} {s}", .{ if (is_export) "export" else "readonly", entry.key_ptr.* });
            if (variable.value) |value| {
                try writer.writeByte('=');
                try quoted(writer, value);
            }
            try writer.writeByte('\n');
        }
        try output.flush();
        return .{ .status = 0 };
    }
    for (args[index..]) |arg| {
        const eq = std.mem.findScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        if (!validName(name)) return error.InvalidOperand;
        try ctx.setVariable(name, if (eq) |pos| arg[pos + 1 ..] else null, is_export, !is_export);
    }
    return .{ .status = 0 };
}

fn setBuiltin(ctx: anytype, allocator: Allocator, args: []const [:0]const u8) !Outcome {
    var i: usize = 0;
    var replace = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            replace = true;
            break;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        for (arg[1..]) |c| {
            if (c != 'f') return error.InvalidOperand;
            ctx.no_glob = arg[0] == '-';
        }
    }
    if (i < args.len or replace) {
        const values = try allocator.alloc([]const u8, args.len - i);
        defer allocator.free(values);
        for (args[i..], 0..) |value, j| values[j] = value;
        try ctx.replacePositionals(values);
    } else if (args.len == 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buffer: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(io, &buffer);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        var iter = ctx.vars.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.value != null) try names.append(allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for (names.items) |name| {
            const value = ctx.vars.get(name).?.value.?;
            try output.interface.print("{s}=", .{name});
            try quoted(&output.interface, value);
            try output.interface.writeByte('\n');
        }
        try output.flush();
    }
    return .{ .status = 0 };
}

fn unsetBuiltin(ctx: anytype, args: []const [:0]const u8) !Outcome {
    var i: usize = 0;
    var functions = false;
    var variables = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| switch (c) {
            'f' => functions = true,
            'v' => variables = true,
            else => return error.InvalidOperand,
        };
    }
    if (functions and variables) return error.InvalidOperand;
    for (args[i..]) |name| {
        if (!validName(name)) return error.InvalidOperand;
        if (functions) ctx.unsetFunction(name) else try ctx.unsetVariable(name);
    }
    return .{ .status = 0 };
}

fn commandBuiltin(ctx: anytype, allocator: Allocator, args: []const [:0]const u8) !Outcome {
    var i: usize = 0;
    var default_path = false;
    var query: u8 = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| switch (c) {
            'p' => default_path = true,
            'v', 'V' => query = c,
            else => return error.InvalidOperand,
        };
    }
    if (query == 0) {
        if (i == args.len) return .{ .status = 0 };
        return ctx.executeArgs(allocator, args[i..], true, default_path, false);
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    const writer = &output.interface;
    var result: u8 = 0;
    for (args[i..]) |name| {
        if (ctx.aliases.lookup(name)) |value| {
            if (query == 'V') try writer.print("{s} is an alias for ", .{name}) else try writer.print("alias {s}=", .{name});
            try quoted(writer, value);
            try writer.writeByte('\n');
            continue;
        }
        const found = try ctx.lookup(allocator, name, false, default_path);
        switch (found) {
            .builtin => {
                if (query == 'V') try writer.print("{s} is a shell builtin\n", .{name}) else try writer.print("{s}\n", .{name});
            },
            .function => {
                if (query == 'V') try writer.print("{s} is a function\n", .{name}) else try writer.print("{s}\n", .{name});
            },
            .external => |path| {
                defer allocator.free(path);
                if (query == 'V') try writer.print("{s} is {s}\n", .{ name, path }) else try writer.print("{s}\n", .{path});
            },
            .inaccessible, .missing => result = 1,
        }
    }
    try output.flush();
    return .{ .status = result };
}

const ReadByte = struct { byte: u8, quoted: bool };
fn ifsWhite(c: ReadByte, ifs: []const u8) bool {
    return !c.quoted and (c.byte == ' ' or c.byte == '\t' or c.byte == '\n') and std.mem.findScalar(u8, ifs, c.byte) != null;
}
fn ifsDelim(c: ReadByte, ifs: []const u8) bool {
    return !c.quoted and std.mem.findScalar(u8, ifs, c.byte) != null;
}

fn readBuiltin(ctx: anytype, allocator: Allocator, args: []const [:0]const u8) !Outcome {
    var i: usize = 0;
    var raw = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| if (c == 'r') {
            raw = true;
        } else return error.InvalidOperand;
    }
    const names = args[i..];
    if (names.len == 0) return error.InvalidOperand;
    for (names) |name| if (!validName(name)) return error.InvalidOperand;
    var line: std.ArrayList(ReadByte) = .empty;
    defer line.deinit(allocator);
    var escaped = false;
    var terminated = false;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = blk: {
            while (true) break :blk process.interactiveRead(0, &byte) catch |err| switch (err) {
                error.ChildChanged => {
                    if (@hasDecl(@TypeOf(ctx.*), "collectChildren")) ctx.collectChildren();
                    continue;
                },
                else => return err,
            };
        };
        if (n == 0) break;
        const c = byte[0];
        if (!raw and !escaped and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '\n') {
            if (escaped) {
                escaped = false;
                if (ctx.interactive and process.terminal(0)) try process.write(2, ctx.parameter("PS2") orelse "> ");
                continue;
            }
            terminated = true;
            break;
        }
        try line.append(allocator, .{ .byte = c, .quoted = escaped });
        escaped = false;
    }
    if (escaped) try line.append(allocator, .{ .byte = '\\', .quoted = true });
    // A destination variable may itself be IFS.
    const ifs = try allocator.dupe(u8, ctx.parameter("IFS") orelse " \t\n");
    defer allocator.free(ifs);
    var pos: usize = 0;
    for (names, 0..) |name, field| {
        while (pos < line.items.len and ifsWhite(line.items[pos], ifs)) : (pos += 1) {}
        const start = pos;
        var end: usize = pos;
        if (field + 1 == names.len) {
            end = line.items.len;
            while (end > start and ifsWhite(line.items[end - 1], ifs)) : (end -= 1) {}
            pos = line.items.len;
        } else {
            while (pos < line.items.len and !ifsDelim(line.items[pos], ifs)) : (pos += 1) {}
            end = pos;
            if (pos < line.items.len) {
                if (ifsWhite(line.items[pos], ifs)) {
                    while (pos < line.items.len and ifsWhite(line.items[pos], ifs)) : (pos += 1) {}
                    if (pos < line.items.len and ifsDelim(line.items[pos], ifs)) pos += 1;
                } else pos += 1;
                while (pos < line.items.len and ifsWhite(line.items[pos], ifs)) : (pos += 1) {}
            }
        }
        const value = try allocator.alloc(u8, end - start);
        defer allocator.free(value);
        for (line.items[start..end], 0..) |item, j| value[j] = item.byte;
        try ctx.setVariable(name, value, false, false);
    }
    return .{ .status = if (terminated) 0 else 1 };
}

fn cwd(allocator: Allocator) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &buffer);
    return allocator.dupe(u8, buffer[0..n]);
}

// A logical .. may cancel a component only if that component names a directory.
fn logicalParentsExist(allocator: Allocator, path: []const u8) !bool {
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    try prefix.append(allocator, '/');
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            const name = try allocator.dupeSentinel(u8, prefix.items, 0);
            defer allocator.free(name);
            var stat: process.linux.Statx = undefined;
            if (process.linux.errno(process.linux.statx(process.linux.AT.FDCWD, name, 0, .{ .TYPE = true }, &stat)) != .SUCCESS or !process.linux.S.ISDIR(stat.mode)) return false;
            const slash = std.mem.findScalarLast(u8, prefix.items, '/').?;
            prefix.shrinkRetainingCapacity(if (slash == 0) 1 else slash);
            continue;
        }
        if (prefix.items[prefix.items.len - 1] != '/') try prefix.append(allocator, '/');
        try prefix.appendSlice(allocator, part);
    }
    return true;
}

fn cdBuiltin(ctx: anytype, allocator: Allocator, args: []const [:0]const u8) !Outcome {
    var i: usize = 0;
    var physical = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| switch (c) {
            'L' => physical = false,
            'P' => physical = true,
            else => return error.InvalidOperand,
        };
    }
    if (args.len - i > 1) return error.InvalidOperand;
    var operand: []const u8 = if (i == args.len) ctx.parameter("HOME") orelse return error.InvalidOperand else args[i];
    const dash = std.mem.eql(u8, operand, "-");
    if (dash) operand = ctx.parameter("OLDPWD") orelse return error.InvalidOperand;
    if (operand.len == 0) return error.InvalidOperand;
    const physical_old = try cwd(allocator);
    defer allocator.free(physical_old);
    const pwd = ctx.parameter("PWD") orelse "";
    var real_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = if (pwd.len != 0 and pwd[0] == '/') std.Io.Dir.cwd().realPathFile(std.Io.Threaded.global_single_threaded.io(), pwd, &real_buffer) catch 0 else 0;
    const old = try allocator.dupe(u8, if (real_len != 0 and std.mem.eql(u8, real_buffer[0..real_len], physical_old)) pwd else physical_old);
    defer allocator.free(old);
    const use_cdpath = operand[0] != '/' and !std.mem.eql(u8, operand, ".") and !std.mem.eql(u8, operand, "..") and !std.mem.startsWith(u8, operand, "./") and !std.mem.startsWith(u8, operand, "../");
    var paths = std.mem.splitScalar(u8, if (use_cdpath) ctx.parameter("CDPATH") orelse "" else "", ':');
    var fallback = false;
    while (true) {
        const component = paths.next() orelse if (!fallback) blk: {
            fallback = true;
            break :blk "";
        } else break;
        const candidate = if (component.len == 0) try allocator.dupe(u8, operand) else try std.fs.path.join(allocator, &.{ component, operand });
        defer allocator.free(candidate);
        if (use_cdpath and !fallback) {
            const candidate_z = try allocator.dupeSentinel(u8, candidate, 0);
            defer allocator.free(candidate_z);
            var stat: process.linux.Statx = undefined;
            if (process.linux.errno(process.linux.statx(process.linux.AT.FDCWD, candidate_z, 0, .{ .TYPE = true }, &stat)) != .SUCCESS or !process.linux.S.ISDIR(stat.mode)) continue;
        }
        if (!physical) {
            const raw_path = if (candidate[0] == '/') try allocator.dupe(u8, candidate) else try std.fs.path.join(allocator, &.{ old, candidate });
            defer allocator.free(raw_path);
            if (!try logicalParentsExist(allocator, raw_path)) continue;
        }
        const logical = if (!physical and old.len != 0 and old[0] == '/') try std.fs.path.resolveAlloc(allocator, &.{ old, candidate }) else null;
        defer if (logical) |path| allocator.free(path);
        const target = try allocator.dupeSentinel(u8, logical orelse candidate, 0);
        defer allocator.free(target);
        if (process.linux.errno(process.linux.chdir(target)) != .SUCCESS) continue;
        const new = if (logical) |path| try allocator.dupe(u8, path) else try cwd(allocator);
        defer allocator.free(new);
        try ctx.setVariable("OLDPWD", old, true, false);
        try ctx.setVariable("PWD", new, true, false);
        if (dash or component.len != 0) {
            try process.write(1, new);
            try process.write(1, "\n");
        }
        return .{ .status = 0 };
    }
    return error.ChangeDirectory;
}

pub fn run(ctx: anytype, allocator: Allocator, kind: Kind, args: []const [:0]const u8) anyerror!Outcome {
    switch (kind) {
        .colon => return .{ .status = 0 },
        .dot => {
            if (args.len == 0) return error.InvalidOperand;
            return ctx.sourceFile(allocator, args[0], args[1..]);
        },
        .break_loop, .continue_loop => {
            if (args.len > 1) return error.InvalidOperand;
            const levels = if (args.len == 0) 1 else try number(args[0]);
            if (levels == 0) return error.InvalidOperand;
            if (ctx.loop_depth == 0) return .{ .status = 0 };
            return .{ .status = 0, .flow = if (kind == .break_loop) .break_loop else .continue_loop, .levels = @min(levels, ctx.loop_depth) };
        },
        .exit => return .{ .status = try statusArg(args, ctx.last_status), .flow = .exit },
        .return_fn => {
            if (ctx.function_depth == 0 and ctx.source_depth == 0) return error.InvalidOperand;
            return .{ .status = try statusArg(args, ctx.last_status), .flow = .return_fn };
        },
        .exec => {
            if (args.len == 0) return .{ .status = 0, .retain_redirections = true };
            const operands = if (std.mem.eql(u8, args[0], "--")) args[1..] else args;
            if (operands.len == 0) return .{ .status = 0, .retain_redirections = true };
            return ctx.executeArgs(allocator, operands, false, false, true);
        },
        .export_vars, .readonly_vars => return declarations(ctx, args, kind),
        .set => return setBuiltin(ctx, allocator, args),
        .shift => {
            if (args.len > 1) return error.InvalidOperand;
            const amount = if (args.len == 0) 1 else try number(args[0]);
            const values = ctx.positionals();
            if (amount > values.len) return error.InvalidOperand;
            try ctx.replacePositionals(values[amount..]);
            return .{ .status = 0 };
        },
        .unset => return unsetBuiltin(ctx, args),
        .cd => return cdBuiltin(ctx, allocator, args),
        .read => return readBuiltin(ctx, allocator, args),
        .command => return commandBuiltin(ctx, allocator, args),
        .kill => return .{ .status = @import("../commands/kill.zig").run(allocator, args) },
        .wait => return .{ .status = try @import("../commands/wait.zig").run(ctx, args) },
        .alias => {
            const io = std.Io.Threaded.global_single_threaded.io();
            var out_buf: [1024]u8 = undefined;
            var err_buf: [1024]u8 = undefined;
            var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
            var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
            return .{ .status = alias.runBuiltin(&ctx.aliases, args, &out.interface, &err.interface) };
        },
        .unalias => {
            var i: usize = 0;
            if (args.len > 0 and std.mem.eql(u8, args[0], "-a")) {
                if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--"))) return error.InvalidOperand;
                ctx.aliases.clear();
                return .{ .status = 0 };
            }
            if (args.len > 0 and std.mem.eql(u8, args[0], "--")) i = 1;
            if (i == args.len) return error.InvalidOperand;
            var status: u8 = 0;
            for (args[i..]) |name| if (!ctx.aliases.remove(name)) {
                try process.write(2, "unalias: ");
                try process.write(2, name);
                try process.write(2, ": alias not found\n");
                status = 1;
            };
            return .{ .status = status };
        },
    }
}

test "sh: builtin names and special status" {
    try std.testing.expectEqual(Kind.dot, find(".").?);
    try std.testing.expect(Kind.dot.special());
    try std.testing.expect(!Kind.command.special());
    try std.testing.expect(find("missing") == null);
    try std.testing.expect(validName("_A1"));
    try std.testing.expect(!validName("1a"));
}

test "sh: stateful builtin operations" {
    const Mock = struct {
        const Variable = struct { value: ?[]const u8, exported: bool, readonly: bool };
        const Lookup = union(enum) { builtin: Kind, function, external: [:0]const u8, inaccessible, missing };
        allocator: Allocator,
        vars: std.StringHashMap(Variable),
        aliases: alias.Table,
        params: std.ArrayList([]const u8) = .empty,
        no_glob: bool = false,
        interactive: bool = false,
        last_status: u8 = 0,
        loop_depth: usize = 0,
        function_depth: usize = 0,
        source_depth: usize = 0,

        fn deinit(self: *@This()) void {
            var it = self.vars.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                if (entry.value_ptr.value) |value| self.allocator.free(value);
            }
            self.vars.deinit();
            self.aliases.deinit();
            for (self.params.items) |p| self.allocator.free(p);
            self.params.deinit(self.allocator);
        }
        fn parameter(self: *@This(), name: []const u8) ?[]const u8 {
            const v = self.vars.get(name) orelse return null;
            return v.value;
        }
        fn positionals(self: *@This()) []const []const u8 {
            return self.params.items;
        }
        fn replacePositionals(self: *@This(), values: []const []const u8) !void {
            var next: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (next.items) |p| self.allocator.free(p);
                next.deinit(self.allocator);
            }
            for (values) |value| {
                const copy = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(copy);
                try next.append(self.allocator, copy);
            }
            for (self.params.items) |p| self.allocator.free(p);
            self.params.deinit(self.allocator);
            self.params = next;
        }
        fn setVariable(self: *@This(), name: []const u8, value: ?[]const u8, exported: bool, readonly: bool) !void {
            if (self.vars.getPtr(name)) |v| {
                if (v.readonly and value != null) return error.ReadOnly;
                if (value) |text| {
                    const copy = try self.allocator.dupe(u8, text);
                    if (v.value) |old| self.allocator.free(old);
                    v.value = copy;
                }
                v.exported = v.exported or exported;
                v.readonly = v.readonly or readonly;
                return;
            }
            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            const copy = if (value) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (copy) |v| self.allocator.free(v);
            try self.vars.put(key, .{ .value = copy, .exported = exported, .readonly = readonly });
        }
        fn unsetVariable(self: *@This(), name: []const u8) !void {
            if (self.vars.get(name)) |v| if (v.readonly) return error.ReadOnly;
            if (self.vars.fetchRemove(name)) |entry| {
                self.allocator.free(entry.key);
                if (entry.value.value) |v| self.allocator.free(v);
            }
        }
        fn unsetFunction(_: *@This(), _: []const u8) void {}
        fn sourceFile(_: *@This(), _: Allocator, _: [:0]const u8, _: []const [:0]const u8) !Outcome {
            return .{ .status = 0 };
        }
        fn executeArgs(_: *@This(), _: Allocator, _: []const [:0]const u8, _: bool, _: bool, _: bool) !Outcome {
            return .{ .status = 0 };
        }
        fn lookup(_: *@This(), _: Allocator, _: [:0]const u8, _: bool, _: bool) !Lookup {
            return .missing;
        }
        pub fn waitChild(_: *@This(), _: ?process.Pid) !u8 {
            return 127;
        }
    };
    const a = std.testing.allocator;
    var ctx: Mock = .{ .allocator = a, .vars = std.StringHashMap(Mock.Variable).init(a), .aliases = alias.Table.init(a) };
    defer ctx.deinit();
    _ = try run(&ctx, a, .export_vars, &.{"A=one"});
    _ = try run(&ctx, a, .readonly_vars, &.{"A"});
    try std.testing.expectEqualStrings("one", ctx.parameter("A").?);
    try std.testing.expect(ctx.vars.get("A").?.exported and ctx.vars.get("A").?.readonly);
    try std.testing.expectError(error.ReadOnly, run(&ctx, a, .unset, &.{"A"}));
    _ = try run(&ctx, a, .set, &.{ "-f", "--", "one", "two" });
    try std.testing.expect(ctx.no_glob);
    _ = try run(&ctx, a, .shift, &.{});
    try std.testing.expectEqualStrings("two", ctx.positionals()[0]);
    try std.testing.expectError(error.InvalidOperand, run(&ctx, a, .shift, &.{"2"}));
    ctx.loop_depth = 2;
    const jump = try run(&ctx, a, .break_loop, &.{"3"});
    try std.testing.expectEqual(.break_loop, jump.flow);
    try std.testing.expectEqual(2, jump.levels);
    _ = try run(&ctx, a, .alias, &.{"x=value"});
    try std.testing.expectEqualStrings("value", ctx.aliases.lookup("x").?);
    _ = try run(&ctx, a, .unalias, &.{"x"});
    try std.testing.expect(ctx.aliases.lookup("x") == null);

    const saved = try process.save(0, 10);
    defer process.install(saved, 0) catch {};
    const pipe = try process.pipe();
    try process.write(pipe[1], "one\\:two:three::last\nraw\\:data\npartial");
    process.close(pipe[1]);
    try process.install(pipe[0], 0);
    try ctx.setVariable("IFS", ":", false, false);
    try std.testing.expectEqual(0, (try run(&ctx, a, .read, &.{ "X", "Y" })).status);
    try std.testing.expectEqualStrings("one:two", ctx.parameter("X").?);
    try std.testing.expectEqualStrings("three::last", ctx.parameter("Y").?);
    _ = try run(&ctx, a, .read, &.{ "-r", "X", "Y" });
    try std.testing.expectEqualStrings("raw\\", ctx.parameter("X").?);
    try std.testing.expectEqualStrings("data", ctx.parameter("Y").?);
    try std.testing.expectEqual(1, (try run(&ctx, a, .read, &.{"X"})).status);
    try std.testing.expectEqualStrings("partial", ctx.parameter("X").?);
}
