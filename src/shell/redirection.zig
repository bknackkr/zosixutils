//! Shell descriptor redirections and restoration.
const std = @import("std");
const process = @import("process.zig");
const syntax = @import("syntax.zig");
const expand = @import("expand.zig");
const Allocator = std.mem.Allocator;
const Fd = process.Fd;
const linux = process.linux;

pub const Hidden = struct {
    fd: Fd,
    next: ?*Hidden = null,
};

pub const Descriptors = struct {
    head: ?*Hidden = null,
    reserved: ?*Saved = null,

    pub fn track(self: *Descriptors, item: *Hidden) void {
        item.next = self.head;
        self.head = item;
    }

    pub fn untrack(self: *Descriptors, item: *Hidden) void {
        var link = &self.head;
        while (link.*) |node| {
            if (node == item) {
                link.* = node.next;
                node.next = null;
                return;
            }
            link = &node.next;
        }
    }
};

const Saved = struct {
    target: Fd,
    flags: usize,
    backup: ?Hidden,
    restore: bool,
    next: ?*Saved,
    reservation_next: ?*Saved,
};

pub const Redirects = struct {
    saved: ?*Saved = null,
    failure_word: ?[]const u8 = null,

    // Avoid both current operands and every target that will later be restored.
    // Skipping occupied numbers by increasing the minimum needs no temporary FDs.
    fn duplicate(descriptors: *Descriptors, fd: Fd, target: Fd, source: ?Fd) !Fd {
        // Closed standard streams must stay closed for in-process builtins.
        var minimum: Fd = 3;
        while (true) {
            const copy = try process.save(fd, minimum);
            var reserved = copy == target or (source != null and copy == source.?);
            var entry = descriptors.reserved;
            while (entry) |saved| : (entry = saved.reservation_next) {
                if (copy == saved.target) reserved = true;
            }
            if (!reserved) return copy;
            process.close(copy);
            if (copy == std.math.maxInt(Fd)) return error.DescriptorFailed;
            minimum = copy + 1;
        }
    }

    fn protect(descriptors: *Descriptors, target: Fd, source: ?Fd) !void {
        var node = descriptors.head;
        while (node) |item| : (node = item.next) {
            if (item.fd == target or (source != null and item.fd == source.?)) {
                const replacement = try duplicate(descriptors, item.fd, target, source);
                process.close(item.fd);
                item.fd = replacement;
            }
        }
    }

    fn saveTarget(self: *Redirects, descriptors: *Descriptors, allocator: Allocator, target: Fd, source: ?Fd, restore: bool) !void {
        var entry = self.saved;
        while (entry) |saved| : (entry = saved.next) {
            if (saved.target == target) return;
        }
        const saved = try allocator.create(Saved);
        if (!restore) {
            saved.* = .{ .target = target, .flags = 0, .backup = null, .restore = false, .next = self.saved, .reservation_next = descriptors.reserved };
            self.saved = saved;
            descriptors.reserved = saved;
            return;
        }
        const flags: ?usize = process.flags(target) catch |err| switch (err) {
            error.BadDescriptor => null,
            else => return err,
        };
        saved.* = .{ .target = target, .flags = flags orelse 0, .backup = null, .restore = true, .next = self.saved, .reservation_next = descriptors.reserved };
        if (flags != null) {
            saved.backup = .{ .fd = try duplicate(descriptors, target, target, source) };
            descriptors.track(&saved.backup.?);
        }
        self.saved = saved;
        descriptors.reserved = saved;
    }

    pub fn apply(self: *Redirects, descriptors: *Descriptors, ctx: anytype, allocator: Allocator, ops: []const syntax.Redirection, restore: bool) anyerror!void {
        for (ops) |op| {
            self.failure_word = op.word;
            if (op.target < 0) return error.InvalidDescriptor;

            var operand: []const u8 = undefined;
            switch (op.op) {
                .here, .here_strip => {
                    const doc = op.here_doc orelse return error.MissingHereDoc;
                    if (doc.expand) {
                        const fields = try expand.word(ctx, allocator, doc.body, .heredoc);
                        if (fields.len != 1) return error.AmbiguousRedirect;
                        operand = fields[0];
                    } else operand = doc.body;
                },
                else => {
                    const fields = try expand.word(ctx, allocator, op.word, .redirection);
                    if (fields.len != 1) return error.AmbiguousRedirect;
                    operand = fields[0];
                },
            }

            var source: ?Fd = null;
            switch (op.op) {
                .dup_input, .dup_output => if (!std.mem.eql(u8, operand, "-")) {
                    source = try descriptorNumber(operand);
                },
                else => {},
            }
            try protect(descriptors, op.target, source);
            try self.saveTarget(descriptors, allocator, op.target, source, restore);

            switch (op.op) {
                .dup_input, .dup_output => {
                    if (source) |fd| {
                        const rc = linux.fcntl(fd, linux.F.GETFL, 0);
                        if (linux.errno(rc) != .SUCCESS) return error.InvalidDescriptor;
                        const options: linux.O = @bitCast(@as(u32, @truncate(rc)));
                        if (options.PATH or op.op == .dup_input and options.ACCMODE == .WRONLY or
                            op.op == .dup_output and options.ACCMODE == .RDONLY)
                            return error.InvalidDescriptor;
                        try process.dup(fd, op.target);
                    } else process.close(op.target);
                },
                .here, .here_strip => try process.install(try process.hereDoc(operand), op.target),
                else => {
                    if (std.mem.findScalar(u8, operand, 0) != null) return error.InvalidOperand;
                    const path = try allocator.dupeSentinel(u8, operand, 0);
                    const options: linux.O = switch (op.op) {
                        .input => .{ .ACCMODE = .RDONLY },
                        .output, .clobber => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                        .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                        .read_write => .{ .ACCMODE = .RDWR, .CREAT = true },
                        else => unreachable,
                    };
                    try process.install(try process.open(path, options), op.target);
                },
            }
            self.failure_word = null;
        }
    }

    pub fn finish(self: *Redirects, descriptors: *Descriptors, retain: bool) void {
        var entry = self.saved;
        while (entry) |saved| : (entry = saved.next) {
            if (saved.backup) |*backup| {
                if (!retain) {
                    while (true) {
                        const rc = linux.dup2(backup.fd, saved.target);
                        switch (linux.errno(rc)) {
                            .INTR, .BUSY => continue,
                            .SUCCESS => {
                                while (linux.errno(linux.fcntl(saved.target, linux.F.SETFD, saved.flags)) == .INTR) {}
                                break;
                            },
                            else => break,
                        }
                    }
                }
                descriptors.untrack(backup);
                process.close(backup.fd);
            } else if (!retain and saved.restore) process.close(saved.target);
            var link = &descriptors.reserved;
            while (link.*) |reservation| {
                if (reservation == saved) {
                    link.* = reservation.reservation_next;
                    break;
                }
                link = &reservation.reservation_next;
            }
        }
        self.saved = null;
        self.failure_word = null;
    }
};

