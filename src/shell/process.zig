//! Linux process and descriptor operations used by the single-threaded shell.
const std = @import("std");
pub const linux = std.os.linux;
pub const Fd = linux.fd_t;
pub const Pid = linux.pid_t;
pub const Vector = [*:null]const ?[*:0]const u8;

pub fn fork(signals: *const Signals) !Pid {
    var old: linux.sigset_t = undefined;
    if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &signalMask(), &old)) != .SUCCESS)
        return error.SignalMask;
    const rc = linux.fork();
    if (rc == 0) signals.restoreChild();
    if (linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &old, null)) != .SUCCESS and rc == 0)
        linux.exit(125);
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    return @intCast(rc);
}

pub fn exec(path: [:0]const u8, argv: Vector, envp: Vector) linux.E {
    return linux.errno(linux.execve(path, argv, envp));
}

pub fn wait(pid: Pid) !u8 {
    while (true) {
        var raw: i32 = undefined;
        switch (linux.errno(linux.waitpid(pid, &raw, 0))) {
            .INTR => continue,
            .SUCCESS => {
                const status: u32 = @bitCast(raw);
                if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
                if (linux.W.IFSIGNALED(status)) return 128 + @as(u8, @intCast(@backingInt(linux.W.TERMSIG(status))));
            },
            else => return error.WaitFailed,
        }
    }
}

pub fn cancel(pid: Pid) void {
    _ = linux.kill(pid, .KILL);
}

pub fn pipe() ![2]Fd {
    var fds: [2]Fd = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    return fds;
}

pub fn close(fd: Fd) void {
    // Linux releases the number even when close reports EINTR.
    _ = linux.close(fd);
}

pub fn flags(fd: Fd) !usize {
    const rc = linux.fcntl(fd, linux.F.GETFD, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .BADF => error.BadDescriptor,
        else => error.DescriptorFailed,
    };
}

pub fn save(fd: Fd, minimum: Fd) !Fd {
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, @intCast(minimum));
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .BADF => error.BadDescriptor,
        else => error.DescriptorFailed,
    };
}

pub fn dup(old: Fd, new: Fd) !void {
    if (old == new) {
        _ = try flags(old);
        return;
    }
    if (linux.errno(linux.dup2(old, new)) != .SUCCESS) return error.BadDescriptor;
}

/// Install an owned close-on-exec descriptor and consume it even on failure.
pub fn install(fd: Fd, target: Fd) !void {
    if (fd == target) {
        if (linux.errno(linux.fcntl(target, linux.F.SETFD, 0)) == .SUCCESS) return;
        close(fd);
        return error.DescriptorFailed;
    }
    defer close(fd);
    try dup(fd, target);
}

pub fn open(path: [:0]const u8, options: linux.O) !Fd {
    var opts = options;
    opts.CLOEXEC = true;
    while (true) {
        const rc = linux.openat(linux.AT.FDCWD, path, opts, 0o666);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.OpenFailed,
        }
    }
}

pub fn readOnce(fd: Fd, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        else => error.ReadFailed,
    };
}

pub fn read(fd: Fd, buf: []u8) !usize {
    while (true) return readOnce(fd, buf) catch |err| switch (err) {
        error.Interrupted => continue,
        else => return err,
    };
}

pub fn write(fd: Fd, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len != 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                rest = rest[rc..];
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub fn hereDoc(bytes: []const u8) !Fd {
    const rc = linux.memfd_create("sh-here-doc", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: Fd = @intCast(rc);
    errdefer close(fd);
    try write(fd, bytes);
    try rewind(fd);
    return fd;
}

pub fn rewind(fd: Fd) !void {
    var offset: linux.off_t = undefined;
    const rc = if (@sizeOf(usize) == 4) linux.llseek(fd, 0, &offset, linux.SEEK.SET) else linux.lseek(fd, 0, linux.SEEK.SET);
    if (linux.errno(rc) != .SUCCESS) return error.SeekFailed;
}

const changed_signals = [_]linux.SIG{ .INT, .QUIT, .TERM, .CHLD };
var interrupted: u8 = 0;

fn handleInterrupt(_: linux.SIG) callconv(.c) void {
    const flag: *volatile u8 = &interrupted;
    flag.* = 1;
}

pub fn takeInterrupt() bool {
    const flag: *volatile u8 = &interrupted;
    if (flag.* == 0) return false;
    flag.* = 0;
    return true;
}

pub fn isInterrupted() bool {
    const flag: *const volatile u8 = &interrupted;
    return flag.* != 0;
}

fn signalMask() linux.sigset_t {
    var set = linux.sigemptyset();
    for (changed_signals) |sig| linux.sigaddset(&set, sig);
    return set;
}

pub const Signals = struct {
    original: [changed_signals.len]linux.Sigaction,
    changed: [changed_signals.len]bool = @splat(false),

    pub fn init(interactive: bool) !Signals {
        var self: Signals = .{ .original = undefined };
        errdefer self.deinit();
        for (changed_signals, 0..) |sig, i| {
            if (linux.errno(linux.sigaction(sig, null, &self.original[i])) != .SUCCESS) return error.SignalSetup;
            if (sig != .CHLD and !interactive) continue;
            try installHandler(sig);
            self.changed[i] = true;
        }
        return self;
    }

    pub fn deinit(self: *const Signals) void {
        for (changed_signals, self.changed, &self.original) |sig, changed, *action|
            if (changed) {
                _ = linux.sigaction(sig, action, null);
            };
    }

    pub fn restoreChild(self: *const Signals) void {
        for (changed_signals, self.changed, &self.original) |sig, changed, *action|
            if (changed and sig != .CHLD) {
                if (linux.errno(linux.sigaction(sig, action, null)) != .SUCCESS) linux.exit(125);
            };
    }

    pub fn exec(self: *const Signals, path: [:0]const u8, argv: Vector, envp: Vector, replace_interactive: bool) linux.E {
        for (changed_signals, self.changed, &self.original) |sig, changed, *action| {
            if (changed and (sig == .CHLD or replace_interactive)) _ = linux.sigaction(sig, action, null);
        }
        const result = linux.errno(linux.execve(path, argv, envp));
        for (changed_signals, self.changed) |sig, changed| {
            if (changed and (sig == .CHLD or replace_interactive)) installHandler(sig) catch linux.exit(125);
        }
        return result;
    }
};

fn installHandler(sig: linux.SIG) !void {
    const handler: ?linux.Sigaction.handler_fn = switch (sig) {
        .INT => handleInterrupt,
        .QUIT, .TERM => linux.SIG.IGN,
        .CHLD => linux.SIG.DFL,
        else => unreachable,
    };
    const action: linux.Sigaction = .{ .handler = .{ .handler = handler }, .flags = 0, .mask = linux.sigemptyset() };
    if (linux.errno(linux.sigaction(sig, &action, null)) != .SUCCESS) return error.SignalSetup;
}

pub fn terminal(fd: Fd) bool {
    var termios: linux.termios = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&termios))) == .SUCCESS;
}

