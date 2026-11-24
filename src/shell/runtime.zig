//! Shell state, command execution, and streaming command sources.
const std = @import("std");
const Alias = @import("../commands/alias.zig").Table;
const builtins = @import("builtins.zig");
const expand = @import("expand.zig");
const proc = @import("process.zig");
const redir = @import("redirection.zig");
const syntax = @import("syntax.zig");
const linux = proc.linux;
const Allocator = std.mem.Allocator;
const Node = syntax.Node;
const eq = std.mem.eql;
const max_depth = 128;
const default_path = "/bin:/usr/bin";

pub const Outcome = struct {
    status: u8,
    flow: enum { normal, exit, return_fn, break_loop, continue_loop, fatal } = .normal,
    levels: usize = 1,
    retain_redirections: bool = false,
};

pub const Variable = struct {
    value: ?[]const u8,
    exported: bool,
    readonly: bool,
};

pub const Lookup = union(enum) {
    builtin: builtins.Kind,
    function,
    external: [:0]const u8,
    inaccessible,
    missing,
};

const Function = struct {
    arena: std.heap.ArenaAllocator,
    body: *const Node,
};

const Child = struct { pid: proc.Pid, status: ?u8 = null, completed: u64 = 0 };

const Source = struct {
    rt: *Runtime,
    input: union(enum) { text: []const u8, shared, private: *redir.Hidden },
    prompt: enum { none, primary, secondary } = .none,
    buffer: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn next(context: *anyopaque) anyerror!?u8 {
        const self: *Source = @ptrCast(@alignCast(context));
        return switch (self.input) {
            .text => |*text| blk: {
                if (text.len == 0) break :blk null;
                const c = text.*[0];
                text.* = text.*[1..];
                break :blk c;
            },
            .private => |fd| blk: {
                if (self.start == self.end) {
                    self.end = read_input: {
                        while (true) break :read_input proc.interactiveRead(fd.fd, &self.buffer) catch |err| switch (err) {
                            error.ChildChanged => {
                                self.rt.collectChildren();
                                continue;
                            },
                            else => return err,
                        };
                    };
                    self.start = 0;
                    if (self.end == 0) break :blk null;
                }
                const c = self.buffer[self.start];
                self.start += 1;
                break :blk c;
            },
            .shared => blk: {
                var c: [1]u8 = undefined;
                if (self.prompt != .none) {
                    self.rt.printPrompt(self.prompt == .primary);
                    self.prompt = .none;
                }
                const n = read_input: {
                    while (true) break :read_input proc.interactiveRead(0, &c) catch |err| switch (err) {
                        error.ChildChanged => {
                            self.rt.collectChildren();
                            continue;
                        },
                        else => return err,
                    };
                };
                if (n == 0) break :blk null;
                if (self.rt.interactive and c[0] == '\n') self.prompt = .secondary;
                break :blk c[0];
            },
        };
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    aliases: Alias,
    vars: std.StringHashMap(Variable),
    functions: std.StringHashMap(Function),
    pos: [][]const u8 = &.{},
    zero: []const u8,
    pid: proc.Pid,
    last_status: u8 = 0,
    last_async: ?proc.Pid = null,
    children: std.ArrayList(Child) = .empty,
    completed_serial: u64 = 0,
    direct_exec: bool = false,
    substitution_status: ?u8 = null,
    no_glob: bool = false,
    interactive: bool = false,
    signals: *const proc.Signals,
    descriptors: redir.Descriptors = .{},
    loop_depth: usize = 0,
    function_depth: usize = 0,
    source_depth: usize = 0,
    eval_depth: usize = 0,
    parameter_buf: [32]u8 = undefined,

    pub fn init(allocator: Allocator, zero: []const u8, args: []const []const u8, envp: proc.Vector, signals: *const proc.Signals) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .aliases = .init(allocator),
            .vars = .init(allocator),
            .functions = .init(allocator),
            .zero = zero,
            .pid = linux.getpid(),
            .signals = signals,
        };
        errdefer self.deinit();
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const bytes = std.mem.span(entry);
            const split = std.mem.findScalar(u8, bytes, '=') orelse continue;
            if (split != 0) try self.setVariable(bytes[0..split], bytes[split + 1 ..], true, false);
        }
        try self.setVariable("IFS", " \t\n", false, false);
        try self.replacePositionals(args);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.freePositionals(self.pos);
        self.aliases.deinit();
        var vars = self.vars.iterator();
        while (vars.next()) |entry| self.freeVariable(entry.key_ptr.*, entry.value_ptr.*);
        self.vars.deinit();
        var functions = self.functions.iterator();
        while (functions.next()) |entry| {
            entry.value_ptr.arena.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();
        self.children.deinit(self.allocator);
    }

    fn freeVariable(self: *Runtime, name: []const u8, v: Variable) void {
        self.allocator.free(name);
        if (v.value) |value| self.allocator.free(value);
    }

    pub fn setVariable(self: *Runtime, name: []const u8, value: ?[]const u8, exported: bool, readonly: bool) !void {
        if (value) |bytes| if (std.mem.findScalar(u8, bytes, 0) != null) return error.InvalidByte;
        if (self.vars.getPtr(name)) |v| {
            if (value) |bytes| {
                if (v.readonly) return error.ReadonlyVariable;
                const copy = try self.allocator.dupe(u8, bytes);
                if (v.value) |old| self.allocator.free(old);
                v.value = copy;
            }
            v.exported = v.exported or exported;
            v.readonly = v.readonly or readonly;
            return;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const copy = if (value) |bytes| try self.allocator.dupe(u8, bytes) else null;
        errdefer if (copy) |bytes| self.allocator.free(bytes);
        try self.vars.put(key, .{ .value = copy, .exported = exported, .readonly = readonly });
    }

    pub fn assignParameter(self: *Runtime, name: []const u8, value: []const u8) !void {
        if (!validName(name)) return error.InvalidAssignment;
        try self.setVariable(name, value, false, false);
    }

    pub fn unsetVariable(self: *Runtime, name: []const u8) !void {
        if (self.vars.get(name)) |v| if (v.readonly) return error.ReadonlyVariable;
        if (self.vars.fetchRemove(name)) |removed| self.freeVariable(removed.key, removed.value);
    }

    pub fn parameter(self: *Runtime, name: []const u8) ?[]const u8 {
        if (eq(u8, name, "0")) return self.zero;
        if (eq(u8, name, "-")) return if (self.interactive) (if (self.no_glob) "fi" else "i") else (if (self.no_glob) "f" else "");
        if (eq(u8, name, "#")) return std.fmt.bufPrint(&self.parameter_buf, "{d}", .{self.pos.len}) catch unreachable;
        if (eq(u8, name, "?")) return std.fmt.bufPrint(&self.parameter_buf, "{d}", .{self.last_status}) catch unreachable;
        if (eq(u8, name, "$")) return std.fmt.bufPrint(&self.parameter_buf, "{d}", .{self.pid}) catch unreachable;
        if (eq(u8, name, "!")) return if (self.last_async) |pid| std.fmt.bufPrint(&self.parameter_buf, "{d}", .{pid}) catch unreachable else null;
        if (name.len != 0 and std.ascii.isDigit(name[0])) {
            const i = std.fmt.parseInt(usize, name, 10) catch return null;
            if (i == 0) return self.zero;
            return if (i <= self.pos.len) self.pos[i - 1] else null;
        }
        return (self.vars.get(name) orelse return null).value;
    }

    pub fn positionals(self: *const Runtime) []const []const u8 {
        return self.pos;
    }

    pub fn noglob(self: *const Runtime) bool {
        return self.no_glob;
    }

    pub fn replacePositionals(self: *Runtime, args: []const []const u8) !void {
        const copy = try self.allocator.alloc([]const u8, args.len);
        var i: usize = 0;
        errdefer self.freePositionalsPartial(copy, i);
        while (i < args.len) : (i += 1) copy[i] = try self.allocator.dupe(u8, args[i]);
        self.freePositionals(self.pos);
        self.pos = copy;
    }

    fn freePositionals(self: *Runtime, args: [][]const u8) void {
        self.freePositionalsPartial(args, args.len);
    }

    fn freePositionalsPartial(self: *Runtime, args: [][]const u8, len: usize) void {
        for (args[0..len]) |arg| self.allocator.free(arg);
        self.allocator.free(args);
    }

    pub fn unsetFunction(self: *Runtime, name: []const u8) void {
        if (self.functions.fetchRemove(name)) |removed| {
            var definition = removed.value;
            definition.arena.deinit();
            self.allocator.free(removed.key);
        }
    }

    fn setFunction(self: *Runtime, name: []const u8, body: *const Node) !void {
        if (builtins.find(name)) |kind| if (kind.special()) return error.InvalidFunctionName;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const copy = try cloneAst(arena.allocator(), body);
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const entry = try self.functions.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.arena.deinit();
        }
        entry.key_ptr.* = key;
        entry.value_ptr.* = .{ .arena = arena, .body = copy };
    }

    pub fn sourceFile(self: *Runtime, a: Allocator, name: [:0]const u8, args: []const [:0]const u8) anyerror!Outcome {
        const path = if (std.mem.findScalar(u8, name, '/') != null) name else switch (try self.search(a, name, false, false)) {
            .external => |path| path,
            else => return error.FileNotFound,
        };
        if (self.source_depth == max_depth) return error.DepthLimit;
        self.source_depth += 1;
        defer self.source_depth -= 1;
        const old = self.pos;
        if (args.len != 0) self.pos = &.{};
        defer if (args.len != 0) {
            self.freePositionals(self.pos);
            self.pos = old;
        };
        if (args.len != 0) try self.replacePositionals(try operands(a, args));
        const result = try self.runFile(path);
        return if (result.flow == .return_fn) normal(result.status) else result;
    }

    pub fn runFile(self: *Runtime, path: [:0]const u8) anyerror!Outcome {
        const fd = try proc.open(path, .{});
        return self.runOpened(path, fd);
    }

    pub fn runOpened(self: *Runtime, path: []const u8, fd: proc.Fd) anyerror!Outcome {
        var item: redir.Hidden = .{ .fd = if (fd > 2) fd else blk: {
            defer proc.close(fd);
            break :blk try proc.save(fd, 3);
        } };
        self.descriptors.track(&item);
        defer proc.close(item.fd);
        defer self.descriptors.untrack(&item);
        var source: Source = .{ .rt = self, .input = .{ .private = &item } };
        return self.runInput(&source, path);
    }

    pub fn runText(self: *Runtime, text: []const u8) anyerror!Outcome {
        var source: Source = .{ .rt = self, .input = .{ .text = text } };
        return self.runInput(&source, self.zero);
    }

    pub fn runStdin(self: *Runtime) anyerror!Outcome {
        var source: Source = .{ .rt = self, .input = .shared };
        return self.runInput(&source, self.zero);
    }

    fn runInput(self: *Runtime, source: *Source, name: []const u8) anyerror!Outcome {
        var parser = syntax.Parser.init(self.allocator, .{ .context = source, .next = Source.next }, &self.aliases);
        defer parser.deinit();
        const prompt = self.interactive and source.input == .shared;
        while (true) {
            if (prompt) source.prompt = .primary;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const node = parser.next(a) catch |err| {
                if (prompt and err == error.Interrupted) {
                    _ = proc.takeInterrupt();
                    self.last_status = 130;
                    proc.write(2, "\n") catch {};
                    parser.interrupt();
                    continue;
                }
                var location: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&location, "{d}:{d}: {s}", .{ parser.diagnostic.line, parser.diagnostic.column, reason(err) }) catch reason(err);
                diagnose("sh", name, text);
                if (prompt and (err == error.Syntax or err == error.Unsupported or err == error.DepthLimit)) {
                    self.last_status = 2;
                    parser.recover();
                    continue;
                }
                return .{ .status = 2, .flow = .fatal };
            } orelse return normal(self.last_status);
            const result = self.eval(a, node) catch |err| blk: {
                if (err != error.ExpansionError) diagnose("sh", name, reason(err));
                break :blk self.failure(2, true);
            };
            if (prompt and proc.takeInterrupt()) {
                self.last_status = 130;
                proc.write(2, "\n") catch {};
                continue;
            }
            self.last_status = result.status;
            if (self.interactive and result.flow == .fatal) continue;
            if (result.flow != .normal) return result;
        }
    }

    fn printPrompt(self: *Runtime, primary: bool) void {
        const prompt = self.parameter(if (primary) "PS1" else "PS2") orelse if (primary) "$ " else "> ";
        var i: usize = 0;
        while (i < prompt.len) {
            const start = i;
            i += 1;
            if (prompt[start] == '$' and i < prompt.len) {
                const first = i;
                if (prompt[i] == '{') {
                    if (std.mem.findScalar(u8, prompt[i + 1 ..], '}')) |offset| {
                        i += offset + 2;
                        proc.write(2, self.parameter(prompt[first + 1 .. i - 1]) orelse "") catch return;
                        continue;
                    }
                } else if (nameStart(prompt[i])) {
                    i += 1;
                    while (i < prompt.len and (nameStart(prompt[i]) or std.ascii.isDigit(prompt[i]))) : (i += 1) {}
                    proc.write(2, self.parameter(prompt[first..i]) orelse "") catch return;
                    continue;
                } else if (std.mem.findScalar(u8, "?$#!-0123456789", prompt[i]) != null) {
                    i += 1;
                    proc.write(2, self.parameter(prompt[first..i]) orelse "") catch return;
                    continue;
                }
            }
            proc.write(2, prompt[start..i]) catch return;
        }
    }

    fn failure(_: *Runtime, status: u8, fatal: bool) Outcome {
        return .{ .status = status, .flow = if (fatal) .fatal else .normal };
    }

    pub fn expansionError(_: *Runtime, name: []const u8, msg: []const u8) void {
        diagnose("sh", name, msg);
    }

    fn eval(self: *Runtime, a: Allocator, node: *const Node) anyerror!Outcome {
        if (self.eval_depth == max_depth) return error.DepthLimit;
        self.eval_depth += 1;
        defer self.eval_depth -= 1;
        const result = try self.evalNode(a, node);
        self.last_status = result.status;
        return result;
    }

    fn evalNode(self: *Runtime, a: Allocator, node: *const Node) anyerror!Outcome {
        switch (node.*) {
            .simple => |command| return self.simple(a, command),
            .sequence => |commands| {
                var result = normal(self.last_status);
                for (commands) |command| {
                    result = try self.eval(a, command);
                    if (result.flow != .normal or (self.interactive and proc.isInterrupted())) break;
                }
                return result;
            },
            .and_or => |list| {
                var result = try self.eval(a, list.first);
                for (list.rest) |step| {
                    if (result.flow != .normal or (self.interactive and proc.isInterrupted())) break;
                    if ((result.status == 0) == (step.op == .and_if)) result = try self.eval(a, step.node);
                }
                return result;
            },
            .pipeline => |chain| return self.pipeline(a, chain.stages, chain.negate),
            .group => |body| return self.eval(a, body),
            .asynchronous => |body| return self.launchAsync(a, body),
            .subshell => |body| {
                const pid = try proc.fork(self.signals);
                if (pid == 0) self.child(a, body);
                return normal(try self.waitForeground(pid));
            },
            .conditional => |conditional| {
                for (conditional.branches) |branch| {
                    const result = try self.eval(a, branch.condition);
                    if (result.flow != .normal) return result;
                    if (result.status == 0) return self.eval(a, branch.body);
                }
                return if (conditional.otherwise) |body| self.eval(a, body) else normal(0);
            },
            .loop => |loop| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                var status: u8 = 0;
                while (!self.interactive or !proc.isInterrupted()) {
                    const condition = try self.iteration(loop.condition);
                    if (condition.flow != .normal) {
                        if (loopJump(condition, &status)) |result| return result;
                        continue;
                    }
                    if ((condition.status == 0) == loop.until) break;
                    const body = try self.iteration(loop.body);
                    if (loopJump(body, &status)) |result| return result;
                }
                return normal(status);
            },
            .for_loop => |loop| {
                var values: std.ArrayList([]const u8) = .empty;
                if (loop.words) |words| {
                    for (words) |word| try values.appendSlice(a, try expand.word(self, a, word, .arguments));
                } else {
                    for (self.pos) |arg| try values.append(a, try a.dupe(u8, arg));
                }
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                var status: u8 = 0;
                for (values.items) |value| {
                    if (self.interactive and proc.isInterrupted()) break;
                    try self.assignParameter(loop.name, value);
                    const result = try self.iteration(loop.body);
                    if (loopJump(result, &status)) |leave| return leave;
                }
                return normal(status);
            },
            .case => |case| {
                const value = (try expand.word(self, a, case.word, .assignment))[0];
                var result = normal(0);
                var fallthrough = false;
                for (case.arms) |arm| {
                    var matched = fallthrough;
                    if (!matched) for (arm.patterns) |pattern| {
                        if (expand.matches((try expand.word(self, a, pattern, .pattern))[0], value)) {
                            matched = true;
                            break;
                        }
                    };
                    if (!matched) continue;
                    result = try self.eval(a, arm.body);
                    if (result.flow != .normal or !arm.fallthrough) break;
                    fallthrough = true;
                }
                return result;
            },
            .function => |definition| {
                try self.setFunction(definition.name, definition.body);
                return normal(0);
            },
            .redirected => |wrapped| switch (wrapped.node.*) {
                .subshell => |body| {
                    const pid = try proc.fork(self.signals);
                    if (pid == 0) {
                        self.resetSubshell();
                        self.interactive = false;
                        const result = self.evalRedirected(a, body, wrapped.redirs) catch |err| self.childError(err);
                        linux.exit(result.status);
                    }
                    return normal(try self.waitForeground(pid));
                },
                else => return self.evalRedirected(a, wrapped.node, wrapped.redirs),
            },
        }
    }

    fn evalRedirected(self: *Runtime, a: Allocator, node: *const Node, ops: []const syntax.Redirection) anyerror!Outcome {
        var redirects: redir.Redirects = .{};
        defer redirects.finish(&self.descriptors, false);
        redirects.apply(&self.descriptors, self, a, ops, true) catch |err|
            return self.redirectError(redirects.failure_word, err, false);
        return self.eval(a, node);
    }

    fn iteration(self: *Runtime, body: *const Node) anyerror!Outcome {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return self.eval(arena.allocator(), body);
    }

    fn child(self: *Runtime, a: Allocator, body: *const Node) noreturn {
        self.resetSubshell();
        self.interactive = false;
        const result = self.eval(a, body) catch |err| self.childError(err);
        linux.exit(result.status);
    }

    fn resetSubshell(self: *Runtime) void {
        self.children.clearRetainingCapacity();
        self.last_async = null;
        self.completed_serial = 0;
        self.direct_exec = false;
    }

    fn launchAsync(self: *Runtime, a: Allocator, body: *const Node) !Outcome {
        self.collectChildren();
        try self.children.ensureUnusedCapacity(self.allocator, 1);
        const pid = try proc.forkAsync(self.signals);
        if (pid == 0) {
            var signals = self.signals.asyncCopy();
            self.signals = &signals;
            self.resetSubshell();
            self.interactive = false;
            const fd = proc.open("/dev/null", .{}) catch linux.exit(125);
            proc.install(fd, 0) catch linux.exit(125);
            self.direct_exec = body.* == .simple;
            const result = self.eval(a, body) catch |err| self.childError(err);
            linux.exit(result.status);
        }
        var i: usize = 0;
        while (i < self.children.items.len) {
            if (self.children.items[i].pid == pid) {
                _ = self.children.orderedRemove(i);
            } else i += 1;
        }
        self.children.appendAssumeCapacity(.{ .pid = pid });
        self.last_async = pid;
        if (self.interactive) {
            var buffer: [32]u8 = undefined;
            proc.write(2, std.fmt.bufPrint(&buffer, "{d}\n", .{pid}) catch unreachable) catch {};
        }
        return normal(0);
    }

    pub fn collectChildren(self: *Runtime) void {
        for (self.children.items) |*entry| {
            if (entry.status != null) continue;
            const status = proc.collect(entry.pid) catch 127;
            if (status) |value| {
                self.completed_serial +%= 1;
                entry.status = value;
                entry.completed = self.completed_serial;
            }
        }
        var limit: linux.rlimit = undefined;
        const max_saved: u64 = if (linux.errno(linux.getrlimit(.NPROC, &limit)) == .SUCCESS) @max(25, limit.cur) else 25;
        var count: u64 = 0;
        for (self.children.items) |entry| if (entry.status != null) {
            count += 1;
        };
        while (count > max_saved) : (count -= 1) {
            var oldest: ?usize = null;
            for (self.children.items, 0..) |entry, i| {
                if (entry.status != null and (oldest == null or entry.completed < self.children.items[oldest.?].completed)) oldest = i;
            }
            _ = self.children.orderedRemove(oldest.?);
        }
    }

    pub fn waitChild(self: *Runtime, pid: ?proc.Pid) !u8 {
        const old = try proc.blockChildSignals();
        defer proc.restoreMask(&old);
        while (true) {
            self.collectChildren();
            if (self.interactive and proc.isInterrupted()) return error.Interrupted;
            if (pid) |target| {
                for (self.children.items, 0..) |entry, i| {
                    if (entry.pid != target) continue;
                    if (entry.status) |status| {
                        _ = self.children.orderedRemove(i);
                        return status;
                    }
                    try proc.waitEvent(&old);
                    break;
                } else return 127;
            } else {
                var running = false;
                for (self.children.items) |entry| if (entry.status == null) {
                    running = true;
                    break;
                };
                if (!running) {
                    self.children.clearRetainingCapacity();
                    return 0;
                }
                try proc.waitEvent(&old);
            }
        }
    }

    fn waitForeground(self: *Runtime, pid: proc.Pid) !u8 {
        const old = try proc.blockChildSignals();
        defer proc.restoreMask(&old);
        while (true) {
            self.collectChildren();
            if (try proc.collect(pid)) |status| return status;
            try proc.waitEvent(&old);
        }
    }

    fn childError(_: *Runtime, err: anyerror) noreturn {
        if (err != error.ExpansionError) diagnose("sh", null, reason(err));
        linux.exit(2);
    }

    fn pipeline(self: *Runtime, a: Allocator, stages: []const *const Node, negate: bool) anyerror!Outcome {
        if (stages.len == 1) {
            var result = try self.eval(a, stages[0]);
            if (negate and result.flow == .normal) result.status = @intFromBool(result.status == 0);
            return result;
        }
        const pids = try a.alloc(proc.Pid, stages.len);
        // Stages cannot start running commands until all of them are forked.
        // On partial launch failure this lets us kill/reap only direct children.
        const gate = try internalPipe();
        defer proc.close(gate[0]);
        var gate_open = true;
        defer if (gate_open) proc.close(gate[1]);
        var started: usize = 0;
        var previous: ?proc.Fd = null;
        errdefer if (previous) |fd| proc.close(fd);
        errdefer {
            for (pids[0..started]) |pid| proc.cancel(pid);
            for (pids[0..started]) |pid| _ = proc.wait(pid) catch 0;
        }
        for (stages, 0..) |stage, i| {
            const fds = if (i + 1 < stages.len) try internalPipe() else null;
            errdefer if (fds) |pair| {
                proc.close(pair[0]);
                proc.close(pair[1]);
            };
            const pid = try proc.fork(self.signals);
            if (pid == 0) {
                proc.close(gate[1]);
                if (previous) |fd| proc.install(fd, 0) catch linux.exit(125);
                if (fds) |pair| {
                    proc.close(pair[0]);
                    proc.install(pair[1], 1) catch linux.exit(125);
                }
                var byte: [1]u8 = undefined;
                if ((proc.read(gate[0], &byte) catch linux.exit(125)) != 0) linux.exit(125);
                proc.close(gate[0]);
                self.child(a, stage);
            }
            pids[started] = pid;
            started += 1;
            if (previous) |fd| proc.close(fd);
            previous = if (fds) |pair| blk: {
                proc.close(pair[1]);
                break :blk pair[0];
            } else null;
        }
        proc.close(gate[1]);
        gate_open = false;
        var status: u8 = 0;
        var wait_failed = false;
        for (pids) |pid| status = self.waitForeground(pid) catch blk: {
            wait_failed = true;
            break :blk 125;
        };
        started = 0;
        if (wait_failed) return error.WaitFailed;
        return normal(if (negate) @intFromBool(status == 0) else status);
    }

    pub fn substitute(self: *Runtime, a: Allocator, text: []const u8) anyerror![]const u8 {
        const fds = try internalPipe();
        const pid = proc.fork(self.signals) catch |err| {
            proc.close(fds[0]);
            proc.close(fds[1]);
            return err;
        };
        if (pid == 0) {
            proc.close(fds[0]);
            proc.install(fds[1], 1) catch linux.exit(125);
            self.resetSubshell();
            self.interactive = false;
            const result = self.runText(text) catch linux.exit(2);
            linux.exit(result.status);
        }
        proc.close(fds[1]);
        defer proc.close(fds[0]);
        var waited = false;
        defer if (!waited) {
            proc.cancel(pid);
            _ = proc.wait(pid) catch 0;
        };
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(a);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = proc.interactiveRead(fds[0], &buf) catch |err| switch (err) {
                error.ChildChanged => {
                    self.collectChildren();
                    continue;
                },
                else => return err,
            };
            if (n == 0) break;
            try bytes.appendSlice(a, buf[0..n]);
        }
        self.substitution_status = try self.waitForeground(pid);
        waited = true;
        bytes.items.len = std.mem.trimEnd(u8, bytes.items, "\n").len;
        return bytes.toOwnedSlice(a);
    }

    fn simple(self: *Runtime, a: Allocator, command: syntax.Simple) anyerror!Outcome {
        self.substitution_status = null;
        var prefix: usize = 0;
        while (prefix < command.words.len and syntax.assignment(command.words[prefix]) != null) : (prefix += 1) {}
        var args: std.ArrayList([:0]const u8) = .empty;
        var declare = false;
        for (command.words[prefix..]) |word| {
            const mode: expand.Mode = if (declare and syntax.assignment(word) != null) .assignment else .arguments;
            for (try expand.word(self, a, word, mode)) |field| {
                if (args.items.len == 0) declare = eq(u8, field, "export") or eq(u8, field, "readonly");
                try args.append(a, try cString(a, field));
            }
        }
        const name = if (args.items.len != 0) args.items[0] else null;
        const kind = if (name) |n| builtins.find(n) else null;
        const special = if (kind) |k| k.special() else false;
        const temporary = !special and name != null;
        const saved = try a.alloc(Previous, if (temporary) prefix else 0);
        var saved_len: usize = 0;
        defer self.restoreVariables(saved[0..saved_len]);
        var redirects: redir.Redirects = .{};
        var retain = false;
        defer redirects.finish(&self.descriptors, retain);
        redirects.apply(&self.descriptors, self, a, command.redirs, true) catch |err|
            return self.redirectError(redirects.failure_word, err, special);
        for (command.words[0..prefix]) |word| {
            const split = syntax.assignment(word).?;
            const key = word[0..split];
            const value = (try expand.word(self, a, word[split + 1 ..], .assignment))[0];
            if (temporary) {
                saved[saved_len] = try self.saveVariable(key);
                saved_len += 1;
            }
            self.setVariable(key, value, temporary or kind == .exec, false) catch |err| {
                diagnose("sh", key, reason(err));
                return self.failure(1, true);
            };
        }
        if (name == null) return normal(self.substitution_status orelse 0);
        const result = try self.executeArgs(a, args.items, false, false, false);
        retain = result.retain_redirections;
        return result;
    }

    fn redirectError(self: *Runtime, word: ?[]const u8, err: anyerror, special: bool) Outcome {
        if (err != error.ExpansionError) diagnose("sh", word, reason(err));
        return self.failure(1, special or switch (err) {
            error.ExpansionError, error.BadExpansion, error.Unsupported, error.DepthLimit, error.InvalidAssignment, error.ReadonlyVariable, error.OutOfMemory => true,
            else => false,
        });
    }

    const Previous = struct { name: []const u8, before: ?Variable };

    fn saveVariable(self: *Runtime, name: []const u8) !Previous {
        var before = self.vars.get(name) orelse return .{ .name = name, .before = null };
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        if (before.value) |value| before.value = try self.allocator.dupe(u8, value);
        return .{ .name = owned, .before = before };
    }

    fn restoreVariables(self: *Runtime, previous: []const Previous) void {
        var i = previous.len;
        while (i > 0) {
            i -= 1;
            const saved = previous[i];
            if (self.vars.fetchRemove(saved.name)) |current| self.freeVariable(current.key, current.value);
            if (saved.before) |value| self.vars.put(saved.name, value) catch |err| {
                self.freeVariable(saved.name, value);
                diagnose("sh", null, reason(err));
            };
        }
    }

    pub fn lookup(self: *Runtime, a: Allocator, name: [:0]const u8, bypass: bool, use_default: bool) anyerror!Lookup {
        if (std.mem.findScalar(u8, name, '/') == null) {
            const kind = builtins.find(name);
            if (kind) |k| if (k.special()) return .{ .builtin = k };
            if (!bypass and self.functions.contains(name)) return .function;
            if (kind) |k| return .{ .builtin = k };
        }
        return self.search(a, name, use_default, true);
    }

    fn search(self: *Runtime, a: Allocator, name: [:0]const u8, use_default: bool, executable: bool) !Lookup {
        if (name.len == 0) return .missing;
        if (std.mem.findScalar(u8, name, '/') != null) return switch (fileAccess(name, executable)) {
            .external => .{ .external = try a.dupeSentinel(u8, name, 0) },
            else => |other| other,
        };
        var paths = std.mem.splitScalar(u8, if (use_default) default_path else self.parameter("PATH") orelse default_path, ':');
        var denied = false;
        while (paths.next()) |dir| {
            const path = if (dir.len == 0) try a.dupeSentinel(u8, name, 0) else try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
            switch (fileAccess(path, executable)) {
                .external => return .{ .external = path },
                .inaccessible => denied = true,
                else => {},
            }
            a.free(path);
        }
        return if (denied) .inaccessible else .missing;
    }

    pub fn executeArgs(self: *Runtime, a: Allocator, args: []const [:0]const u8, bypass: bool, use_default: bool, replace: bool) anyerror!Outcome {
        if (args.len == 0) return normal(0);
        const target = if (replace) try self.search(a, args[0], use_default, true) else try self.lookup(a, args[0], bypass, use_default);
        switch (target) {
            .builtin => |kind| {
                self.direct_exec = false;
                const result = builtins.run(self, a, kind, args[1..]) catch |err| {
                    if (err == error.Interrupted) return normal(130);
                    if (err != error.ExpansionError) diagnose(args[0], null, reason(err));
                    return self.failure(1, (!bypass and kind.special()) or err == error.OutOfMemory);
                };
                if (!bypass and kind == .exec and result.status != 0) return self.failure(result.status, true);
                return result;
            },
            .function => {
                self.direct_exec = false;
                // The running function may unset or redefine itself.
                const body = try cloneAst(a, self.functions.get(args[0]).?.body);
                const old = self.pos;
                self.pos = &.{};
                defer {
                    self.freePositionals(self.pos);
                    self.pos = old;
                }
                try self.replacePositionals(try operands(a, args[1..]));
                self.function_depth += 1;
                defer self.function_depth -= 1;
                const result = try self.eval(a, body);
                return if (result.flow == .return_fn) normal(result.status) else result;
            },
            .external => |path| {
                const argv = try a.allocSentinel(?[*:0]const u8, args.len, null);
                for (args, argv) |arg, *ptr| ptr.* = arg.ptr;
                const envp = try self.environment(a);
                if (replace or self.direct_exec) {
                    const status = self.execExternal(a, path, args, argv, envp, true);
                    return normal(status);
                }
                const pid = try proc.fork(self.signals);
                if (pid == 0) linux.exit(self.execExternal(a, path, args, argv, envp, false));
                return normal(try self.waitForeground(pid));
            },
            .missing, .inaccessible => {
                diagnose("sh", args[0], if (target == .missing) "not found" else "cannot execute");
                return normal(if (target == .missing) 127 else 126);
            },
        }
    }

    fn environment(self: *Runtime, a: Allocator) ![:null]?[*:0]const u8 {
        var entries: std.ArrayList(?[*:0]const u8) = .empty;
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            const v = entry.value_ptr.*;
            if (v.exported) if (v.value) |value| {
                const text = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ entry.key_ptr.*, value }, 0);
                try entries.append(a, text.ptr);
            };
        }
        return entries.toOwnedSliceSentinel(a, null);
    }

    fn execExternal(self: *Runtime, a: Allocator, path: [:0]const u8, args: []const [:0]const u8, argv: proc.Vector, envp: proc.Vector, replace: bool) u8 {
        const err = self.signals.exec(path, argv, envp, replace and self.interactive);
        if (err == .NOEXEC) {
            const fd = proc.open(path, .{}) catch {
                diagnose("sh", path, "cannot open executable text");
                return 126;
            };
            var buf: [512]u8 = undefined;
            const n = proc.read(fd, &buf) catch {
                proc.close(fd);
                diagnose("sh", path, "cannot read executable text");
                return 126;
            };
            if (std.mem.findScalar(u8, buf[0..n], 0) != null) {
                proc.close(fd);
                diagnose("sh", path, "cannot execute binary file");
                return 126;
            }
            proc.rewind(fd) catch {
                proc.close(fd);
                diagnose("sh", path, "cannot rewind executable text");
                return 126;
            };
            const pos = operands(a, args[1..]) catch {
                proc.close(fd);
                return 125;
            };
            var fresh = Runtime.init(self.allocator, path, pos, envp, self.signals) catch {
                proc.close(fd);
                return 125;
            };
            fresh.descriptors = self.descriptors;
            if (replace and self.interactive) self.signals.restoreChild();
            const result = fresh.runOpened(path, fd) catch linux.exit(2);
            linux.exit(result.status);
        }
        diagnose("sh", path, "cannot execute");
        return 126;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !nameStart(name[0])) return false;
    for (name[1..]) |c| if (!nameStart(c) and !std.ascii.isDigit(c)) return false;
    return true;
}

