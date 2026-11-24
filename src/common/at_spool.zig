//! Durable private records for the same-user scheduler.
const std = @import("std");
const linux = std.os.linux;
const account = @import("at_account.zig");

const Fd = linux.fd_t;
pub const Id = [32]u8;
pub const Job = struct { id: Id, due: i64, queue: u8 };
pub const Context = struct {
    cwd: [:0]const u8,
    env: [:null]const ?[*:0]const u8,
    umask: linux.mode_t,
    fsize_current: u64,
    fsize_max: u64,
    mail: bool,

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        for (self.env) |item| if (item) |value| allocator.free(std.mem.span(value));
        allocator.free(self.env);
        self.* = undefined;
    }
};

const max_meta = 1024 * 1024;
const max_script = 16 * 1024 * 1024;
const header_len = 48;
const Meta = struct { job: Job, context: Context };

pub fn validateId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn nameId(id: []const u8) ![33:0]u8 {
    if (!validateId(id)) return error.InvalidId;
    var name: [33:0]u8 = @splat(0);
    @memcpy(name[0..32], id);
    return name;
}

fn sync(fd: Fd) !void {
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.SyncFailed;
}

fn writeAll(fd: Fd, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => {},
            else => return error.WriteFailed,
        }
        if (rc == 0) return error.WriteFailed;
        off += rc;
    }
}

fn readAll(allocator: std.mem.Allocator, fd: Fd, limit: usize) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        switch (linux.errno(n)) {
            .INTR => continue,
            .SUCCESS => {},
            else => return error.ReadFailed,
        }
        if (n == 0) break;
        if (n > limit - data.items.len) return error.FileTooLarge;
        try data.appendSlice(allocator, buf[0..n]);
    }
    return data.toOwnedSlice(allocator);
}

fn verifyFile(fd: Fd) !linux.Statx {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st)) != .SUCCESS or
        !st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.NLINK or !st.mask.SIZE) return error.StatFailed;
    if (!linux.S.ISREG(st.mode) or st.uid != linux.geteuid() or st.mode & 0o077 != 0 or st.nlink != 1)
        return error.UnsafeFile;
    return st;
}

