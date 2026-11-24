//! Account and administrator policy lookup for the same-user scheduler.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Account = struct {
    name: []u8,
    home: []u8,

    pub fn deinit(self: *Account, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.home);
        self.* = undefined;
    }
};

fn openAt(dir: linux.fd_t, path: [*:0]const u8, directory: bool) !?linux.fd_t {
    const rc = linux.openat(dir, path, .{
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .DIRECTORY = directory,
    }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @as(linux.fd_t, @intCast(rc)),
        .NOENT => null,
        else => error.OpenFailed,
    };
}

fn verify(fd: linux.fd_t, owner: u32, directory: bool) !void {
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat)) != .SUCCESS)
        return error.StatFailed;
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID) return error.StatFailed;
    if (stat.uid != owner or stat.mode & 0o022 != 0) return error.UnsafeOwnershipOrMode;
    if (if (directory) !linux.S.ISDIR(stat.mode) else !linux.S.ISREG(stat.mode))
        return error.UnsafeFileType;
}

fn readBounded(allocator: Allocator, fd: linux.fd_t, limit: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => {},
            else => return error.ReadFailed,
        }
        if (rc == 0) break;
        if (rc > limit - result.items.len) return error.FileTooLarge;
        try result.appendSlice(allocator, buf[0..rc]);
    }
    return result.toOwnedSlice(allocator);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    for (name) |c| if (c <= 0x20 or c >= 0x7f or c == ':' or c == '/') {
        return false;
    };
    return true;
}

fn accountFromBytes(allocator: Allocator, data: []const u8, uid: u32) !Account {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid_text = fields.next() orelse continue;
        const entry_uid = std.fmt.parseInt(u32, uid_text, 10) catch continue;
        if (entry_uid != uid) continue;
        _ = fields.next() orelse return error.InvalidAccount;
        _ = fields.next() orelse return error.InvalidAccount;
        const home = fields.next() orelse return error.InvalidAccount;
        _ = fields.next() orelse return error.InvalidAccount;
        if (!validName(name) or home.len == 0 or home[0] != '/' or home.len > 4095)
            return error.InvalidAccount;
        for (home) |c| if (c == 0 or c == '\n' or c == '\r') return error.InvalidAccount;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        return .{ .name = owned_name, .home = try allocator.dupe(u8, home) };
    }
    return error.AccountNotFound;
}

/// Resolve the effective UID through the administrator-owned local account file.
pub fn resolve(allocator: Allocator) !Account {
    if (linux.getuid() != linux.geteuid() or linux.getgid() != linux.getegid()) return error.ElevatedCredentials;
    const etc = (try openAt(linux.AT.FDCWD, "/etc", true)) orelse return error.AccountNotFound;
    defer _ = linux.close(etc);
    try verify(etc, 0, true);
    const fd = (try openAt(etc, "passwd", false)) orelse return error.AccountNotFound;
    defer _ = linux.close(fd);
    try verify(fd, 0, false);
    const data = try readBounded(allocator, fd, 1024 * 1024);
    defer allocator.free(data);
    return accountFromBytes(allocator, data, linux.geteuid());
}

fn containsName(data: []const u8, name: []const u8) !bool {
    if (std.mem.indexOfScalar(u8, data, 0) != null) return error.InvalidPolicy;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!validName(line)) return error.InvalidPolicy;
        if (std.mem.eql(u8, line, name)) found = true;
    }
    return found;
}

fn readPolicy(allocator: Allocator, dir: linux.fd_t, name: [*:0]const u8, owner: u32) !?[]u8 {
    const fd = (try openAt(dir, name, false)) orelse return null;
    defer _ = linux.close(fd);
    try verify(fd, owner, false);
    return try readBounded(allocator, fd, 64 * 1024);
}

// The caller verifies the directory. The owner argument permits private test fixtures.
fn checkAt(allocator: Allocator, dir: linux.fd_t, name: []const u8, uid: u32, owner: u32) !void {
    if (try readPolicy(allocator, dir, "at.allow", owner)) |allow| {
        defer allocator.free(allow);
        if (!try containsName(allow, name)) return error.SubmissionDenied;
        return;
    }
    if (try readPolicy(allocator, dir, "at.deny", owner)) |deny| {
        defer allocator.free(deny);
        if (try containsName(deny, name)) return error.SubmissionDenied;
        return;
    }
    if (uid != 0) return error.SubmissionDenied;
}

/// Apply allow-file precedence, rejecting unreadable or unsafe policy.
pub fn checkSubmission(allocator: Allocator, account: *const Account) !void {
    const etc = (try openAt(linux.AT.FDCWD, "/etc", true)) orelse return error.OpenFailed;
    defer _ = linux.close(etc);
    try verify(etc, 0, true);
    const dir = (try openAt(etc, "zosixutils", true)) orelse {
        if (linux.geteuid() != 0) return error.SubmissionDenied;
        return;
    };
    defer _ = linux.close(dir);
    try verify(dir, 0, true);
    try checkAt(allocator, dir, account.name, linux.geteuid(), 0);
}

test "at: account parsing uses UID and rejects malformed home" {
    const allocator = std.testing.allocator;
    var account = try accountFromBytes(allocator, "other:x:7:7::/bad:/bin/sh\nalice:x:42:42::/home/alice:/bin/sh\n", 42);
    defer account.deinit(allocator);
    try std.testing.expectEqualStrings("alice", account.name);
    try std.testing.expectEqualStrings("/home/alice", account.home);
    try std.testing.expectError(error.InvalidAccount, accountFromBytes(allocator, "alice:x:42:42::relative:/bin/sh\n", 42));
    try std.testing.expectError(error.AccountNotFound, accountFromBytes(allocator, "", 42));
}

test "at: policy exact names and malformed input" {
    try std.testing.expect(try containsName("alice\nbob\n", "alice"));
    try std.testing.expect(!try containsName("alice\nbob\n", "ali"));
    try std.testing.expect(!try containsName("", "alice"));
    try std.testing.expectError(error.InvalidPolicy, containsName("alice\x00bob", "alice"));
    try std.testing.expectError(error.InvalidPolicy, containsName("alice\nbad name\n", "alice"));
}

test "at: policy precedence, default, and unsafe files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.fd_t = tmp.dir.handle;
    const owner = linux.geteuid();
    try std.testing.expectError(error.SubmissionDenied, checkAt(allocator, dir, "alice", 123, owner));
    try checkAt(allocator, dir, "root", 0, owner);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at.deny", .data = "alice\n" });
    try std.testing.expectError(error.SubmissionDenied, checkAt(allocator, dir, "alice", 123, owner));
    try checkAt(allocator, dir, "bob", 123, owner);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at.allow", .data = "alice\n" });
    try checkAt(allocator, dir, "alice", 123, owner);
    try std.testing.expectError(error.SubmissionDenied, checkAt(allocator, dir, "bob", 123, owner));

    const allow = (try openAt(dir, "at.allow", false)).?;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(allow, 0o666)));
    _ = linux.close(allow);
    try std.testing.expectError(error.UnsafeOwnershipOrMode, checkAt(allocator, dir, "alice", 123, owner));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlinkat(dir, "at.allow", 0)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("at.deny", dir, "at.allow")));
    try std.testing.expectError(error.OpenFailed, checkAt(allocator, dir, "alice", 123, owner));
}