fn nameStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

pub fn operands(a: Allocator, args: []const [:0]const u8) ![]const []const u8 {
    const result = try a.alloc([]const u8, args.len);
    for (args, result) |arg, *dest| dest.* = arg;
    return result;
}

fn cString(a: Allocator, text: []const u8) ![:0]const u8 {
    if (std.mem.findScalar(u8, text, 0) != null) return error.InvalidByte;
    return a.dupeSentinel(u8, text, 0);
}

fn fileAccess(path: [:0]const u8, executable: bool) Lookup {
    var stat: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stat);
    switch (linux.errno(rc)) {
        .NOENT, .NOTDIR => return .missing,
        .SUCCESS => if (linux.S.ISDIR(stat.mode)) return .inaccessible,
        else => return .inaccessible,
    }
    const mode: linux.mode_t = if (executable) linux.X_OK else linux.R_OK;
    return if (linux.errno(linux.faccessat(linux.AT.FDCWD, path, mode, 0)) == .SUCCESS) .{ .external = path } else .inaccessible;
}

fn internalPipe() ![2]proc.Fd {
    var fds = try proc.pipe();
    errdefer for (fds) |fd| proc.close(fd);
    for (&fds) |*fd| {
        if (fd.* > 2) continue;
        const moved = try proc.save(fd.*, 3);
        proc.close(fd.*);
        fd.* = moved;
    }
    return fds;
}