/// Open a private regular record file without following symlinks.
pub fn openRecordFile(dir: Fd, name: [*:0]const u8) !Fd {
    const component = std.mem.span(name);
    if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or std.mem.indexOfScalar(u8, component, '/') != null)
        return error.InvalidName;
    const rc = linux.openat(dir, name, .{ .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: Fd = @intCast(rc);
    errdefer _ = linux.close(fd);
    _ = try verifyFile(fd);
    return fd;
}

fn createFile(dir: Fd, name: [*:0]const u8) !Fd {
    const rc = linux.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.CreateFailed;
    const fd: Fd = @intCast(rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.ChmodFailed;
    _ = try verifyFile(fd);
    return fd;
}

fn recordDir(parent: Fd, id: []const u8) !Fd {
    const name = try nameId(id);
    const fd = try openDirectory(parent, &name);
    errdefer _ = linux.close(fd);
    try verifyDirectory(fd, linux.geteuid(), false, true);
    return fd;
}

fn moveRecord(from: Fd, to: Fd, id: []const u8) !void {
    const name = try nameId(id);
    if (linux.errno(linux.renameat2(from, &name, to, &name, .{ .NOREPLACE = true })) != .SUCCESS) return error.RenameFailed;
    try sync(from);
    try sync(to);
}

fn removeRecord(parent: Fd, id: []const u8) !void {
    const dir = try recordDir(parent, id);
    defer _ = linux.close(dir);
    // Never recursively follow or erase unknown files in a record.
    for ([_][*:0]const u8{ "script", "meta", "output", "status" }) |file| {
        switch (linux.errno(linux.unlinkat(dir, file, 0))) {
            .SUCCESS, .NOENT => {},
            else => return error.RemoveFailed,
        }
    }
    try sync(dir);
    const name = try nameId(id);
    if (linux.errno(linux.unlinkat(parent, &name, linux.AT.REMOVEDIR)) != .SUCCESS) return error.RemoveFailed;
    try sync(parent);
}

fn randomId() !Id {
    var raw: [16]u8 = undefined;
    var off: usize = 0;
    while (off < raw.len) {
        const rc = linux.getrandom(raw[off..].ptr, raw.len - off, 0);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => {},
            else => return error.RandomFailed,
        }
        if (rc == 0) return error.RandomFailed;
        off += rc;
    }
    const hex = "0123456789abcdef";
    var id: Id = undefined;
    for (raw, 0..) |b, i| {
        id[i * 2] = hex[b >> 4];
        id[i * 2 + 1] = hex[b & 15];
    }
    return id;
}

fn currentUmask(allocator: std.mem.Allocator) !linux.mode_t {
    const rc = linux.openat(linux.AT.FDCWD, "/proc/self/status", .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ContextFailed;
    const fd: Fd = @intCast(rc);
    defer _ = linux.close(fd);
    const bytes = try readAll(allocator, fd, 128 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Umask:")) continue;
        const value = std.mem.trim(u8, line[6..], " \t\r");
        const mask = std.fmt.parseInt(linux.mode_t, value, 8) catch return error.ContextFailed;
        if (mask > 0o777) return error.ContextFailed;
        return mask;
    }
    return error.ContextFailed;
}

fn makeMeta(allocator: std.mem.Allocator, due: i64, queue: u8, mail: bool, env: [*:null]const ?[*:0]const u8) ![]u8 {
    if (queue != 'a' and queue != 'b') return error.InvalidQueue;
    var cwd: [4096]u8 = undefined;
    const n = linux.getcwd(&cwd, cwd.len);
    if (linux.errno(n) != .SUCCESS or n < 2 or n > cwd.len or cwd[n - 1] != 0 or cwd[0] != '/') return error.ContextFailed;
    var lim: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.FSIZE, &lim)) != .SUCCESS) return error.ContextFailed;
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    try data.appendSlice(allocator, &@as([header_len]u8, @splat(0)));
    try data.appendSlice(allocator, cwd[0..n]);
    var count: u32 = 0;
    while (env[count]) |entry| : (count += 1) {
        if (count >= 65536) return error.ContextTooLarge;
        const value = std.mem.span(entry);
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, '=') == null or value[0] == '=') return error.InvalidEnvironment;
        if (value.len + 1 > max_meta - data.items.len) return error.ContextTooLarge;
        try data.appendSlice(allocator, value);
        try data.append(allocator, 0);
    }
    const h = data.items[0..header_len];
    @memcpy(h[0..4], "AT01");
    h[4] = queue;
    h[5] = @intFromBool(mail);
    std.mem.writeInt(i64, h[8..16], due, .little);
    std.mem.writeInt(u32, h[16..20], try currentUmask(allocator), .little);
    std.mem.writeInt(u32, h[20..24], @intCast(n), .little);
    std.mem.writeInt(u32, h[24..28], count, .little);
    std.mem.writeInt(u64, h[32..40], lim.cur, .little);
    std.mem.writeInt(u64, h[40..48], lim.max, .little);
    return data.toOwnedSlice(allocator);
}