fn descriptorNumber(word: []const u8) !Fd {
    if (word.len == 0) return error.InvalidDescriptor;
    var n: Fd = 0;
    for (word) |c| {
        if (c < '0' or c > '9') return error.InvalidDescriptor;
        const digit: Fd = c - '0';
        if (n > @divTrunc(std.math.maxInt(Fd) - digit, 10)) return error.InvalidDescriptor;
        n = n * 10 + digit;
    }
    return n;
}

const TestContext = struct {
    pub fn parameter(_: *@This(), name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "x")) return "first";
        return null;
    }
    pub fn positionals(_: *@This()) []const []const u8 {
        return &.{};
    }
    pub fn assignParameter(_: *@This(), _: []const u8, _: []const u8) !void {}
    pub fn substitute(_: *@This(), _: Allocator, _: []const u8) ![]const u8 {
        return "";
    }
    pub fn noglob(_: *@This()) bool {
        return true;
    }
};

test "sh: redirection keeps closed sources closed and restores CLOEXEC on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try process.hereDoc("original");
    defer process.close(input);
    const target = try process.save(input, 30);
    defer process.close(target);
    const source = try process.save(input, 0);
    process.close(source);
    const word = try std.fmt.allocPrint(a, "{d}", .{source});
    var descriptors: Descriptors = .{};
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const ops = [_]syntax.Redirection{.{ .target = target, .op = .dup_input, .word = word }};
    try std.testing.expectError(error.InvalidDescriptor, redirects.apply(&descriptors, &ctx, a, &ops, true));
    try std.testing.expectEqualStrings(word, redirects.failure_word.?);
    redirects.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(source));
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(target));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("original", buf[0..try process.read(target, &buf)]);
    try std.testing.expect(descriptors.head == null);
}