fn normal(status: u8) Outcome {
    return .{ .status = status };
}

fn loopJump(result: Outcome, status: *u8) ?Outcome {
    switch (result.flow) {
        .normal => status.* = result.status,
        .break_loop, .continue_loop => {
            if (result.levels > 1) {
                var jump = result;
                jump.levels -= 1;
                return jump;
            }
            status.* = result.status;
            if (result.flow == .break_loop) return normal(status.*);
        },
        else => return result,
    }
    return null;
}

// ASTs contain only immutable scalars, slices, and child pointers. Deep-copy
// these shapes into the function's lifetime without keeping parser storage live.
fn cloneAst(a: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => blk: {
                const dest = try a.create(p.child);
                dest.* = try cloneAst(a, value.*);
                break :blk dest;
            },
            .slice => blk: {
                if (p.child == u8) break :blk try a.dupe(u8, value);
                const dest = try a.alloc(p.child, value.len);
                for (value, dest) |element, *out| out.* = try cloneAst(a, element);
                break :blk dest;
            },
            else => @compileError("unexpected AST pointer"),
        },
        .optional => if (value) |item| try cloneAst(a, item) else null,
        .@"struct" => blk: {
            var dest: T = undefined;
            inline for (comptime std.meta.fieldNames(T)) |field| @field(dest, field) = try cloneAst(a, @field(value, field));
            break :blk dest;
        },
        .@"union" => switch (value) {
            inline else => |item, tag| @unionInit(T, @tagName(tag), try cloneAst(a, item)),
        },
        .int, .bool, .@"enum", .void => value,
        else => @compileError("unexpected AST field"),
    };
}

