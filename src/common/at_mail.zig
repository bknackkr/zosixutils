//! Private, retryable local Maildir delivery for completed scheduler jobs.
const std = @import("std");
const linux = std.os.linux;
const Fd = linux.fd_t;

const proc = struct {
    fn close(fd: Fd) void {
        _ = linux.close(fd);
    }
    fn rewind(fd: Fd) !void {
        var off: linux.off_t = undefined;
        const rc = if (@sizeOf(usize) == 4) linux.llseek(fd, 0, &off, linux.SEEK.SET) else linux.lseek(fd, 0, linux.SEEK.SET);
        if (linux.errno(rc) != .SUCCESS) return error.SeekFailed;
    }
    fn read(fd: Fd, buf: []u8) !usize {
        while (true) {
            const rc = linux.read(fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .INTR => continue,
                .SUCCESS => return rc,
                else => return error.ReadFailed,
            }
        }
    }
    fn write(fd: Fd, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            const rc = linux.write(fd, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .INTR => continue,
                .SUCCESS => if (rc == 0) return error.WriteFailed else {
                    rest = rest[rc..];
                },
                else => return error.WriteFailed,
            }
        }
    }
};

fn directory(parent: Fd, name: [*:0]const u8, uid: u32, create: bool, root_allowed: bool) !Fd {
    var created = false;
    if (create) {
        const old_mask = linux.syscall1(.umask, 0o077);
        const rc = linux.mkdirat(parent, name, 0o700);
        _ = linux.syscall1(.umask, old_mask);
        switch (linux.errno(rc)) {
            .SUCCESS => created = true,
            .EXIST => {},
            else => return error.MailDirectory,
        }
    }
    const rc = linux.openat(parent, name, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MailDirectory;
    const fd: Fd = @intCast(rc);
    errdefer proc.close(fd);
    if (created and linux.errno(linux.fchmod(fd, 0o700)) != .SUCCESS) return error.MailDirectory;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat)) != .SUCCESS or
        !stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !linux.S.ISDIR(stat.mode) or
        (stat.uid != uid and !(root_allowed and stat.uid == 0)) or stat.mode & 0o022 != 0)
        return error.UnsafeMailDirectory;
    if (created and (linux.errno(linux.fsync(fd)) != .SUCCESS or linux.errno(linux.fsync(parent)) != .SUCCESS)) return error.MailSync;
    return fd;
}

fn homeDirectory(home: []const u8, uid: u32) !Fd {
    if (home.len == 0 or home[0] != '/') return error.MailDirectory;
    var fd = try directory(linux.AT.FDCWD, "/", uid, false, true);
    errdefer proc.close(fd);
    var parts = std.mem.splitScalar(u8, home[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, 0) != null) return error.MailDirectory;
        var name: [256:0]u8 = @splat(0);
        @memcpy(name[0..part.len], part);
        const next = try directory(fd, &name, uid, false, true);
        proc.close(fd);
        fd = next;
    }
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat)) != .SUCCESS or stat.uid != uid) return error.UnsafeMailDirectory;
    return fd;
}

// Mail readers move new entries to cur and append flags after ':'.
fn contains(dir: Fd, name: []const u8) !bool {
    var buf: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(dir, &buf, buf.len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.MailRead;
        if (n == 0) return false;
        var offset: usize = 0;
        while (offset < n) {
            const entry: *const linux.dirent64 = @ptrCast(@alignCast(&buf[offset]));
            if (entry.reclen < @offsetOf(linux.dirent64, "name") + 1 or offset + entry.reclen > n) return error.MailRead;
            const raw = buf[offset + @offsetOf(linux.dirent64, "name") .. offset + entry.reclen];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse return error.MailRead;
            offset += entry.reclen;
            const item = raw[0..end :0];
            if (!std.mem.eql(u8, item, name) and !(std.mem.startsWith(u8, item, name) and item.len > name.len and item[name.len] == ':')) continue;
            var stat: linux.Statx = undefined;
            switch (linux.errno(linux.statx(dir, item, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &stat))) {
                .SUCCESS => {},
                .NOENT => continue,
                else => return error.MailRead,
            }
            if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !stat.mask.NLINK or !linux.S.ISREG(stat.mode) or
                stat.uid != linux.geteuid() or stat.mode & 0o077 != 0 or stat.nlink != 1) return error.UnsafeMailMessage;
            return true;
        }
    }
}

/// Publish once under a job-derived name; existing entries in new or cur mean delivery succeeded.
pub fn deliver(home: []const u8, account: []const u8, id: []const u8, status: u8, output: Fd) !void {
    if (id.len != 32) return error.InvalidJob;
    for (id) |c| if (!std.ascii.isAlphanumeric(c)) return error.InvalidJob;
    for (account) |c| if (c <= 0x20 or c >= 0x7f or c == ':') return error.InvalidAccount;
    const uid = linux.geteuid();
    const home_fd = try homeDirectory(home, uid);
    defer proc.close(home_fd);
    try deliverAt(home_fd, uid, account, id, status, output);
}