fn parseMeta(allocator: std.mem.Allocator, bytes: []const u8) !Meta {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], "AT01") or
        (bytes[4] != 'a' and bytes[4] != 'b') or bytes[5] > 1 or bytes[6] != 0 or bytes[7] != 0 or
        !std.mem.eql(u8, bytes[28..32], &@as([4]u8, @splat(0)))) return error.InvalidMetadata;
    const mask = std.mem.readInt(u32, bytes[16..20], .little);
    const cwd_len = std.mem.readInt(u32, bytes[20..24], .little);
    const count = std.mem.readInt(u32, bytes[24..28], .little);
    if (mask > 0o777 or cwd_len < 2 or cwd_len > 4096 or count > 65536 or cwd_len > bytes.len - header_len) return error.InvalidMetadata;
    const cwd = bytes[header_len..][0..cwd_len];
    if (cwd[0] != '/' or cwd[cwd.len - 1] != 0 or std.mem.indexOfScalar(u8, cwd[0 .. cwd.len - 1], 0) != null) return error.InvalidMetadata;
    const saved_cwd = try allocator.dupeSentinel(u8, cwd[0 .. cwd.len - 1], 0);
    errdefer allocator.free(saved_cwd);
    const env = try allocator.allocSentinel(?[*:0]const u8, count, null);
    @memset(env, null);
    errdefer {
        for (env) |item| if (item) |value| allocator.free(std.mem.span(value));
        allocator.free(env);
    }
    var pos: usize = header_len + cwd_len;
    for (env) |*entry| {
        if (pos >= bytes.len) return error.InvalidMetadata;
        const end = std.mem.indexOfScalarPos(u8, bytes, pos, 0) orelse return error.InvalidMetadata;
        const value = bytes[pos..end];
        if (value.len == 0 or value[0] == '=' or std.mem.indexOfScalar(u8, value, '=') == null) return error.InvalidMetadata;
        entry.* = (try allocator.dupeSentinel(u8, value, 0)).ptr;
        pos = end + 1;
    }
    if (pos != bytes.len) return error.InvalidMetadata;
    const cur = std.mem.readInt(u64, bytes[32..40], .little);
    const max = std.mem.readInt(u64, bytes[40..48], .little);
    if (cur > max) return error.InvalidMetadata;
    return .{
        .job = .{ .id = undefined, .due = std.mem.readInt(i64, bytes[8..16], .little), .queue = bytes[4] },
        .context = .{ .cwd = saved_cwd, .env = env, .umask = mask, .fsize_current = cur, .fsize_max = max, .mail = bytes[5] == 1 },
    };
}

fn readMeta(allocator: std.mem.Allocator, dir: Fd) !Meta {
    const fd = try openRecordFile(dir, "meta");
    defer _ = linux.close(fd);
    if ((try verifyFile(fd)).size > max_meta) return error.FileTooLarge;
    const bytes = try readAll(allocator, fd, max_meta);
    defer allocator.free(bytes);
    return parseMeta(allocator, bytes);
}

/// The caller owns the supplied arena and all returned context allocations.
pub fn loadContext(allocator: std.mem.Allocator, dir: Fd) !Context {
    return (try readMeta(allocator, dir)).context;
}

fn openDirectory(parent: Fd, name: [*:0]const u8) !Fd {
    const rc = linux.openat(parent, name, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.FileNotFound,
        else => error.OpenFailed,
    };
}

fn mkdirPrivate(parent: Fd, name: [*:0]const u8) linux.E {
    // Scheduler applets are single-threaded; restore the submission mask before reading it.
    const old_mask = linux.syscall1(.umask, 0o077);
    defer _ = linux.syscall1(.umask, old_mask);
    return linux.errno(linux.mkdirat(parent, name, 0o700));
}

fn verifyDirectory(fd: Fd, uid: u32, root_allowed: bool, private: bool) !void {
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat)) != .SUCCESS)
        return error.StatFailed;
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID) return error.StatFailed;
    if (!linux.S.ISDIR(stat.mode) or (stat.uid != uid and (!root_allowed or stat.uid != 0)))
        return error.UnsafeDirectory;
    if (stat.mode & (if (private) @as(u16, 0o077) else 0o022) != 0)
        return error.UnsafeDirectory;
}

fn openHome(path: []const u8, uid: u32) !Fd {
    if (path.len == 0 or path[0] != '/') return error.InvalidHome;
    var current = try openDirectory(linux.AT.FDCWD, "/");
    errdefer _ = linux.close(current);
    try verifyDirectory(current, uid, true, false);
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, 0) != null)
            return error.InvalidHome;
        var name: [256:0]u8 = @splat(0);
        @memcpy(name[0..part.len], part);
        const next = try openDirectory(current, &name);
        verifyDirectory(next, uid, true, false) catch |err| {
            _ = linux.close(next);
            return err;
        };
        _ = linux.close(current);
        current = next;
    }
    try verifyDirectory(current, uid, false, false);
    return current;
}