pub fn diagnose(command: []const u8, subject: ?[]const u8, msg: []const u8) void {
    proc.write(2, command) catch return;
    proc.write(2, ": ") catch return;
    if (subject) |name| {
        proc.write(2, name) catch return;
        proc.write(2, ": ") catch return;
    }
    proc.write(2, msg) catch return;
    proc.write(2, "\n") catch {};
}

pub fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.Syntax => "syntax error",
        error.Incomplete => "unexpected end of input",
        error.Unsupported => "unsupported shell syntax",
        error.DepthLimit => "shell nesting limit exceeded",
        error.FileNotFound => "not found",
        error.AccessDenied => "permission denied",
        error.ReadonlyVariable => "readonly variable",
        error.BadDescriptor => "bad file descriptor",
        error.InvalidByte => "unexpected NUL byte",
        error.BadExpansion => "invalid word expansion",
        error.InvalidAssignment => "invalid assignment",
        error.InvalidDescriptor => "invalid file descriptor",
        error.AmbiguousRedirect => "ambiguous redirection",
        error.InvalidOperand => "invalid operand or unsupported option",
        error.OpenFailed => "cannot open file",
        error.ReadFailed => "cannot read input",
        error.WriteFailed => "cannot write output",
        error.ChangeDirectory => "cannot change directory",
        error.PipeFailed => "cannot create pipe",
        error.ForkFailed => "cannot start child process",
        else => @errorName(err),
    };
}