fn deliverAt(home_fd: Fd, uid: u32, account: []const u8, id: []const u8, status: u8, output: Fd) !void {
    const maildir = try directory(home_fd, "Maildir", uid, true, false);
    defer proc.close(maildir);
    const tmp = try directory(maildir, "tmp", uid, true, false);
    defer proc.close(tmp);
    const new = try directory(maildir, "new", uid, true, false);
    defer proc.close(new);
    const cur = try directory(maildir, "cur", uid, true, false);
    defer proc.close(cur);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "zosix-at-{s}", .{id}, 0);
    if (try contains(new, name) or try contains(cur, name)) {
        if (linux.errno(linux.fsync(new)) != .SUCCESS or linux.errno(linux.fsync(cur)) != .SUCCESS or linux.errno(linux.fsync(tmp)) != .SUCCESS) return error.MailSync;
        return;
    }

    // A previous incomplete attempt can leave its private staging file behind.
    switch (linux.errno(linux.unlinkat(tmp, name, 0))) {
        .SUCCESS, .NOENT => {},
        else => return error.MailWrite,
    }
    const old_mask = linux.syscall1(.umask, 0o077);
    const rc = linux.openat(tmp, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    _ = linux.syscall1(.umask, old_mask);
    if (linux.errno(rc) != .SUCCESS) return error.MailWrite;
    const fd: Fd = @intCast(rc);
    defer proc.close(fd);
    errdefer _ = linux.unlinkat(tmp, name, 0);
    if (linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.MailWrite;
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "To: {s}\nSubject: at job {s} completed\n\nJob {s} exited with status {d}.\n\n", .{ account, id, id, status });
    try proc.write(fd, header);
    try proc.rewind(output);
    var buffer: [16384]u8 = undefined;
    while (true) {
        const n = try proc.read(output, &buffer);
        if (n == 0) break;
        try proc.write(fd, buffer[0..n]);
    }
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.MailSync;
    switch (linux.errno(linux.renameat2(tmp, name, new, name, .{ .NOREPLACE = true }))) {
        .SUCCESS => {},
        .EXIST => {
            if (!try contains(new, name) and !try contains(cur, name)) return error.MailWrite;
            _ = linux.unlinkat(tmp, name, 0);
            if (linux.errno(linux.fsync(new)) != .SUCCESS or linux.errno(linux.fsync(cur)) != .SUCCESS or linux.errno(linux.fsync(tmp)) != .SUCCESS) return error.MailSync;
            return;
        },
        else => return error.MailWrite,
    }
    if (linux.errno(linux.fsync(new)) != .SUCCESS or linux.errno(linux.fsync(tmp)) != .SUCCESS) return error.MailSync;
}

test "at: Maildir publishes once and recognizes moved messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try directory(tmp.dir.handle, ".", linux.geteuid(), false, false);
    defer proc.close(home);
    const rc = linux.memfd_create("at-mail-test", linux.MFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const output: Fd = @intCast(rc);
    defer proc.close(output);
    try proc.write(output, "captured\n");
    const id = "0123456789abcdef0123456789abcdef";
    const old_mask = linux.syscall1(.umask, 0o777);
    const first = deliverAt(home, linux.geteuid(), "tester", id, 7, output);
    _ = linux.syscall1(.umask, old_mask);
    try first;
    try deliverAt(home, linux.geteuid(), "tester", id, 7, output);
    const md = try directory(home, "Maildir", linux.geteuid(), false, false);
    defer proc.close(md);
    const new = try directory(md, "new", linux.geteuid(), false, false);
    defer proc.close(new);
    const cur = try directory(md, "cur", linux.geteuid(), false, false);
    defer proc.close(cur);
    const name = "zosix-at-0123456789abcdef0123456789abcdef";
    const rc_message = linux.openat(new, name, .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc_message));
    const message: Fd = @intCast(rc_message);
    defer proc.close(message);
    var stat: linux.Statx = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.statx(message, "", linux.AT.EMPTY_PATH, .{ .MODE = true }, &stat)));
    try std.testing.expectEqual(@as(u16, 0o600), stat.mode & 0o777);
    var content: [512]u8 = undefined;
    const count = try proc.read(message, &content);
    try std.testing.expect(std.mem.indexOf(u8, content[0..count], "status 7.\n\ncaptured\n") != null);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.renameat2(new, name, cur, name ++ ":2,S", .{})));
    try deliverAt(home, linux.geteuid(), "tester", id, 7, output);
    const fresh = try directory(md, "new", linux.geteuid(), false, false);
    defer proc.close(fresh);
    try std.testing.expect(!try contains(fresh, name));
    const moved = try directory(md, "cur", linux.geteuid(), false, false);
    defer proc.close(moved);
    try std.testing.expect(try contains(moved, name));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("missing", new, name)));
    try std.testing.expectError(error.UnsafeMailMessage, deliverAt(home, linux.geteuid(), "tester", id, 7, output));
}
