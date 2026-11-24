//! Report Linux process status from procfs.

const std = @import("std");
const linux = std.os.linux;
const user = @import("../common/user.zig");
const ArgParser = @import("../common/args.zig").ArgParser;
const common_error = @import("../common/error.zig");
const Allocator = std.mem.Allocator;

const Field = enum {
    ruser,
    user,
    rgroup,
    group,
    pid,
    ppid,
    pgid,
    pcpu,
    vsz,
    nice,
    etime,
    time,
    tty,
    comm,
    args,
    flags,
    state,
    uidnum,
    cpu,
    pri,
    addr,
    size,
    wchan,
    stime,
};
const Column = struct { field: Field, header: []const u8, width: usize };
const Record = struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    sid: u32,
    tty: u32,
    ruid: u32,
    euid: u32,
    rgid: u32,
    egid: u32,
    state: u8,
    flags: u64,
    utime: u64,
    stime: u64,
    start: u64,
    vsize: u64,
    priority: i64,
    nice: i64,
    name: []const u8,
    argv: []const u8,
    arg0_len: usize,
};
const Options = struct {
    all: bool = false,
    terminals: bool = false,
    nonleaders: bool = false,
    selected: bool = false,
    full: bool = false,
    long: bool = false,
    wide: u8 = 0,
    pids: std.ArrayList(u32) = .empty,
    sessions: std.ArrayList(u32) = .empty,
    rgids: std.ArrayList(u32) = .empty,
    ruids: std.ArrayList(u32) = .empty,
    euids: std.ArrayList(u32) = .empty,
    ttys: std.ArrayList([]const u8) = .empty,
    columns: std.ArrayList(Column) = .empty,
};

fn header(f: Field) []const u8 {
    return switch (f) {
        .ruser => "RUSER",
        .user => "USER",
        .rgroup => "RGROUP",
        .group => "GROUP",
        .pid => "PID",
        .ppid => "PPID",
        .pgid => "PGID",
        .pcpu => "%CPU",
        .vsz => "VSZ",
        .nice => "NI",
        .etime => "ELAPSED",
        .time => "TIME",
        .tty => "TT",
        .comm, .args => "COMMAND",
        .flags => "F",
        .state => "S",
        .uidnum => "UID",
        .cpu => "C",
        .pri => "PRI",
        .addr => "ADDR",
        .size => "SZ",
        .wchan => "WCHAN",
        .stime => "STIME",
    };
}

fn addColumn(a: Allocator, columns: *std.ArrayList(Column), f: Field, h: []const u8) !void {
    const min_width: usize = switch (f) {
        .pid, .ppid, .pgid => 5,
        .user, .ruser, .group, .rgroup => 8,
        .tty => 8,
        .time, .etime => 8,
        .vsz, .size => 6,
        else => 1,
    };
    try columns.append(a, .{ .field = f, .header = h, .width = @max(min_width, @max(h.len, header(f).len)) });
}

fn parseFormat(a: Allocator, columns: *std.ArrayList(Column), text: []const u8) !void {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ',' or text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i == text.len) break;
        const start = i;
        while (i < text.len and text[i] != ',' and text[i] != ' ' and text[i] != '\t' and text[i] != '=') : (i += 1) {}
        const f = std.meta.stringToEnum(Field, text[start..i]) orelse return error.InvalidArgument;
        if (@backingInt(f) > @backingInt(Field.args)) return error.InvalidArgument;
        const h = if (i < text.len and text[i] == '=') text[i + 1 ..] else header(f);
        try addColumn(a, columns, f, h);
        count += 1;
        if (i < text.len and text[i] == '=') break;
    }
    if (count == 0) return error.InvalidArgument;
}

fn parseList(a: Allocator, io: std.Io, opt: u8, text: []const u8, o: *Options) !void {
    var it = std.mem.tokenizeAny(u8, text, ", \t");
    var count: usize = 0;
    while (it.next()) |part| {
        count += 1;
        if (opt == 't') {
            try o.ttys.append(a, part);
            continue;
        }
        const n = std.fmt.parseInt(u32, part, 10) catch switch (opt) {
            'U', 'u' => user.findUidByName(io, part) orelse return error.InvalidArgument,
            'G' => user.findGidByName(io, part) orelse return error.InvalidArgument,
            else => return error.InvalidArgument,
        };
        switch (opt) {
            'p' => try o.pids.append(a, n),
            'g' => try o.sessions.append(a, n),
            'G' => try o.rgids.append(a, n),
            'U' => try o.ruids.append(a, n),
            'u' => try o.euids.append(a, n),
            else => unreachable,
        }
    }
    if (count == 0) return error.InvalidArgument;
}