fn ensureDirectory(parent: Fd, name: [*:0]const u8, uid: u32, private: bool) !Fd {
    const created = switch (mkdirPrivate(parent, name)) {
        .SUCCESS => true,
        .EXIST => false,
        else => return error.CreateFailed,
    };
    const fd = try openDirectory(parent, name);
    errdefer _ = linux.close(fd);
    try verifyDirectory(fd, uid, false, private);
    if (created and (linux.errno(linux.fsync(fd)) != .SUCCESS or linux.errno(linux.fsync(parent)) != .SUCCESS))
        return error.SyncFailed;
    return fd;
}

fn lockFile(dir: Fd, name: [*:0]const u8, nonblocking: bool) !Fd {
    var rc = blk: {
        const old_mask = linux.syscall1(.umask, 0o077);
        defer _ = linux.syscall1(.umask, old_mask);
        break :blk linux.openat(dir, name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    };
    var created = true;
    if (linux.errno(rc) == .EXIST) {
        created = false;
        rc = linux.openat(dir, name, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    }
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: Fd = @intCast(rc);
    errdefer _ = linux.close(fd);
    if (created and linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.ChmodFailed;
    _ = try verifyFile(fd);
    if (created) {
        try sync(fd);
        try sync(dir);
    }
    while (true) {
        const result = linux.flock(fd, 2 | (if (nonblocking) @as(i32, 4) else 0));
        switch (linux.errno(result)) {
            .SUCCESS => return fd,
            .INTR => continue,
            .AGAIN => return error.LockBusy,
            else => return error.LockFailed,
        }
    }
}

fn ids(allocator: std.mem.Allocator, parent: Fd) ![]Id {
    const fd = try openDirectory(parent, ".");
    defer _ = linux.close(fd);
    var result: std.ArrayList(Id) = .empty;
    errdefer result.deinit(allocator);
    var buf: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        switch (linux.errno(n)) {
            .INTR => continue,
            .SUCCESS => {},
            else => return error.ReadFailed,
        }
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            if (ent.reclen < @offsetOf(linux.dirent64, "name") + 1 or off + ent.reclen > n) return error.InvalidDirectory;
            const names = buf[off + @offsetOf(linux.dirent64, "name") .. off + ent.reclen];
            const len = std.mem.indexOfScalar(u8, names, 0) orelse return error.InvalidDirectory;
            const name = names[0..len];
            off += ent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!validateId(name)) return error.InvalidDirectory;
            var id: Id = undefined;
            @memcpy(&id, name);
            try result.append(allocator, id);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn readJob(allocator: std.mem.Allocator, parent: Fd, id: Id) !Job {
    const dir = try recordDir(parent, &id);
    defer _ = linux.close(dir);
    const script = try openRecordFile(dir, "script");
    defer _ = linux.close(script);
    if ((try verifyFile(script)).size > max_script) return error.FileTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var job = (try readMeta(arena.allocator(), dir)).job;
    job.id = id;
    return job;
}

fn jobLess(_: void, a: Job, b: Job) bool {
    if (a.due != b.due) return a.due < b.due;
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

pub const Spool = struct {
    allocator: std.mem.Allocator,
    account: account.Account,
    fd: Fd,

    pub fn open(allocator: std.mem.Allocator) !Spool {
        return openAccount(allocator, false);
    }

    pub fn openForSubmission(allocator: std.mem.Allocator) !Spool {
        return openAccount(allocator, true);
    }

    fn openAccount(allocator: std.mem.Allocator, submitting: bool) !Spool {
        var identity = try account.resolve(allocator);
        errdefer identity.deinit(allocator);
        if (submitting) try account.checkSubmission(allocator, &identity);
        const uid = linux.geteuid();
        const home = try openHome(identity.home, uid);
        defer _ = linux.close(home);
        const local = try ensureDirectory(home, ".local", uid, false);
        defer _ = linux.close(local);
        const state = try ensureDirectory(local, "state", uid, false);
        defer _ = linux.close(state);
        const zosix = try ensureDirectory(state, "zosixutils", uid, false);
        defer _ = linux.close(zosix);
        const fd = try ensureDirectory(zosix, "at", uid, true);
        return .{ .allocator = allocator, .account = identity, .fd = fd };
    }

    /// Use an already opened private spool directory, primarily for isolated tests.
    pub fn openDir(allocator: std.mem.Allocator, dir: Fd) !Spool {
        var identity = try account.resolve(allocator);
        errdefer identity.deinit(allocator);
        const fd = try openDirectory(dir, ".");
        errdefer _ = linux.close(fd);
        try verifyDirectory(fd, linux.geteuid(), false, true);
        return .{ .allocator = allocator, .account = identity, .fd = fd };
    }

    pub fn close(self: *Spool) void {
        _ = linux.close(self.fd);
        self.account.deinit(self.allocator);
        self.* = undefined;
    }

    fn openState(self: *Spool, name: [*:0]const u8) !Fd {
        return ensureDirectory(self.fd, name, linux.geteuid(), true);
    }

    fn acquireLock(self: *Spool) !Fd {
        return lockFile(self.fd, "lock", false);
    }

    fn checkAvailable(self: *Spool, id: Id) !void {
        const name = try nameId(&id);
        for ([_][*:0]const u8{ "pending", "running", "finished", "quarantine", "trash" }) |state_name| {
            const dir = try self.openState(state_name);
            defer _ = linux.close(dir);
            var st: linux.Statx = undefined;
            switch (linux.errno(linux.statx(dir, &name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st))) {
                .NOENT => {},
                .SUCCESS => return error.IdCollision,
                else => return error.StatFailed,
            }
        }
    }

    pub fn lockRunner(self: *Spool) !Fd {
        return lockFile(self.fd, "runner.lock", true);
    }

    pub fn submit(self: *Spool, due: i64, queue: u8, mail: bool, script_fd: Fd, env: [*:null]const ?[*:0]const u8) !Id {
        const meta = try makeMeta(self.allocator, due, queue, mail, env);
        defer self.allocator.free(meta);
        const staging = try self.openState("staging");
        defer _ = linux.close(staging);
        const pending = try self.openState("pending");
        defer _ = linux.close(pending);
        var id: Id = undefined;
        var name: [33:0]u8 = undefined;
        var made = false;
        for (0..128) |_| {
            id = try randomId();
            name = try nameId(&id);
            switch (mkdirPrivate(staging, &name)) {
                .SUCCESS => {
                    made = true;
                    break;
                },
                .EXIST => continue,
                else => return error.CreateFailed,
            }
        }
        if (!made) return error.IdCollision;
        errdefer removeRecord(staging, &id) catch {};
        const dir = try openDirectory(staging, &name);
        defer _ = linux.close(dir);
        try verifyDirectory(dir, linux.geteuid(), false, true);
        const meta_fd = try createFile(dir, "meta");
        defer _ = linux.close(meta_fd);
        try writeAll(meta_fd, meta);
        try sync(meta_fd);
        const script = try createFile(dir, "script");
        defer _ = linux.close(script);
        var total: usize = 0;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = linux.read(script_fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .INTR => continue,
                .SUCCESS => {},
                else => return error.ReadFailed,
            }
            if (n == 0) break;
            if (n > max_script - total) return error.FileTooLarge;
            try writeAll(script, buf[0..n]);
            total += n;
        }
        try sync(script);
        try sync(dir);
        try sync(staging);
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        try self.checkAvailable(id);
        try moveRecord(staging, pending, &id);
        return id;
    }

    pub fn list(self: *Spool, allocator: std.mem.Allocator) ![]Job {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const pending = try self.openState("pending");
        defer _ = linux.close(pending);
        const all = try ids(allocator, pending);
        defer allocator.free(all);
        const result = try allocator.alloc(Job, all.len);
        errdefer allocator.free(result);
        for (all, 0..) |id, i| result[i] = try readJob(allocator, pending, id);
        std.mem.sort(Job, result, {}, jobLess);
        return result;
    }

    pub fn remove(self: *Spool, id: []const u8) !void {
        if (!validateId(id)) return error.InvalidId;
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const pending = try self.openState("pending");
        defer _ = linux.close(pending);
        const trash = try self.openState("trash");
        defer _ = linux.close(trash);
        var fixed: Id = undefined;
        @memcpy(&fixed, id);
        _ = readJob(self.allocator, pending, fixed) catch |err| return if (err == error.FileNotFound) error.JobNotFound else err;
        try moveRecord(pending, trash, id);
        try removeRecord(trash, id);
    }

    pub fn claim(self: *Spool, now: i64, allow_batch: bool) !?Job {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const pending = try self.openState("pending");
        defer _ = linux.close(pending);
        const running = try self.openState("running");
        defer _ = linux.close(running);
        const all = try ids(self.allocator, pending);
        defer self.allocator.free(all);
        var best_a: ?Job = null;
        var best_b: ?Job = null;
        for (all) |id| {
            const job = try readJob(self.allocator, pending, id);
            if (job.due > now) continue;
            const best = if (job.queue == 'a') &best_a else &best_b;
            if (best.* == null or jobLess({}, job, best.*.?)) best.* = job;
        }
        const selected = best_a orelse (if (allow_batch) best_b else null) orelse return null;
        try moveRecord(pending, running, &selected.id);
        return selected;
    }

    pub fn quarantineRunning(self: *Spool) !void {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const trash = try self.openState("trash");
        defer _ = linux.close(trash);
        const discarded = try ids(self.allocator, trash);
        defer self.allocator.free(discarded);
        for (discarded) |id| try removeRecord(trash, &id);
        const running = try self.openState("running");
        defer _ = linux.close(running);
        const quarantine = try self.openState("quarantine");
        defer _ = linux.close(quarantine);
        const all = try ids(self.allocator, running);
        defer self.allocator.free(all);
        for (all) |id| {
            const dir = try recordDir(running, &id);
            _ = linux.close(dir);
            try moveRecord(running, quarantine, &id);
        }
    }

    pub fn openRunning(self: *Spool, id: Id) !Fd {
        const running = try self.openState("running");
        defer _ = linux.close(running);
        return recordDir(running, &id);
    }

    pub fn finish(self: *Spool, id: Id) !void {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const running = try self.openState("running");
        defer _ = linux.close(running);
        const finished_dir = try self.openState("finished");
        defer _ = linux.close(finished_dir);
        const dir = try recordDir(running, &id);
        defer _ = linux.close(dir);
        const status = try openRecordFile(dir, "status");
        defer _ = linux.close(status);
        try sync(dir);
        try moveRecord(running, finished_dir, &id);
    }

    pub fn finished(self: *Spool, allocator: std.mem.Allocator) ![]Id {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const dir = try self.openState("finished");
        defer _ = linux.close(dir);
        const all = try ids(allocator, dir);
        errdefer allocator.free(all);
        for (all) |id| {
            const record = try recordDir(dir, &id);
            _ = linux.close(record);
        }
        return all;
    }

    pub fn openFinished(self: *Spool, id: Id) !Fd {
        const dir = try self.openState("finished");
        defer _ = linux.close(dir);
        return recordDir(dir, &id);
    }

    pub fn removeFinished(self: *Spool, id: Id) !void {
        const lock = try self.acquireLock();
        defer _ = linux.close(lock);
        const dir = try self.openState("finished");
        defer _ = linux.close(dir);
        const trash = try self.openState("trash");
        defer _ = linux.close(trash);
        const record = try recordDir(dir, &id);
        _ = linux.close(record);
        try moveRecord(dir, trash, &id);
        try removeRecord(trash, &id);
    }
};

test "at: spool directories reject symlinks and unsafe modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try openDirectory(tmp.dir.handle, ".");
    defer _ = linux.close(dir);
    const uid = linux.geteuid();
    const child = try ensureDirectory(dir, "child", uid, true);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(child, 0o755)));
    _ = linux.close(child);
    try std.testing.expectError(error.UnsafeDirectory, ensureDirectory(dir, "child", uid, true));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("child", dir, "link")));
    try std.testing.expectError(error.OpenFailed, ensureDirectory(dir, "link", uid, true));
}

