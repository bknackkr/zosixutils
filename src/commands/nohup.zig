//! Invoke a utility with SIGHUP ignored and redirect its terminal descriptors.
const std = @import("std");
const env = @import("../common/env.zig");
const proc = @import("../shell/process.zig");
const shell = @import("../shell/runtime.zig");
const sh = @import("sh.zig");
const linux = proc.linux;
const Allocator = std.mem.Allocator;

pub fn run(_: Allocator, _: []const [:0]const u8) u8 {
    return fail(null, "requires startup context");
}

pub fn launch(allocator: Allocator, args: []const [:0]const u8, envp: env.Vector) u8 {
    const explicit_end = args.len != 0 and std.mem.eql(u8, args[0], "--");
    const operands = if (explicit_end) args[1..] else args;
    if (operands.len == 0 or operands[0].len == 0) return fail(null, "missing utility operand");
    if (!explicit_end and operands[0][0] == '-') return fail(operands[0], "invalid option");

    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    if (linux.errno(linux.sigaction(.HUP, &ignore, null)) != .SUCCESS) return fail(null, "cannot ignore SIGHUP");
    redirect(allocator, envp) catch |err| return fail(null, switch (err) {
        error.NoOutputFile => "cannot open nohup.out for appending",
        error.OutOfMemory => "out of memory",
        else => "cannot redirect standard descriptors",
    });
    return invoke(allocator, operands, envp) catch |err| fail(operands[0], shell.reason(err));
}

fn fail(subject: ?[]const u8, message: []const u8) u8 {
    shell.diagnose("nohup", subject, message);
    return 127;
}

const Descriptor = enum { closed, terminal, other };

fn probe(fd: proc.Fd) !Descriptor {
    _ = proc.flags(fd) catch |err| return switch (err) {
        error.BadDescriptor => .closed,
        else => err,
    };
    return if (proc.terminal(fd)) .terminal else .other;
}

fn redirect(allocator: Allocator, envp: env.Vector) !void {
    const input = try probe(0);
    const output = try probe(1);
    const errors = try probe(2);

    if (input == .terminal) try proc.install(try proc.open("/dev/null", .{}), 0);
    if (output == .terminal or (output == .closed and errors == .terminal)) {
        var path: [:0]const u8 = "nohup.out";
        var fallback: ?[:0]const u8 = null;
        defer if (fallback) |owned| allocator.free(owned);
        const fd = openAppend(path) catch blk: {
            const home = env.get(envp, "HOME") orelse return error.NoOutputFile;
            if (home.len == 0) return error.NoOutputFile;
            fallback = try std.fmt.allocPrintSentinel(allocator, "{s}/nohup.out", .{home}, 0);
            path = fallback.?;
            break :blk try openAppend(path);
        };
        if (output == .terminal and errors != .closed)
            shell.diagnose("nohup", "appending output to", path);
        try proc.install(fd, if (output == .terminal) 1 else 2);
    }
    if (errors == .terminal and output != .closed) try proc.dup(1, 2);
}

fn openAppend(path: [:0]const u8) !proc.Fd {
    const append: linux.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true };
    var exclusive = append;
    exclusive.CREAT = true;
    exclusive.EXCL = true;
    while (true) {
        const result = linux.openat(linux.AT.FDCWD, path, exclusive, 0o600);
        switch (linux.errno(result)) {
            .SUCCESS => {
                const fd: proc.Fd = @intCast(result);
                errdefer proc.close(fd);
                if (linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.NoOutputFile;
                return fd;
            },
            .INTR => continue,
            .EXIST => return proc.open(path, append) catch error.NoOutputFile,
            else => return error.NoOutputFile,
        }
    }
}

fn invoke(allocator: Allocator, args: []const [:0]const u8, envp: env.Vector) !u8 {
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len, null);
    defer allocator.free(argv);
    for (args, argv) |arg, *entry| entry.* = arg.ptr;

    const name = args[0];
    var paths = std.mem.splitScalar(u8, env.get(envp, "PATH") orelse "/bin:/usr/bin", ':');
    const direct = std.mem.findScalar(u8, name, '/') != null;
    var inaccessible = false;
    while (paths.next()) |dir| {
        const owned = if (!direct and dir.len != 0) try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0) else null;
        defer if (owned) |path| allocator.free(path);
        const path = owned orelse name;
        switch (proc.exec(path, argv, envp)) {
            .NOEXEC => return runTextUtility(allocator, path, args[1..], envp) catch {
                shell.diagnose("nohup", path, "cannot execute file as shell text");
                return 126;
            },
            .NOENT, .NOTDIR => {
                // An executable with a missing interpreter also yields ENOENT.
                var info: linux.Statx = undefined;
                if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &info)) == .SUCCESS)
                    inaccessible = true;
            },
            .ACCES, .PERM => inaccessible = true,
            else => {
                inaccessible = true;
                break;
            },
        }
        if (direct) break;
    }
    if (!inaccessible) return fail(name, "not found");
    shell.diagnose("nohup", name, "cannot execute");
    return 126;
}

fn runTextUtility(allocator: Allocator, path: [:0]const u8, args: []const [:0]const u8, envp: env.Vector) !u8 {
    const fd = try proc.open(path, .{ .NONBLOCK = true });
    var consumed = false;
    defer if (!consumed) proc.close(fd);
    var info: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &info)) != .SUCCESS or !linux.S.ISREG(info.mode))
        return error.NotText;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try proc.read(fd, &buf);
        if (n == 0) break;
        if (std.mem.findScalar(u8, buf[0..n], 0) != null) return error.NotText;
    }
    try proc.rewind(fd);
    consumed = true;
    return sh.launchOpened(allocator, path, args, envp, fd);
}

test "nohup: missing and invalid utility operands return 127 before setup" {
    try std.testing.expectEqual(127, launch(std.testing.allocator, &.{}, &.{null}));
    try std.testing.expectEqual(127, launch(std.testing.allocator, &.{"--"}, &.{null}));
    try std.testing.expectEqual(127, launch(std.testing.allocator, &.{"-h"}, &.{null}));
}