test "sh: evaluation owns definitions and temporary command state" {
    const signals = try proc.Signals.init(false);
    defer signals.deinit();
    var rt = try Runtime.init(std.testing.allocator, "sh", &.{"outer"}, &.{ "EXPORTED=yes", "IFS=wrong", null }, &signals);
    defer rt.deinit();
    const result = try rt.runText(
        "v=old\n" ++
            "f() { v=changed; saved=$1; unset -f f; return 9; }\n" ++
            "v=temp f inner && unreachable=yes\n" ++
            "status=$?; :\n",
    );
    try std.testing.expectEqual(0, result.status);
    try std.testing.expectEqualStrings("old", rt.parameter("v").?);
    try std.testing.expectEqualStrings("inner", rt.parameter("saved").?);
    try std.testing.expectEqualStrings("outer", rt.parameter("1").?);
    try std.testing.expectEqualStrings("9", rt.parameter("status").?);
    try std.testing.expectEqualStrings(" \t\n", rt.parameter("IFS").?);
    try std.testing.expect(rt.parameter("unreachable") == null);
    try std.testing.expect(!rt.functions.contains("f"));
}

test "sh: shell state and initialization release partial allocations" {
    const signals = try proc.Signals.init(false);
    defer signals.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn make(a: Allocator, sigs: *const proc.Signals) !void {
            var rt = try Runtime.init(a, "sh", &.{ "first", "second" }, &.{ "ONE=1", "TWO=2", null }, sigs);
            defer rt.deinit();
            try rt.setVariable("ONE", "new", false, true);
            try rt.setFunction("f", &.{ .simple = .{ .words = &.{ "export", "X=1" }, .redirs = &.{} } });
        }
    }.make, .{&signals});
}