test "at: spool public declarations compile" {
    std.testing.refAllDecls(Spool);
}

test "at: durable record lifecycle and queue selection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_fd = try openDirectory(tmp.dir.handle, ".");
    defer _ = linux.close(tmp_fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(tmp_fd, 0o700)));
    var spool = try Spool.openDir(allocator, tmp_fd);
    defer spool.close();
    const source = try createFile(tmp.dir.handle, "source");
    defer _ = linux.close(source);
    try writeAll(source, "echo sample\n");
    const input_rc = linux.openat(tmp.dir.handle, "source", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(input_rc));
    const input: Fd = @intCast(input_rc);
    defer _ = linux.close(input);
    const env = [_:null]?[*:0]const u8{ "A=value with spaces", "B=second" };
    const batch = try spool.submit(10, 'b', true, input, &env);
    try std.testing.expectError(error.IdCollision, spool.checkAvailable(batch));
    if (@sizeOf(usize) == 4) {
        var offset: linux.off_t = 0;
        _ = linux.llseek(input, 0, &offset, 0);
    } else _ = linux.lseek(input, 0, 0);
    const timed_later = try spool.submit(20, 'a', false, input, &env);
    if (@sizeOf(usize) == 4) {
        var offset: linux.off_t = 0;
        _ = linux.llseek(input, 0, &offset, 0);
    } else _ = linux.lseek(input, 0, 0);
    const timed_first = try spool.submit(15, 'a', true, input, &env);
    const jobs = try spool.list(allocator);
    defer allocator.free(jobs);
    try std.testing.expectEqual(@as(usize, 3), jobs.len);
    try std.testing.expectEqual(batch, jobs[0].id);
    try std.testing.expectEqual(timed_first, jobs[1].id);
    try std.testing.expectEqual(timed_later, jobs[2].id);
    try std.testing.expect((try spool.claim(14, false)) == null);
    const first = (try spool.claim(20, true)).?;
    try std.testing.expectEqual(timed_first, first.id);
    try std.testing.expectError(error.JobNotFound, spool.remove(&timed_first));
    const running = try spool.openRunning(first.id);
    defer _ = linux.close(running);
    var context = try loadContext(allocator, running);
    defer context.deinit(allocator);
    try std.testing.expect(context.mail);
    try std.testing.expectEqualStrings("A=value with spaces", std.mem.span(context.env[0].?));
    try std.testing.expectEqualStrings("B=second", std.mem.span(context.env[1].?));
    try std.testing.expect(context.cwd.len > 0 and context.cwd[0] == '/');
    const output = try createFile(running, "output");
    try writeAll(output, "output");
    try sync(output);
    _ = linux.close(output);
    const status = try createFile(running, "status");
    try writeAll(status, "0\n");
    try sync(status);
    _ = linux.close(status);
    try spool.finish(first.id);
    const finished_ids = try spool.finished(allocator);
    defer allocator.free(finished_ids);
    try std.testing.expectEqual(@as(usize, 1), finished_ids.len);
    try std.testing.expectEqual(first.id, finished_ids[0]);
    const finished = try spool.openFinished(first.id);
    _ = linux.close(finished);
    try spool.removeFinished(first.id);
    const second = (try spool.claim(20, true)).?;
    try std.testing.expectEqual(timed_later, second.id);
    try spool.quarantineRunning();
    try std.testing.expectError(error.FileNotFound, spool.openRunning(second.id));
    const third = (try spool.claim(20, true)).?;
    try std.testing.expectEqual(batch, third.id);
    try spool.quarantineRunning();
    try std.testing.expect((try spool.claim(20, true)) == null);
    const tied1 = try spool.submit(30, 'a', false, input, &env);
    const tied2 = try spool.submit(30, 'a', false, input, &env);
    const expected = if (std.mem.order(u8, &tied1, &tied2) == .lt) tied1 else tied2;
    const tie_winner = (try spool.claim(30, false)).?;
    try std.testing.expectEqual(expected, tie_winner.id);
    try spool.quarantineRunning();
    const other = if (std.mem.eql(u8, &tied1, &expected)) tied2 else tied1;
    try spool.remove(&other);
}