test "sh: private descriptors move away from targets and survive restoration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hidden: Hidden = .{ .fd = try process.hereDoc("script") };
    defer process.close(hidden.fd);
    const target = hidden.fd;
    var descriptors: Descriptors = .{};
    descriptors.track(&hidden);
    defer descriptors.untrack(&hidden);
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const doc: syntax.HereDoc = .{ .body = "redirected", .expand = false };
    const ops = [_]syntax.Redirection{.{ .target = target, .op = .here, .word = "EOF", .here_doc = &doc }};
    try redirects.apply(&descriptors, &ctx, a, &ops, true);
    try std.testing.expect(hidden.fd != target);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("redirected", buf[0..try process.read(target, &buf)]);
    redirects.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(target));
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(hidden.fd));
    try std.testing.expectEqualStrings("script", buf[0..try process.read(hidden.fd, &buf)]);
}

test "sh: private same-number source and target are not command descriptors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hidden: Hidden = .{ .fd = try process.hereDoc("script") };
    defer process.close(hidden.fd);
    const target = hidden.fd;
    const word = try std.fmt.allocPrint(a, "{d}", .{target});
    var descriptors: Descriptors = .{};
    descriptors.track(&hidden);
    defer descriptors.untrack(&hidden);
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const ops = [_]syntax.Redirection{.{ .target = target, .op = .dup_input, .word = word }};
    try std.testing.expectError(error.InvalidDescriptor, redirects.apply(&descriptors, &ctx, a, &ops, true));
    redirects.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(target));
    var buf: [6]u8 = undefined;
    try std.testing.expectEqualStrings("script", buf[0..try process.read(hidden.fd, &buf)]);
}

test "sh: nested redirections cannot relocate backups into outer closed targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try process.hereDoc("original");
    defer process.close(input);
    const outer_target = try process.save(input, 0);
    process.close(outer_target);
    const target = try process.save(input, 30);
    defer process.close(target);
    var descriptors: Descriptors = .{};
    var outer: Redirects = .{};
    var inner: Redirects = .{};
    var ctx: TestContext = .{};
    const close_outer = [_]syntax.Redirection{.{ .target = outer_target, .op = .dup_input, .word = "-" }};
    try outer.apply(&descriptors, &ctx, a, &close_outer, true);
    const doc: syntax.HereDoc = .{ .body = "new", .expand = false };
    const replace = [_]syntax.Redirection{.{ .target = target, .op = .here, .word = "EOF", .here_doc = &doc }};
    try inner.apply(&descriptors, &ctx, a, &replace, true);
    try std.testing.expectError(error.BadDescriptor, process.flags(outer_target));
    inner.finish(&descriptors, false);
    outer.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(outer_target));
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(target));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("original", buf[0..try process.read(target, &buf)]);
    try std.testing.expect(descriptors.reserved == null);
}

test "sh: saved descriptor collision and partial failure restore initial state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try process.hereDoc("original");
    defer process.close(input);
    const target = try process.save(input, 30);
    defer process.close(target);
    var descriptors: Descriptors = .{};
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const doc: syntax.HereDoc = .{ .body = "new", .expand = false };
    const replace = [_]syntax.Redirection{.{ .target = target, .op = .here, .word = "EOF", .here_doc = &doc }};
    try redirects.apply(&descriptors, &ctx, a, &replace, true);
    const backup_number = descriptors.head.?.fd;
    const collide = [_]syntax.Redirection{.{ .target = backup_number, .op = .here, .word = "EOF", .here_doc = &doc }};
    try redirects.apply(&descriptors, &ctx, a, &collide, true);
    const bad = [_]syntax.Redirection{.{ .target = target, .op = .dup_input, .word = "-1" }};
    try std.testing.expectError(error.InvalidDescriptor, redirects.apply(&descriptors, &ctx, a, &bad, true));
    redirects.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(backup_number));
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(target));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("original", buf[0..try process.read(target, &buf)]);
    try std.testing.expect(descriptors.head == null and descriptors.reserved == null);
}