fn options(a: Allocator, io: std.Io, args: []const [:0]const u8) !Options {
    var o: Options = .{};
    var p = ArgParser.init(args);
    while (p.next("aAdeflg:G:o:p:t:u:U:w")) |c| switch (c) {
        'a' => {
            o.terminals = true;
            o.selected = true;
        },
        'A', 'e' => {
            o.all = true;
            o.selected = true;
        },
        'd' => {
            o.nonleaders = true;
            o.selected = true;
        },
        'f' => o.full = true,
        'l' => o.long = true,
        'w' => o.wide +|= 1,
        'o' => try parseFormat(a, &o.columns, p.optarg.?),
        'g', 'G', 'p', 't', 'u', 'U' => {
            o.selected = true;
            try parseList(a, io, c, p.optarg.?, &o);
        },
        else => return error.InvalidArgument,
    };
    if (p.remaining().len != 0) return error.InvalidArgument;
    if (o.columns.items.len == 0) {
        if (o.long) {
            try addColumn(a, &o.columns, .flags, "F");
            try addColumn(a, &o.columns, .state, "S");
        }
        if (o.long or o.full) try addColumn(a, &o.columns, if (o.full) .user else .uidnum, "UID");
        try addColumn(a, &o.columns, .pid, "PID");
        if (o.long or o.full) {
            try addColumn(a, &o.columns, .ppid, "PPID");
            try addColumn(a, &o.columns, .cpu, "C");
        }
        if (o.long) for ([_]Field{ .pri, .nice, .addr, .size, .wchan }) |f| try addColumn(a, &o.columns, f, header(f));
        if (o.full) try addColumn(a, &o.columns, .stime, "STIME");
        try addColumn(a, &o.columns, .tty, "TTY");
        try addColumn(a, &o.columns, .time, "TIME");
        try addColumn(a, &o.columns, if (o.full) .args else .comm, "CMD");
    }
    return o;
}

fn readFile(a: Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, limit: usize) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(limit));
}

fn sanitize(text: []u8) void {
    for (text) |*c| if (c.* < 32 or c.* >= 127) {
        c.* = '?';
    };
}

fn parseStat(a: Allocator, text: []const u8, expected: u32) !Record {
    const left = std.mem.indexOfScalar(u8, text, '(') orelse return error.InvalidArgument;
    const right = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.InvalidArgument;
    if (right <= left or right + 2 >= text.len) return error.InvalidArgument;
    const pid = try std.fmt.parseInt(u32, std.mem.trim(u8, text[0..left], " "), 10);
    if (pid != expected) return error.InvalidArgument;
    const name = try a.dupe(u8, text[left + 1 .. right]);
    sanitize(name);
    var it = std.mem.tokenizeScalar(u8, text[right + 1 ..], ' ');
    var fields: [22][]const u8 = undefined;
    for (&fields) |*f| f.* = it.next() orelse return error.InvalidArgument;
    if (fields[0].len != 1) return error.InvalidArgument;
    const tty_signed = try std.fmt.parseInt(i64, fields[4], 10);
    if (tty_signed < std.math.minInt(i32) or tty_signed > std.math.maxInt(i32)) return error.InvalidArgument;
    return .{
        .pid = pid,
        .name = name,
        .argv = "",
        .arg0_len = 0,
        .state = fields[0][0],
        .ppid = try std.fmt.parseInt(u32, fields[1], 10),
        .pgid = try std.fmt.parseInt(u32, fields[2], 10),
        .sid = try std.fmt.parseInt(u32, fields[3], 10),
        .tty = @bitCast(@as(i32, @intCast(tty_signed))),
        .flags = try std.fmt.parseInt(u64, fields[6], 10),
        .utime = try std.fmt.parseInt(u64, fields[11], 10),
        .stime = try std.fmt.parseInt(u64, fields[12], 10),
        .priority = try std.fmt.parseInt(i64, fields[15], 10),
        .nice = try std.fmt.parseInt(i64, fields[16], 10),
        .start = try std.fmt.parseInt(u64, fields[19], 10),
        .vsize = try std.fmt.parseInt(u64, fields[20], 10),
        .ruid = 0,
        .euid = 0,
        .rgid = 0,
        .egid = 0,
    };
}