test "at: locks, invalid metadata and unsafe record files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_fd = try openDirectory(tmp.dir.handle, ".");
    defer _ = linux.close(tmp_fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(tmp_fd, 0o700)));
    var spool = try Spool.openDir(allocator, tmp_fd);
    defer spool.close();
    const runner = try spool.lockRunner();
    try std.testing.expectError(error.LockBusy, spool.lockRunner());
    _ = linux.close(runner);
    const next_runner = try spool.lockRunner();
    _ = linux.close(next_runner);
    try std.testing.expect(!validateId("../bad"));
    try std.testing.expectError(error.InvalidName, openRecordFile(tmp.dir.handle, "../x"));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("/etc/passwd", tmp.dir.handle, "link")));
    try std.testing.expectError(error.OpenFailed, openRecordFile(tmp.dir.handle, "link"));
    const data = try createFile(tmp.dir.handle, "meta");
    try writeAll(data, "bad");
    _ = linux.close(data);
    try std.testing.expectError(error.InvalidMetadata, loadContext(allocator, tmp.dir.handle));
    const unsafe = try createFile(tmp.dir.handle, "unsafe");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(unsafe, 0o644)));
    _ = linux.close(unsafe);
    try std.testing.expectError(error.UnsafeFile, openRecordFile(tmp.dir.handle, "unsafe"));
}

