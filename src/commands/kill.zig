//! Send signals to processes, or translate signal numbers and shell statuses.
const std = @import("std");
const proc = @import("../shell/process.zig");
const linux = proc.linux;
const report = @import("../common/error.zig").report;

const Signal = struct { name: []const u8, sig: linux.SIG };
const signals = blk: {
    @setEvalBranchQuota(30_000);
    const fields = @typeInfo(linux.SIG).@"enum".field_names;
    const rtmin = linux.sigrtmin();
    const rtmax = linux.sigrtmax();
    var table: [fields.len + (rtmax - rtmin + 1) + 2]Signal = undefined;
    for (fields, 0..) |name, i| table[i] = .{ .name = name, .sig = @field(linux.SIG, name) };
    for (rtmin..rtmax + 1) |n| table[fields.len + n - rtmin] = .{
        .name = if (n == rtmin) "RTMIN" else if (n == rtmax) "RTMAX" else std.fmt.comptimePrint("RTMIN+{d}", .{n - rtmin}),
        .sig = @fromBackingInt(@intCast(n)),
    };
    table[table.len - 2] = .{ .name = "POLL", .sig = linux.SIG.POLL };
    table[table.len - 1] = .{ .name = "IOT", .sig = linux.SIG.IOT };
    break :blk table;
};

fn decimal(comptime T: type, text: []const u8) ?T {
    const signed = @typeInfo(T).int.signedness == .signed;
    const start: usize = if (signed and text.len != 0 and (text[0] == '+' or text[0] == '-')) 1 else 0;
    if (text.len == start) return null;
    for (text[start..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

fn signalName(number: u32) ?[]const u8 {
    for (&signals) |entry| if (@backingInt(entry.sig) == number) return entry.name;
    return null;
}

fn parseSignal(text: []const u8, numeric: bool) ?linux.SIG {
    if (std.mem.eql(u8, text, "0")) return @fromBackingInt(@intCast(0));
    if (numeric) if (decimal(u32, text)) |n| {
        if (n == 0 or signalName(n) != null) return @fromBackingInt(@intCast(n));
        return null;
    };
    for (&signals) |entry| if (std.ascii.eqlIgnoreCase(entry.name, text)) return entry.sig;
    return null;
}

fn statusName(text: []const u8) ?[]const u8 {
    const n = decimal(u32, text) orelse return null;
    return signalName(if (n > 128) n - 128 else n);
}

const Request = union(enum) {
    list: ?[]const u8,
    send: struct { signal: linux.SIG, pids: []const [:0]const u8 },
};

fn parse(args: []const [:0]const u8) !Request {
    var rest = args;
    var sig: linux.SIG = .TERM;
    if (rest.len != 0 and rest[0].len > 1 and rest[0][0] == '-' and !std.mem.eql(u8, rest[0], "--")) {
        const option = rest[0][1..];
        rest = rest[1..];
        if (std.mem.eql(u8, option, "l")) {
            if (rest.len != 0 and std.mem.eql(u8, rest[0], "--")) rest = rest[1..];
            return switch (rest.len) {
                0 => .{ .list = null },
                1 => .{ .list = rest[0] },
                else => error.InvalidArgument,
            };
        }
        if (std.mem.eql(u8, option, "s")) {
            if (rest.len == 0) return error.InvalidArgument;
            sig = parseSignal(rest[0], false) orelse return error.InvalidArgument;
            rest = rest[1..];
        } else {
            sig = parseSignal(option, true) orelse
                (if (option[0] == 's') parseSignal(option[1..], false) else null) orelse
                return error.InvalidArgument;
        }
    }
    if (rest.len != 0 and std.mem.eql(u8, rest[0], "--")) rest = rest[1..];
    if (rest.len == 0) return error.InvalidArgument;
    return .{ .send = .{ .signal = sig, .pids = rest } };
}

fn sendToTargets(targets: Request, sender: anytype) u8 {
    var status: u8 = 0;
    for (targets.send.pids) |operand| {
        const err = if (decimal(linux.pid_t, operand)) |pid| switch (sender.send(pid, targets.send.signal)) {
            .SUCCESS => continue,
            .SRCH => error.NoSuchProcess,
            .PERM, .ACCES => error.AccessDenied,
            .INVAL => error.InvalidArgument,
            else => error.SignalFailed,
        } else error.InvalidArgument;
        report("kill", operand, err);
        status = 1;
    }
    return status;
}

const Kernel = struct {
    fn send(_: Kernel, pid: linux.pid_t, sig: linux.SIG) linux.E {
        return linux.errno(linux.kill(pid, sig));
    }
};

fn listSignals(status: ?[]const u8) !void {
    if (status) |value| {
        try proc.write(1, statusName(value) orelse return error.InvalidArgument);
        return proc.write(1, "\n");
    }
    for (&signals, 0..) |entry, i| {
        try proc.write(1, entry.name);
        try proc.write(1, if (i + 1 == signals.len) "\n" else " ");
    }
}

pub fn run(_: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const request = parse(args) catch |err| {
        report("kill", if (args.len == 0) "missing operand" else args[0], err);
        return 1;
    };
    switch (request) {
        .send => return sendToTargets(request, Kernel{}),
        .list => |status| listSignals(status) catch |err| {
            report("kill", status, err);
            return 1;
        },
    }
    return 0;
}

test "kill: signal names, numbers and shell statuses share the target table" {
    for (&signals) |entry| {
        try std.testing.expectEqual(entry.sig, parseSignal(entry.name, false).?);
        const n = @backingInt(entry.sig);
        var buf: [10]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{128 + n});
        try std.testing.expectEqualStrings(signalName(n).?, statusName(text).?);
    }
    try std.testing.expectEqual(linux.SIG.TERM, (try parse(&.{ "-s", "tErM", "12" })).send.signal);
    try std.testing.expectEqual(linux.SIG.TERM, (try parse(&.{ "-sTERM", "12" })).send.signal);
    try std.testing.expectEqual(linux.SIG.INT, (try parse(&.{ "-2", "12" })).send.signal);
    try std.testing.expectEqual(linux.SIG.STOP, (try parse(&.{ "-stop", "12" })).send.signal);
    try std.testing.expectEqual(@as(u32, 0), @backingInt((try parse(&.{ "-s", "0", "12" })).send.signal));
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "-s", "SIGINT", "12" }));
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "-999", "12" }));
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "-l", "1", "2" }));
    try std.testing.expect(statusName("129_0") == null);
}

test "kill: signed PID bounds and special operands reach the sender unchanged" {
    const Fake = struct {
        seen: [5]linux.pid_t = undefined,
        len: usize = 0,

        fn send(self: *@This(), pid: linux.pid_t, sig: linux.SIG) linux.E {
            std.debug.assert(sig == .TERM);
            self.seen[self.len] = pid;
            self.len += 1;
            return if (pid == -2) .SRCH else .SUCCESS;
        }
    };
    var fake: Fake = .{};
    const req = try parse(&.{ "--", "-1", "2147483648", "-2", "0", "-2147483648", "+2147483647", "%1", "1_2" });
    try std.testing.expectEqual(1, sendToTargets(req, &fake));
    try std.testing.expectEqualSlices(linux.pid_t, &.{ -1, -2, 0, -2147483648, 2147483647 }, fake.seen[0..fake.len]);
}