fn parseStatus(r: *Record, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var uid = false;
    var gid = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Tgid:")) {
            const tgid = try std.fmt.parseInt(u32, std.mem.trim(u8, line[5..], " \t\r"), 10);
            if (tgid != r.pid) return error.InvalidArgument;
        }
        const is_uid = std.mem.startsWith(u8, line, "Uid:");
        const is_gid = std.mem.startsWith(u8, line, "Gid:");
        if (!is_uid and !is_gid) continue;
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        const real = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidArgument, 10);
        const effective = try std.fmt.parseInt(u32, it.next() orelse return error.InvalidArgument, 10);
        if (is_uid) {
            r.ruid = real;
            r.euid = effective;
            uid = true;
        } else {
            r.rgid = real;
            r.egid = effective;
            gid = true;
        }
    }
    if (!uid or !gid) return error.InvalidArgument;
}

fn readRecord(a: Allocator, io: std.Io, proc: std.Io.Dir, name: []const u8, pid: u32) !Record {
    var dir = try proc.openDir(io, name, .{});
    defer dir.close(io);
    const stat = try readFile(a, io, dir, "stat", 65536);
    var r = try parseStat(a, stat, pid);
    const status = try readFile(a, io, dir, "status", 65536);
    try parseStatus(&r, status);
    return r;
}

fn readCommand(a: Allocator, io: std.Io, proc: std.Io.Dir, name: []const u8, r: *Record) !void {
    var dir = try proc.openDir(io, name, .{});
    defer dir.close(io);
    const stat = try readFile(a, io, dir, "stat", 65536);
    const check = try parseStat(a, stat, r.pid);
    if (check.start != r.start) return error.InvalidArgument;
    const argv = readFile(a, io, dir, "cmdline", 131072) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    var end = argv.len;
    while (end > 0 and argv[end - 1] == 0) : (end -= 1) {}
    r.arg0_len = std.mem.indexOfScalar(u8, argv[0..end], 0) orelse end;
    for (argv[0..end]) |*c| if (c.* == 0) {
        c.* = ' ';
    } else if (c.* < 32 or c.* >= 127) {
        c.* = '?';
    };
    r.argv = argv[0..end];
}

fn ttyName(a: Allocator, dev: u32) ![]const u8 {
    if (dev == 0) return "?";
    const major = (dev >> 8) & 0xfff;
    const minor = (dev & 0xff) | ((dev >> 12) & 0xfff00);
    if (major >= 136 and major <= 143) return std.fmt.allocPrint(a, "pts/{d}", .{(major - 136) * 256 + minor});
    if (major == 4 and minor < 64) return std.fmt.allocPrint(a, "tty{d}", .{minor});
    if (major == 4) return std.fmt.allocPrint(a, "ttyS{d}", .{minor - 64});
    return std.fmt.allocPrint(a, "{d}:{d}", .{ major, minor });
}

fn has(list: []const u32, needle: u32) bool {
    return std.mem.indexOfScalar(u32, list, needle) != null;
}
fn selected(o: Options, r: Record, caller: Record, tty: []const u8) bool {
    if (!o.selected) return r.euid == caller.euid and r.tty == caller.tty;
    if (o.all or (o.terminals and r.tty != 0) or (o.nonleaders and r.pid != r.sid)) return true;
    if (has(o.pids.items, r.pid) or has(o.sessions.items, r.sid) or has(o.rgids.items, r.rgid) or has(o.ruids.items, r.ruid) or has(o.euids.items, r.euid)) return true;
    for (o.ttys.items) |t| {
        const name = if (std.mem.startsWith(u8, t, "/dev/")) t[5..] else t;
        if (std.mem.eql(u8, name, tty) or (std.mem.startsWith(u8, tty, "tty") and std.mem.eql(u8, name, tty[3..]))) return true;
    }
    return false;
}

fn duration(a: Allocator, seconds: u64, elapsed: bool) ![]const u8 {
    const days = seconds / 86400;
    const hours = (seconds / 3600) % 24;
    const mins = (seconds / 60) % 60;
    const secs = seconds % 60;
    if (days != 0) return std.fmt.allocPrint(a, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ days, hours, mins, secs });
    if (hours != 0 or !elapsed) return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs });
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ mins, secs });
}

