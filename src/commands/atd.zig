//! Foreground same-user scheduler runner.
const std = @import("std");
const linux = std.os.linux;
const proc = @import("../shell/process.zig");
const spool_mod = @import("../common/at_spool.zig");
const mail = @import("../common/at_mail.zig");
const clock = @import("../common/at_clock.zig");
const Allocator = std.mem.Allocator;
const Fd = linux.fd_t;

pub fn run(_: Allocator, _: []const [:0]const u8) u8 {
    return fail("requires startup context");
}

pub fn launch(allocator: Allocator, args: []const [:0]const u8, _: proc.Vector) u8 {
    if (args.len != 0) return fail("no options or operands are accepted");
    service(allocator) catch |err| {
        return fail(switch (err) {
            error.ElevatedCredentials => "scheduler does not support setuid or setgid execution",
            error.LockBusy => "scheduler already running for this account",
            else => @errorName(err),
        });
    };
    return 0;
}

fn fail(message: []const u8) u8 {
    std.debug.print("atd: {s}\n", .{message});
    return 1;
}

fn service(allocator: Allocator) !void {
    var spool = try spool_mod.Spool.open(allocator);
    defer spool.close();
    const lock = try spool.lockRunner();
    defer proc.close(lock);
    try spool.quarantineRunning();
    // A supervisor may have ignored SIGCHLD; waitpid requires waitable children.
    const action: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    if (linux.errno(linux.sigaction(.CHLD, &action, null)) != .SUCCESS) return error.SignalSetup;
    while (true) {
        const now = try clock.now();
        var load: linux.Sysinfo = undefined;
        const allow_batch = linux.errno(linux.sysinfo(&load)) == .SUCCESS and load.loads[0] < 98304; // 1.5 in Linux's 16-bit fixed point
        const worked = try cycle(allocator, &spool, now, allow_batch);
        if (!worked) {
            var delay: linux.timespec = .{ .sec = 10, .nsec = 0 };
            while (linux.errno(linux.nanosleep(&delay, &delay)) == .INTR) {}
        }
    }
}

/// One scheduling pass, with caller-supplied clock and batch eligibility.
pub fn cycle(allocator: Allocator, spool: *spool_mod.Spool, now: i64, allow_batch: bool) !bool {
    const finished = try spool.finished(allocator);
    defer allocator.free(finished);
    for (finished) |id| deliverFinished(allocator, spool, id) catch |err| {
        std.debug.print("atd: {s}: delivery: {s}\n", .{ &id, @errorName(err) });
    };
    const job = (try spool.claim(now, allow_batch)) orelse return false;
    try execute(allocator, spool, job.id);
    deliverFinished(allocator, spool, job.id) catch |err| {
        std.debug.print("atd: {s}: delivery: {s}\n", .{ &job.id, @errorName(err) });
    };
    return true;
}

fn createFile(dir: Fd, name: [*:0]const u8) !Fd {
    const old_mask = linux.syscall1(.umask, 0o077);
    const rc = linux.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    _ = linux.syscall1(.umask, old_mask);
    if (linux.errno(rc) != .SUCCESS) return error.CreateFailed;
    const fd: Fd = @intCast(rc);
    errdefer proc.close(fd);
    if (linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.CreateFailed;
    return fd;
}

fn execute(allocator: Allocator, spool: *spool_mod.Spool, id: spool_mod.Id) !void {
    const dir = try spool.openRunning(id);
    defer proc.close(dir);
    var context = try spool_mod.loadContext(allocator, dir);
    defer context.deinit(allocator);
    const script = try spool_mod.openRecordFile(dir, "script");
    defer proc.close(script);
    const output = try createFile(dir, "output");
    defer proc.close(output);
    const pipe = try proc.pipe();
    defer proc.close(pipe[0]);
    var write_open = true;
    defer if (write_open) proc.close(pipe[1]);
    const nullfd = try proc.open("/dev/null", .{});
    defer proc.close(nullfd);
    // Keep source descriptors away from 0-3 while installing child descriptors.
    const child_script = try proc.save(script, 4);
    defer proc.close(child_script);
    const child_output = try proc.save(pipe[1], 4);
    var child_output_open = true;
    defer if (child_output_open) proc.close(child_output);
    const child_null = try proc.save(nullfd, 4);
    defer proc.close(child_null);
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    if (rc == 0) {
        if (linux.errno(linux.setsid()) != .SUCCESS or linux.errno(linux.chdir(context.cwd)) != .SUCCESS) linux.exit(125);
        const unblocked = linux.sigemptyset();
        if (linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &unblocked, null)) != .SUCCESS) linux.exit(125);
        const defaults: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        for ([_]linux.SIG{ .HUP, .INT, .QUIT, .TERM, .PIPE, .XFSZ, .CHLD }) |sig| {
            if (linux.errno(linux.sigaction(sig, &defaults, null)) != .SUCCESS) linux.exit(125);
        }
        const limits: linux.rlimit = .{ .cur = context.fsize_current, .max = context.fsize_max };
        if (linux.errno(linux.setrlimit(.FSIZE, &limits)) != .SUCCESS) linux.exit(125);
        _ = linux.syscall1(.umask, context.umask);
        proc.dup(child_null, 0) catch linux.exit(125);
        proc.dup(child_output, 1) catch linux.exit(125);
        proc.dup(child_output, 2) catch linux.exit(125);
        proc.dup(child_script, 3) catch linux.exit(125);
        if (linux.errno(linux.fcntl(3, linux.F.SETFD, 0)) != .SUCCESS) linux.exit(125);
        closeExtra() catch linux.exit(125);
        const argv = [_:null]?[*:0]const u8{ "zosixutils", "sh", "--zosix-at-source", "3", "/proc/self/fd/3" };
        _ = linux.execve("/proc/self/exe", &argv, context.env.ptr);
        linux.exit(125);
    }
    proc.close(pipe[1]);
    write_open = false;
    proc.close(child_output);
    child_output_open = false;
    // The shell can leave background descendants holding stdout. Drain to EOF
    // before completing the record, rather than discarding their later output.
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = proc.read(pipe[0], &buf) catch {
            terminate(@intCast(rc));
            return error.CaptureFailed;
        };
        if (n == 0) break;
        proc.write(output, buf[0..n]) catch {
            terminate(@intCast(rc));
            return error.CaptureFailed;
        };
    }
    const status = try proc.wait(@intCast(rc));
    if (linux.errno(linux.fsync(output)) != .SUCCESS) return error.SyncFailed;
    const status_fd = try createFile(dir, "status");
    defer proc.close(status_fd);
    var status_buf: [8]u8 = undefined;
    try proc.write(status_fd, try std.fmt.bufPrint(&status_buf, "{d}\n", .{status}));
    if (linux.errno(linux.fsync(status_fd)) != .SUCCESS or linux.errno(linux.fsync(dir)) != .SUCCESS) return error.SyncFailed;
    try spool.finish(id);
}