test "sh: redirections apply left to right and can be retained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try process.hereDoc("");
    defer process.close(input);
    const first = try process.save(input, 30);
    defer process.close(first);
    const second = try process.save(input, 30);
    defer process.close(second);
    const word = try std.fmt.allocPrint(a, "{d}", .{first});
    const doc1: syntax.HereDoc = .{ .body = "$x", .expand = true };
    const doc2: syntax.HereDoc = .{ .body = "second", .expand = false };
    const ops = [_]syntax.Redirection{
        .{ .target = first, .op = .here, .word = "EOF", .here_doc = &doc1 },
        .{ .target = second, .op = .dup_input, .word = word },
        .{ .target = first, .op = .here, .word = "EOF", .here_doc = &doc2 },
    };
    var descriptors: Descriptors = .{};
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    try redirects.apply(&descriptors, &ctx, a, &ops, true);
    redirects.finish(&descriptors, true);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("second", buf[0..try process.read(first, &buf)]);
    try std.testing.expectEqualStrings("first", buf[0..try process.read(second, &buf)]);
    try std.testing.expectEqual(@as(usize, 0), try process.flags(first));
    try std.testing.expect(descriptors.head == null and descriptors.reserved == null);
}

test "sh: high private script descriptor can be used as a redirection target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try process.hereDoc("script");
    defer process.close(input);
    var hidden: Hidden = .{ .fd = try process.save(input, 300) };
    defer process.close(hidden.fd);
    const target = hidden.fd;
    var descriptors: Descriptors = .{};
    descriptors.track(&hidden);
    defer descriptors.untrack(&hidden);
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const ops = [_]syntax.Redirection{.{ .target = target, .op = .input, .word = "/dev/null" }};
    try redirects.apply(&descriptors, &ctx, a, &ops, true);
    try std.testing.expect(hidden.fd != target);
    redirects.finish(&descriptors, false);
    try std.testing.expectError(error.BadDescriptor, process.flags(target));
    var buf: [6]u8 = undefined;
    try std.testing.expectEqualStrings("script", buf[0..try process.read(hidden.fd, &buf)]);
}

test "sh: same-number open descriptor duplication remains valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fd = try process.hereDoc("same");
    defer process.close(fd);
    const word = try std.fmt.allocPrint(a, "{d}", .{fd});
    var descriptors: Descriptors = .{};
    var redirects: Redirects = .{};
    var ctx: TestContext = .{};
    const ops = [_]syntax.Redirection{.{ .target = fd, .op = .dup_input, .word = word }};
    try redirects.apply(&descriptors, &ctx, a, &ops, true);
    redirects.finish(&descriptors, false);
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(fd));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("same", buf[0..try process.read(fd, &buf)]);
}

test "sh: file redirection open modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fd = try process.hereDoc("original");
    defer process.close(fd);
    var descriptors: Descriptors = .{};
    var ctx: TestContext = .{};
    const cases = [_]struct { op: syntax.Redirection.Op, mode: @TypeOf(@as(linux.O, .{}).ACCMODE), append: bool }{
        .{ .op = .input, .mode = .RDONLY, .append = false },
        .{ .op = .output, .mode = .WRONLY, .append = false },
        .{ .op = .clobber, .mode = .WRONLY, .append = false },
        .{ .op = .append, .mode = .WRONLY, .append = true },
        .{ .op = .read_write, .mode = .RDWR, .append = false },
    };
    for (cases) |case| {
        var redirects: Redirects = .{};
        const ops = [_]syntax.Redirection{.{ .target = fd, .op = case.op, .word = "/dev/null" }};
        try redirects.apply(&descriptors, &ctx, a, &ops, true);
        const rc = linux.fcntl(fd, linux.F.GETFL, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        const options: linux.O = @bitCast(@as(u32, @truncate(rc)));
        try std.testing.expectEqual(case.mode, options.ACCMODE);
        try std.testing.expectEqual(case.append, options.APPEND);
        try std.testing.expectEqual(@as(usize, 0), try process.flags(fd));
        redirects.finish(&descriptors, false);
        try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), try process.flags(fd));
    }
}