fn value(a: Allocator, io: std.Io, f: Field, r: Record, tty: []const u8, ticks: u64, uptime: u64, page: u64, boot: ?u64) ![]const u8 {
    const age = uptime -| (r.start / ticks);
    const cpu = (r.utime +| r.stime) / ticks;
    switch (f) {
        .ruser, .user, .rgroup, .group => {
            const id = switch (f) {
                .ruser => r.ruid,
                .user => r.euid,
                .rgroup => r.rgid,
                else => r.egid,
            };
            var buf: [256]u8 = undefined;
            const name = if (f == .ruser or f == .user) user.findNameByUid(io, id, &buf) else user.findNameByGid(io, id, &buf);
            if (name) |n| {
                const copy = try a.dupe(u8, n);
                sanitize(copy);
                for (copy) |*c| if (c.* == ' ') {
                    c.* = '?';
                };
                return copy;
            }
            return std.fmt.allocPrint(a, "{d}", .{id});
        },
        .pid => return std.fmt.allocPrint(a, "{d}", .{r.pid}),
        .ppid => return std.fmt.allocPrint(a, "{d}", .{r.ppid}),
        .pgid => return std.fmt.allocPrint(a, "{d}", .{r.pgid}),
        .uidnum => return std.fmt.allocPrint(a, "{d}", .{r.euid}),
        .vsz => return std.fmt.allocPrint(a, "{d}", .{r.vsize / 1024}),
        .size => return std.fmt.allocPrint(a, "{d}", .{r.vsize / page}),
        .nice => return std.fmt.allocPrint(a, "{d}", .{r.nice}),
        .pri => return std.fmt.allocPrint(a, "{d}", .{r.priority}),
        .flags => return std.fmt.allocPrint(a, "{o}", .{r.flags}),
        .state => return std.fmt.allocPrint(a, "{c}", .{if (r.state >= 33 and r.state < 127) r.state else '?'}),
        .pcpu, .cpu => {
            const elapsed_ticks = (@as(u128, uptime) * ticks) -| r.start;
            const tenths: u64 = if (elapsed_ticks == 0) 0 else @intCast(@min(@as(u128, r.utime +| r.stime) * 1000 / elapsed_ticks, std.math.maxInt(u64)));
            if (f == .cpu) return std.fmt.allocPrint(a, "{d}", .{tenths / 10});
            return std.fmt.allocPrint(a, "{d}.{d}", .{ tenths / 10, tenths % 10 });
        },
        .etime => return duration(a, age, true),
        .time => return duration(a, cpu, false),
        .tty => return tty,
        .comm => {
            if (r.state == 'Z') return try std.fmt.allocPrint(a, "[{s}] <defunct>", .{r.name});
            if (r.argv.len != 0) return r.argv[0..r.arg0_len];
            return r.name;
        },
        .args => {
            if (r.state == 'Z') return try std.fmt.allocPrint(a, "[{s}] <defunct>", .{r.name});
            if (r.argv.len != 0) return r.argv;
            return std.fmt.allocPrint(a, "[{s}]", .{r.name});
        },
        // STIME is an unambiguous Unix timestamp; a missing boot time is unavailable.
        .stime => return if (boot) |b| std.fmt.allocPrint(a, "{d}", .{b +| (r.start / ticks)}) else "-",
        .addr, .wchan => return "-",
    }
}

fn auxValue(data: []const u8, key: usize) ?usize {
    const size = @sizeOf(usize);
    var i: usize = 0;
    while (i + 2 * size <= data.len) : (i += 2 * size) {
        const k = std.mem.readInt(usize, data[i..][0..size], .native);
        const v = std.mem.readInt(usize, data[i + size ..][0..size], .native);
        if (k == key) return v;
        if (k == 0) break;
    }
    return null;
}

fn numberFile(a: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ?u64 {
    const text = readFile(a, io, dir, path, 4096) catch return null;
    const end = std.mem.indexOfAny(u8, text, ". \t\n") orelse text.len;
    return std.fmt.parseInt(u64, text[0..end], 10) catch null;
}

fn bootTime(a: Allocator, io: std.Io, proc: std.Io.Dir) ?u64 {
    const text = readFile(a, io, proc, "stat", 1024 * 1024) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "btime ")) return std.fmt.parseInt(u64, std.mem.trim(u8, line[6..], " \t\r"), 10) catch null;
    }
    return null;
}