test "at: claim and removal serialize and interrupted cleanup recovers" {
    const Race = struct {
        spool: *Spool,
        id: Id,
        claimed: bool = false,
        removed: bool = false,
        fn claimJob(r: *@This()) void {
            r.claimed = (r.spool.claim(50, true) catch return) != null;
        }
        fn removeJob(r: *@This()) void {
            r.spool.remove(&r.id) catch return;
            r.removed = true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try openDirectory(tmp.dir.handle, ".");
    defer _ = linux.close(dir);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmod(dir, 0o700)));
    var spool = try Spool.openDir(std.heap.page_allocator, dir);
    defer spool.close();
    const source_rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(source_rc));
    const source: Fd = @intCast(source_rc);
    defer _ = linux.close(source);
    const env = [_:null]?[*:0]const u8{};
    const id = try spool.submit(10, 'a', false, source, &env);
    var race: Race = .{ .spool = &spool, .id = id };
    const t1 = try std.Thread.spawn(.{}, Race.claimJob, .{&race});
    const t2 = try std.Thread.spawn(.{}, Race.removeJob, .{&race});
    t1.join();
    t2.join();
    try std.testing.expect(race.claimed != race.removed);
    try spool.quarantineRunning();
    const stale = try spool.submit(20, 'a', false, source, &env);
    const pending = try spool.openState("pending");
    defer _ = linux.close(pending);
    const trash = try spool.openState("trash");
    defer _ = linux.close(trash);
    try moveRecord(pending, trash, &stale);
    const record = try recordDir(trash, &stale);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlinkat(record, "script", 0)));
    _ = linux.close(record);
    try spool.quarantineRunning();
    const remaining = try ids(std.testing.allocator, trash);
    defer std.testing.allocator.free(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}