pub fn interactiveRead(fd: Fd, buf: []u8) !usize {
    var blocked = linux.sigemptyset();
    linux.sigaddset(&blocked, .INT);
    var old: linux.sigset_t = undefined;
    if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &blocked, &old)) != .SUCCESS) return error.SignalMask;
    defer _ = linux.sigprocmask(linux.SIG.SETMASK, &old, null);
    var pfd: linux.pollfd = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    while (!isInterrupted()) {
        switch (linux.errno(linux.ppoll(@ptrCast(&pfd), 1, null, &old))) {
            .SUCCESS => {
                // A terminal can flush readable input on SIGINT after ppoll returns.
                // Do not enter a blocking read with that signal masked.
                const current = linux.fcntl(fd, linux.F.GETFL, 0);
                if (linux.errno(current) != .SUCCESS) return error.ReadFailed;
                const nonblock = @as(usize, 1) << @bitOffsetOf(linux.O, "NONBLOCK");
                if (linux.errno(linux.fcntl(fd, linux.F.SETFL, current | nonblock)) != .SUCCESS) return error.ReadFailed;
                defer _ = linux.fcntl(fd, linux.F.SETFL, current);
                return readOnce(fd, buf) catch |err| switch (err) {
                    error.WouldBlock, error.Interrupted => continue,
                    else => return err,
                };
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return error.Interrupted;
}

pub fn normalizeInput(fd: Fd) void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    var opts: linux.O = @bitCast(@as(u32, @truncate(rc)));
    if (!opts.NONBLOCK) return;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat)) != .SUCCESS) return;
    if (!linux.S.ISFIFO(stat.mode) and !terminal(fd)) return;
    opts.NONBLOCK = false;
    _ = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(opts)));
}

test "sh: fork and exec with explicit arguments and environment" {
    const signals = try Signals.init(false);
    defer signals.deinit();
    const pid = try fork(&signals);
    if (pid == 0) {
        _ = exec("/bin/true", &.{ "sh-test", null }, &.{ "PATH=/nonexistent", null });
        linux.exit(125);
    }
    try std.testing.expectEqual(0, try wait(pid));
}

test "sh: two children share a pipe and unrelated ends do not stay open" {
    const signals = try Signals.init(false);
    defer signals.deinit();
    const fds = try pipe();
    const producer = try fork(&signals);
    if (producer == 0) {
        close(fds[0]);
        write(fds[1], "pipe") catch linux.exit(1);
        close(fds[1]);
        linux.exit(0);
    }
    const consumer = try fork(&signals);
    if (consumer == 0) {
        close(fds[1]);
        var buf: [8]u8 = undefined;
        const n = read(fds[0], &buf) catch linux.exit(1);
        if (!std.mem.eql(u8, buf[0..n], "pipe")) linux.exit(2);
        linux.exit(if ((read(fds[0], &buf) catch linux.exit(3)) == 0) 7 else 4);
    }
    close(fds[0]);
    close(fds[1]);
    try std.testing.expectEqual(0, try wait(producer));
    try std.testing.expectEqual(7, try wait(consumer));
}

test "sh: wait decodes a signal and same-descriptor duplication validates the descriptor" {
    const signals = try Signals.init(false);
    defer signals.deinit();
    const pid = try fork(&signals);
    if (pid == 0) {
        cancel(linux.getpid());
        linux.exit(1);
    }
    try std.testing.expectEqual(137, try wait(pid));
    const fds = try pipe();
    defer close(fds[0]);
    try dup(fds[0], fds[0]);
    close(fds[1]);
    try std.testing.expectError(error.BadDescriptor, dup(fds[1], fds[1]));
}