fn emit(a: Allocator, io: std.Io, proc: std.Io.Dir, o: Options, writer: *std.Io.Writer, caller_pid: u32, ticks: u64, uptime: u64, page: u64, boot: ?u64, line_width: usize) !void {
    var caller_buf: [24]u8 = undefined;
    const caller_name = try std.fmt.bufPrint(&caller_buf, "{d}", .{caller_pid});
    const caller = try readRecord(a, io, proc, caller_name, caller_pid);
    var records: std.ArrayList(Record) = .empty;
    var need_command = false;
    for (o.columns.items) |column| {
        if (column.field == .comm or column.field == .args) need_command = true;
    }
    var it = proc.iterate();
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var r = readRecord(a, io, proc, entry.name, pid) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const tty = try ttyName(a, r.tty);
        if (!selected(o, r, caller, tty)) continue;
        if (need_command) readCommand(a, io, proc, entry.name, &r) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        try records.append(a, r);
    }
    std.mem.sort(Record, records.items, {}, struct {
        fn less(_: void, x: Record, y: Record) bool {
            return x.pid < y.pid;
        }
    }.less);
    const rows = try a.alloc([][]const u8, records.items.len);
    for (records.items, 0..) |r, i| {
        rows[i] = try a.alloc([]const u8, o.columns.items.len);
        const tty = try ttyName(a, r.tty);
        for (o.columns.items, 0..) |*col, j| {
            const v = try value(a, io, col.field, r, tty, ticks, uptime, page, boot);
            rows[i][j] = v;
            if (col.field != .args and col.field != .comm) col.width = @max(col.width, v.len);
        }
    }
    var show_header = false;
    for (o.columns.items) |col| if (col.header.len != 0) {
        show_header = true;
        break;
    };
    if (show_header) try writeRow(writer, o.columns.items, null, line_width);
    for (rows) |row| try writeRow(writer, o.columns.items, row, line_width);
}

fn writeRow(writer: *std.Io.Writer, columns: []const Column, row: ?[][]const u8, limit: usize) !void {
    var written: usize = 0;
    for (columns, 0..) |col, i| {
        if (i != 0 and written < limit) {
            try writer.writeByte(' ');
            written += 1;
        }
        const text = if (row) |r| r[i] else col.header;
        const last = i + 1 == columns.len;
        const left = col.field == .comm or col.field == .args or col.field == .tty or col.field == .user or col.field == .ruser or col.field == .group or col.field == .rgroup;
        const available = limit -| written;
        const len = @min(text.len, if (last) available else @min(available, col.width));
        const padding = if (last and left) 0 else @min(available - len, col.width -| len);
        if (!left) for (0..padding) |_| try writer.writeByte(' ');
        try writer.writeAll(text[0..len]);
        if (left) for (0..padding) |_| try writer.writeByte(' ');
        written += len + padding;
    }
    try writer.writeByte('\n');
}

pub fn run(allocator: Allocator, args: []const [:0]const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const o = options(a, io, args) catch |err| {
        common_error.report("ps", null, err);
        return 1;
    };
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
        common_error.report("ps", "/proc", err);
        return 1;
    };
    defer proc.close(io);
    const aux = readFile(a, io, proc, "self/auxv", 65536) catch |err| {
        common_error.report("ps", "/proc/self/auxv", err);
        return 1;
    };
    const ticks = auxValue(aux, std.elf.AT.CLKTCK) orelse 0;
    const page = auxValue(aux, std.elf.AT.PAGESZ) orelse 0;
    if (ticks == 0 or page == 0) {
        common_error.report("ps", "/proc/self/auxv", error.InvalidArgument);
        return 1;
    }
    const uptime = numberFile(a, io, proc, "uptime") orelse {
        common_error.report("ps", "/proc/uptime", error.InvalidArgument);
        return 1;
    };
    var width: usize = 80;
    const env = readFile(a, io, proc, "self/environ", 131072) catch "";
    var vars = std.mem.splitScalar(u8, env, 0);
    while (vars.next()) |v| if (std.mem.startsWith(u8, v, "COLUMNS=")) {
        width = std.fmt.parseInt(usize, v[8..], 10) catch 80;
        if (width == 0) width = 80;
        break;
    };
    if (o.wide != 0) width = @max(width, 132);
    if (o.wide > 1) width = std.math.maxInt(usize);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    const boot = if (o.full and o.columns.items.len > 0) bootTime(a, io, proc) else null;
    emit(a, io, proc, o, &out.interface, @intCast(linux.getpid()), ticks, uptime, page, boot, width) catch |err| {
        common_error.report("ps", if (err == error.WriteFailed) null else "/proc", err);
        return 1;
    };
    out.flush() catch |err| {
        common_error.report("ps", null, err);
        return 1;
    };
    return 0;
}