fn terminate(pid: linux.pid_t) void {
    _ = linux.kill(-pid, .KILL);
    _ = linux.kill(pid, .KILL);
    _ = proc.wait(pid) catch {};
}

fn closeExtra() !void {
    if (linux.errno(linux.close_range(4, -1, .{ .UNSHARE = false, .CLOEXEC = false })) == .SUCCESS) return;
    const rc = linux.openat(linux.AT.FDCWD, "/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.CloseFailed;
    const dir: Fd = @intCast(rc);
    defer proc.close(dir);
    var buf: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(dir, &buf, buf.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.CloseFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            if (ent.reclen < @offsetOf(linux.dirent64, "name") + 1 or off + ent.reclen > n) return error.CloseFailed;
            const name = buf[off + @offsetOf(linux.dirent64, "name") .. off + ent.reclen];
            const len = std.mem.indexOfScalar(u8, name, 0) orelse return error.CloseFailed;
            const fd = std.fmt.parseInt(Fd, name[0..len], 10) catch -1;
            if (fd >= 4 and fd != dir) proc.close(fd);
            off += ent.reclen;
        }
    }
}

fn deliverFinished(allocator: Allocator, spool: *spool_mod.Spool, id: spool_mod.Id) !void {
    const dir = try spool.openFinished(id);
    defer proc.close(dir);
    var context = try spool_mod.loadContext(allocator, dir);
    defer context.deinit(allocator);
    const status_fd = try spool_mod.openRecordFile(dir, "status");
    defer proc.close(status_fd);
    var buf: [8]u8 = undefined;
    const n = try proc.read(status_fd, &buf);
    if (n < 2 or n == buf.len or buf[n - 1] != '\n' or try proc.read(status_fd, buf[n..]) != 0) return error.InvalidStatus;
    const status = std.fmt.parseInt(u8, buf[0 .. n - 1], 10) catch return error.InvalidStatus;
    const output = try spool_mod.openRecordFile(dir, "output");
    defer proc.close(output);
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(output, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat)) != .SUCCESS or !stat.mask.SIZE) return error.StatFailed;
    if (context.mail or stat.size != 0) try mail.deliver(spool.account.home, spool.account.name, &id, status, output);
    try spool.removeFinished(id);
}

test "atd: cycle respects injected clock and retains failed delivery" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = linux.openat(tmp.dir.handle, ".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const tmp_fd: Fd = @intCast(raw);
    defer proc.close(tmp_fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(tmp_fd, 0o700)));
    var spool = try spool_mod.Spool.openDir(allocator, tmp.dir.handle);
    defer spool.close();
    const script = try proc.hereDoc(":\n");
    defer proc.close(script);
    const id = try spool.submit(100, 'b', true, script, &.{null});
    try std.testing.expect(!try cycle(allocator, &spool, 99, true));
    try std.testing.expect(!try cycle(allocator, &spool, 100, false));
    const job = (try spool.claim(100, true)).?;
    try std.testing.expectEqualSlices(u8, &id, &job.id);
    const dir = try spool.openRunning(id);
    const output = try createFile(dir, "output");
    try proc.write(output, "saved output\n");
    proc.close(output);
    const status = try createFile(dir, "status");
    try proc.write(status, "0\n");
    proc.close(status);
    proc.close(dir);
    try spool.finish(id);

    const original_home = spool.account.home;
    spool.account.home = try allocator.dupe(u8, "/nonexistent-at-mail-home");
    defer {
        allocator.free(spool.account.home);
        spool.account.home = original_home;
    }
    try std.testing.expect(!try cycle(allocator, &spool, 100, true));
    try std.testing.expect(!try cycle(allocator, &spool, 100, true));
    const finished = try spool.finished(allocator);
    defer allocator.free(finished);
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqualSlices(u8, &id, &finished[0]);
    const pending = try spool.list(allocator);
    defer allocator.free(pending);
    try std.testing.expectEqual(@as(usize, 0), pending.len);
}