test "ps: stat fields, status, and hostile names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try parseStat(a, "42 (odd ) name\n) S 1 2 3 34817 0 9 0 0 0 0 120 30 0 0 20 -5 1 0 250 8192 1", 42);
    try parseStatus(&r, "Name:\tx\nUid:\t100 101 0 0\nGid:\t200 201 0 0\n");
    try std.testing.expectEqualStrings("odd ) name?", r.name);
    try std.testing.expectEqual(@as(u32, 101), r.euid);
    try std.testing.expectEqual(@as(u32, 200), r.rgid);
    try std.testing.expectEqual(@as(u64, 250), r.start);
    try std.testing.expectEqualStrings("pts/1", try ttyName(a, r.tty));
    try std.testing.expectError(error.InvalidArgument, parseStat(a, "42 (x) S 1", 42));
}

test "ps: format override and selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const opts = try options(a, io, &.{ "-p", "42,99", "-U", "7", "-o", "pid,ppid=Parent ID", "-o", "args=" });
    try std.testing.expectEqual(@as(usize, 3), opts.columns.items.len);
    try std.testing.expectEqualStrings("Parent ID", opts.columns.items[1].header);
    try std.testing.expectEqualStrings("", opts.columns.items[2].header);
    try std.testing.expect(has(opts.pids.items, 99));
    try std.testing.expectError(error.InvalidArgument, options(a, io, &.{ "-o", "invalid" }));
    var caller = try parseStat(a, "10 (caller) S 1 2 3 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 300 4096 1", 10);
    try parseStatus(&caller, "Uid: 7 8\nGid: 9 10\n");
    var other = caller;
    other.pid = 42;
    other.ruid = 7;
    other.euid = 11;
    try std.testing.expect(selected(opts, other, caller, "?"));
    const defaults = try options(a, io, &.{});
    try std.testing.expect(selected(defaults, caller, caller, "?"));
    try std.testing.expect(!selected(defaults, other, caller, "?"));
    other.euid = caller.euid;
    other.tty = 34817;
    try std.testing.expect(!selected(defaults, other, caller, "pts/1"));
    try std.testing.expect(selected(try options(a, io, &.{"-a"}), other, caller, "pts/1"));
    other.sid = other.pid;
    try std.testing.expect(!selected(try options(a, io, &.{"-d"}), other, caller, "pts/1"));
    try std.testing.expectEqualStrings("1-01:01:01", try duration(a, 90061, true));
}

test "ps: proc fixtures, ordering, selection and fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "10", "20", "30", "40" }) |name| try tmp.dir.createDirPath(io, name);
    try tmp.dir.writeFile(io, .{ .sub_path = "10/stat", .data = "10 (caller) S 1 2 3 0 0 0 0 0 0 0 100 0 0 0 20 0 1 0 200 4096 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "10/status", .data = "Tgid:\t10\nUid:\t5 6 0 0\nGid:\t7 8 0 0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "20/stat", .data = "20 (other) S 1 2 3 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 300 4096 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "20/status", .data = "Tgid:\t20\nUid:\t9 6 0 0\nGid:\t7 8 0 0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "20/cmdline", .data = "evil\x1bname\x00arg\nvalue\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "30/stat", .data = "30 (vanished) S 1 2 3 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 300 4096 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "40/stat", .data = "40 (wrong) S 1 2 3 0 0 0 0 0 0 0 0 0 0 0 20 0 1 0 300 4096 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "40/status", .data = "Tgid:\t41\nUid:\t5 6\nGid:\t7 8\n" });
    const o = try options(a, io, &.{ "-U", "9", "-p", "10", "-o", "pid=", "-o", "args=" });
    var out = std.Io.Writer.Allocating.init(a);
    try emit(a, io, tmp.dir, o, &out.writer, 10, 100, 20, 4096, 1000, 200);
    try std.testing.expectEqualStrings("   10 [caller]\n   20 evil?name arg?value\n", out.written());
    try std.testing.expectError(error.InvalidArgument, readRecord(a, io, tmp.dir, "40", 40));
}
