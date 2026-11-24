const std = @import("std");
const linux = std.os.linux;

// Civil dates are limited to four-digit AD years. DST gaps are rejected;
// in a fold, the earliest occurrence not before the eligibility threshold wins.
const Civil = struct { year: i64, month: i64, day: i64, hour: i64 = 0, minute: i64 = 0, second: i64 = 0 };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

fn leap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}
fn monthDays(y: i64, m: i64) i64 {
    return switch (m) {
        2 => if (leap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
fn valid(c: Civil) bool {
    return c.year >= 1 and c.year <= 9999 and c.month >= 1 and c.month <= 12 and c.day >= 1 and c.day <= monthDays(c.year, c.month) and c.hour >= 0 and c.hour < 24 and c.minute >= 0 and c.minute < 60 and c.second >= 0 and c.second < 60;
}
fn days(c: Civil) i64 {
    const y = c.year - @as(i64, if (c.month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = c.month + @as(i64, if (c.month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + c.day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}
fn fromDays(d: i64) !Civil {
    // Limit before adding, to keep all subsequent arithmetic bounded.
    if (d < -719162 or d > 2932896) return error.OutOfRange;
    const z = d + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    y += if (month <= 2) 1 else 0;
    return .{ .year = y, .month = month, .day = day };
}
fn scalar(c: Civil) !i64 {
    if (!valid(c)) return error.InvalidTime;
    return days(c) * 86400 + c.hour * 3600 + c.minute * 60 + c.second;
}
fn civil(s: i64) !Civil {
    var c = try fromDays(@divFloor(s, 86400));
    const t = @mod(s, 86400);
    c.hour = @divFloor(t, 3600);
    c.minute = @divFloor(@mod(t, 3600), 60);
    c.second = @mod(t, 60);
    return c;
}
fn addDays(c: *Civil, n: i64) !void {
    const d = std.math.add(i64, days(c.*), n) catch return error.OutOfRange;
    const date = try fromDays(d);
    c.year = date.year;
    c.month = date.month;
    c.day = date.day;
}

const Rule = struct {
    kind: enum { julian, day, month },
    a: i64,
    b: i64 = 0,
    c: i64 = 0,
    time: i64 = 7200,
    fn dayOfYear(r: Rule, y: i64) i64 {
        return switch (r.kind) {
            .julian => r.a - 1 + @as(i64, if (leap(y) and r.a >= 60) 1 else 0),
            .day => r.a,
            .month => blk: {
                const first = Civil{ .year = y, .month = r.a, .day = 1 };
                const wd = @mod(days(first) + 4, 7);
                var day = 1 + @mod(r.c - wd, 7) + (r.b - 1) * 7;
                if (day > monthDays(y, r.a)) day -= 7;
                break :blk days(.{ .year = y, .month = r.a, .day = day }) - days(.{ .year = y, .month = 1, .day = 1 });
            },
        };
    }
};
const Posix = struct {
    standard: i32,
    daylight: ?i32 = null,
    start: Rule = undefined,
    end: Rule = undefined,
    fn offset(p: Posix, s: i64) !i32 {
        const dst = p.daylight orelse return p.standard;
        const year = (try civil(std.math.add(i64, s, p.standard) catch return error.OutOfRange)).year;
        var latest: i64 = std.math.minInt(i64);
        var result = p.standard;
        for (0..3) |i| {
            const y = year + @as(i64, @intCast(i)) - 1;
            const jan = days(.{ .year = y, .month = 1, .day = 1 }) * 86400;
            const start = jan + p.start.dayOfYear(y) * 86400 + p.start.time - p.standard;
            const end = jan + p.end.dayOfYear(y) * 86400 + p.end.time - dst;
            if (start <= s and start > latest) {
                latest = start;
                result = dst;
            }
            if (end <= s and end > latest) {
                latest = end;
                result = p.standard;
            }
        }
        return result;
    }
};
const PosixParser = struct {
    s: []const u8,
    i: usize = 0,
    fn take(p: *PosixParser, ch: u8) bool {
        if (p.i < p.s.len and p.s[p.i] == ch) {
            p.i += 1;
            return true;
        }
        return false;
    }
    fn number(p: *PosixParser) !i64 {
        const start = p.i;
        var n: i64 = 0;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) {
            n = std.math.mul(i64, n, 10) catch return error.InvalidTimezone;
            n = std.math.add(i64, n, p.s[p.i] - '0') catch return error.InvalidTimezone;
        }
        if (p.i == start) return error.InvalidTimezone;
        return n;
    }
    fn name(p: *PosixParser) !void {
        const quoted = p.take('<');
        const start = p.i;
        while (p.i < p.s.len and (if (quoted) p.s[p.i] != '>' else std.ascii.isAlphabetic(p.s[p.i]))) : (p.i += 1) {}
        if (p.i - start < 3) return error.InvalidTimezone;
        if (quoted and !p.take('>')) return error.InvalidTimezone;
    }
    fn clock(p: *PosixParser, max: i64) !i64 {
        var sign: i64 = 1;
        if (p.take('-')) sign = -1 else _ = p.take('+');
        const h = try p.number();
        var m: i64 = 0;
        var s: i64 = 0;
        if (p.take(':')) {
            m = try p.number();
            if (p.take(':')) s = try p.number();
        }
        if (h > max or m > 59 or s > 59) return error.InvalidTimezone;
        return sign * (h * 3600 + m * 60 + s);
    }
    fn rule(p: *PosixParser) !Rule {
        var r: Rule = undefined;
        if (p.take('M')) {
            const m = try p.number();
            if (!p.take('.')) return error.InvalidTimezone;
            const w = try p.number();
            if (!p.take('.')) return error.InvalidTimezone;
            const d = try p.number();
            if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return error.InvalidTimezone;
            r = .{ .kind = .month, .a = m, .b = w, .c = d };
        } else if (p.take('J')) {
            const d = try p.number();
            if (d < 1 or d > 365) return error.InvalidTimezone;
            r = .{ .kind = .julian, .a = d };
        } else {
            const d = try p.number();
            if (d > 365) return error.InvalidTimezone;
            r = .{ .kind = .day, .a = d };
        }
        if (p.take('/')) r.time = try p.clock(167);
        return r;
    }
    fn parse(s: []const u8) !Posix {
        var p = PosixParser{ .s = s };
        try p.name();
        var result = Posix{ .standard = @intCast(-(try p.clock(24))) };
        if (p.i == s.len) return result;
        try p.name();
        result.daylight = if (p.i < s.len and s[p.i] != ',') @intCast(-(try p.clock(24))) else result.standard + 3600;
        if (p.i == s.len) {
            // POSIX leaves absent DST rules implementation-defined.
            result.start = .{ .kind = .month, .a = 3, .b = 2, .c = 0 };
            result.end = .{ .kind = .month, .a = 11, .b = 1, .c = 0 };
            return result;
        }
        if (!p.take(',')) return error.InvalidTimezone;
        result.start = try p.rule();
        if (!p.take(',')) return error.InvalidTimezone;
        result.end = try p.rule();
        if (p.i != s.len) return error.InvalidTimezone;
        return result;
    }
};

const Zone = struct {
    allocator: std.mem.Allocator,
    data: ?[]u8 = null,
    posix: ?Posix = null,
    transitions: []const u8 = &.{},
    indices: []const u8 = &.{},
    types: []const u8 = &.{},
    width: usize = 0,
    fn deinit(z: *Zone) void {
        if (z.data) |d| z.allocator.free(d);
    }
    fn integer(b: []const u8, width: usize) i64 {
        return if (width == 8) std.mem.readInt(i64, b[0..8], .big) else std.mem.readInt(i32, b[0..4], .big);
    }
    fn offset(z: *const Zone, s: i64) !i32 {
        const transition_count = z.indices.len;
        if (z.posix) |p| {
            if (transition_count == 0 or s > integer(z.transitions[(transition_count - 1) * z.width ..], z.width)) return p.offset(s);
        }
        var lo: usize = 0;
        var hi = transition_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (integer(z.transitions[mid * z.width ..], z.width) <= s) lo = mid + 1 else hi = mid;
        }
        const index: usize = if (lo == 0) 0 else z.indices[lo - 1];
        return @intCast(integer(z.types[index * 6 ..], 4));
    }
    fn local(z: *const Zone, s: i64) !Civil {
        return civil(std.math.add(i64, s, try z.offset(s)) catch return error.OutOfRange);
    }
    fn resolve(z: *const Zone, c: Civil, minimum: i64) !i64 {
        const wall = try scalar(c);
        var best: ?i64 = null;
        var any = false;
        const n = z.types.len / 6 + @as(usize, if (z.posix != null) 2 else 0);
        for (0..n) |i| {
            const off: i64 = if (i < z.types.len / 6) integer(z.types[i * 6 ..], 4) else if (i == z.types.len / 6) z.posix.?.standard else z.posix.?.daylight orelse z.posix.?.standard;
            const candidate = std.math.sub(i64, wall, off) catch continue;
            if ((try z.offset(candidate)) != off) continue;
            any = true;
            if (candidate >= minimum and (best == null or candidate < best.?)) best = candidate;
        }
        return best orelse if (any) error.PastTime else error.NonexistentTime;
    }
};

fn loadFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd_raw = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    switch (linux.errno(fd_raw)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return error.TimezoneNotFound,
        else => return error.TimezoneFile,
    }
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return error.TimezoneFile;
        if (rc == 0) break;
        if (out.items.len + rc > 1024 * 1024) return error.InvalidTimezone;
        try out.appendSlice(allocator, buf[0..rc]);
    }
    return out.toOwnedSlice(allocator);
}
fn count(b: []const u8, at: usize) usize {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}
fn blockLength(b: []const u8, width: usize) !usize {
    if (b.len < 44 or !std.mem.eql(u8, b[0..4], "TZif")) return error.InvalidTimezone;
    const a = count(b, 20);
    const s = count(b, 24);
    const l = count(b, 28);
    const t = count(b, 32);
    const ty = count(b, 36);
    const ch = count(b, 40);
    if (ty == 0 or ty > 256 or t > 100000 or l > 10000 or ch > 65536 or (a != 0 and a != ty) or (s != 0 and s != ty)) return error.InvalidTimezone;
    return 44 + t * (width + 1) + ty * 6 + ch + l * (width + 4) + s + a;
}
fn parseFile(z: *Zone) !void {
    const d = z.data.?;
    if (d.len < 44) return error.InvalidTimezone;
    const version = d[4];
    const first = try blockLength(d, 4);
    if (first > d.len) return error.InvalidTimezone;
    const start: usize = if (version == 0) 0 else first;
    const width: usize = if (version == 0) 4 else 8;
    if (version != 0 and version != '2' and version != '3' and version != '4') return error.InvalidTimezone;
    const b = d[start..];
    const len = try blockLength(b, width);
    if (len > b.len) return error.InvalidTimezone;
    const n = count(b, 32);
    const ty = count(b, 36);
    z.width = width;
    z.transitions = b[44 .. 44 + n * width];
    z.indices = b[44 + n * width ..][0..n];
    z.types = b[44 + n * (width + 1) ..][0 .. ty * 6];
    for (z.indices, 0..) |idx, i| {
        if (idx >= ty or (i > 0 and Zone.integer(z.transitions[(i - 1) * width ..], width) >= Zone.integer(z.transitions[i * width ..], width))) return error.InvalidTimezone;
    }
    for (0..ty) |i| if (z.types[i * 6 + 4] > 1) return error.InvalidTimezone;
    if (version != 0) {
        if (len >= b.len or b[4] != version) return error.InvalidTimezone;
        const footer = b[len..];
        if (footer.len < 2 or footer[0] != '\n' or footer[footer.len - 1] != '\n') return error.InvalidTimezone;
        if (footer.len > 2) z.posix = try PosixParser.parse(footer[1 .. footer.len - 1]);
    }
}
fn zone(allocator: std.mem.Allocator, tz: ?[]const u8) !Zone {
    var z = Zone{ .allocator = allocator };
    errdefer z.deinit();
    if (tz) |raw| {
        if (raw.len == 0) {
            z.posix = .{ .standard = 0 };
            return z;
        }
        const path_only = raw[0] == ':';
        const name = if (path_only) raw[1..] else raw;
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidTimezone;
        const path = if (name[0] == '/') try std.fmt.allocPrintSentinel(allocator, "{s}", .{name}, 0) else try std.fmt.allocPrintSentinel(allocator, "/usr/share/zoneinfo/{s}", .{name}, 0);
        defer allocator.free(path);
        z.data = loadFile(allocator, path) catch |err| blk: {
            if (err != error.TimezoneNotFound or path_only or name[0] == '/') return err;
            z.posix = try PosixParser.parse(name);
            break :blk null;
        };
        if (z.data != null) try parseFile(&z);
    } else {
        z.data = try loadFile(allocator, "/etc/localtime");
        try parseFile(&z);
    }
    return z;
}

const Lexer = struct {
    text: []const u8,
    index: usize = 0,
    fn next(l: *Lexer) ?[]const u8 {
        while (l.index < l.text.len and std.ascii.isWhitespace(l.text[l.index])) : (l.index += 1) {}
        if (l.index == l.text.len) return null;
        const start = l.index;
        const ch = l.text[l.index];
        l.index += 1;
        if (std.ascii.isDigit(ch)) {
            while (l.index < l.text.len and std.ascii.isDigit(l.text[l.index])) : (l.index += 1) {}
        } else if (std.ascii.isAlphabetic(ch)) {
            while (l.index < l.text.len and std.ascii.isAlphabetic(l.text[l.index])) : (l.index += 1) {}
        }
        return l.text[start..l.index];
    }
    fn peek(l: *Lexer) ?[]const u8 {
        var copy = l.*;
        return copy.next();
    }
    fn accept(l: *Lexer, token: []const u8) bool {
        const value = l.peek() orelse return false;
        if (!std.ascii.eqlIgnoreCase(value, token)) return false;
        _ = l.next();
        return true;
    }
};
fn num(s: []const u8) !i64 {
    if (s.len == 0) return error.InvalidTime;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidTime;
    return std.fmt.parseInt(i64, s, 10) catch error.InvalidTime;
}
fn nameIndex(name: []const u8, names: []const []const u8) ?i64 {
    for (names, 0..) |entry, i| {
        if (std.ascii.eqlIgnoreCase(name, entry) or (name.len == 3 and std.ascii.eqlIgnoreCase(name, entry[0..3]))) return @intCast(i);
    }
    return null;
}
fn increment(l: *Lexer, z: *const Zone, value: i64) !i64 {
    var amount: i64 = 0;
    if (l.accept("+")) amount = try num(l.next() orelse return error.InvalidTime) else if (l.accept("next")) amount = 1 else return value;
    const unit = l.next() orelse return error.InvalidTime;
    if (std.ascii.eqlIgnoreCase(unit, "minute") or std.ascii.eqlIgnoreCase(unit, "minutes") or std.ascii.eqlIgnoreCase(unit, "hour") or std.ascii.eqlIgnoreCase(unit, "hours")) {
        const factor: i64 = if (std.ascii.toLower(unit[0]) == 'm') 60 else 3600;
        const delta = std.math.mul(i64, amount, factor) catch return error.OutOfRange;
        const result = std.math.add(i64, value, delta) catch return error.OutOfRange;
        _ = try z.local(result);
        return result;
    }
    var c = try z.local(value);
    if (std.ascii.eqlIgnoreCase(unit, "day") or std.ascii.eqlIgnoreCase(unit, "days") or std.ascii.eqlIgnoreCase(unit, "week") or std.ascii.eqlIgnoreCase(unit, "weeks")) {
        const factor: i64 = if (std.ascii.toLower(unit[0]) == 'w') 7 else 1;
        try addDays(&c, std.math.mul(i64, amount, factor) catch return error.OutOfRange);
    } else if (std.ascii.eqlIgnoreCase(unit, "month") or std.ascii.eqlIgnoreCase(unit, "months") or std.ascii.eqlIgnoreCase(unit, "year") or std.ascii.eqlIgnoreCase(unit, "years")) {
        // Reject nonexistent dates rather than silently clamping the day.
        const factor: i64 = if (std.ascii.toLower(unit[0]) == 'y') 12 else 1;
        const delta = std.math.mul(i64, amount, factor) catch return error.OutOfRange;
        const m = std.math.add(i64, c.year * 12 + c.month - 1, delta) catch return error.OutOfRange;
        c.year = @divFloor(m, 12);
        c.month = @mod(m, 12) + 1;
        if (!valid(c)) return error.InvalidTime;
    } else return error.InvalidTime;
    return z.resolve(c, value);
}

/// Parse POSIX-locale at operands using an injected current time and timezone.
pub fn parse(allocator: std.mem.Allocator, now: i64, tz: ?[]const u8, tokens: []const [:0]const u8) !i64 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (tokens) |token| {
        if (text.items.len + token.len > 65536) return error.InvalidTime;
        try text.appendSlice(allocator, token);
        try text.append(allocator, ' ');
    }
    var l = Lexer{ .text = text.items };
    const first = l.next() orelse return error.InvalidTime;
    if (std.ascii.eqlIgnoreCase(first, "now")) {
        var z = try zone(allocator, tz);
        defer z.deinit();
        _ = try z.local(now);
        const result = try increment(&l, &z, now);
        if (l.next() != null) return error.InvalidTime;
        return result;
    }
    var hour: i64 = 0;
    var minute: i64 = 0;
    const named = std.ascii.eqlIgnoreCase(first, "noon") or std.ascii.eqlIgnoreCase(first, "midnight");
    if (named) {
        hour = if (std.ascii.eqlIgnoreCase(first, "noon")) 12 else 0;
    } else {
        if (first.len != 1 and first.len != 2 and first.len != 4) return error.InvalidTime;
        const h = try num(first);
        if (first.len == 4) {
            hour = @divFloor(h, 100);
            minute = @mod(h, 100);
        } else hour = h;
        if (l.accept(":")) {
            if (first.len == 4) return error.InvalidTime;
            const m = l.next() orelse return error.InvalidTime;
            if (m.len < 1 or m.len > 2) return error.InvalidTime;
            minute = try num(m);
        }
        if (l.accept("am")) {
            if (hour < 1 or hour > 12) return error.InvalidTime;
            hour = @mod(hour, 12);
        } else if (l.accept("pm")) {
            if (hour < 1 or hour > 12) return error.InvalidTime;
            hour = @mod(hour, 12) + 12;
        }
        if (hour > 23 or minute > 59) return error.InvalidTime;
    }
    const is_utc = !named and l.accept("utc");
    var z = try zone(allocator, if (is_utc) "UTC0" else tz);
    defer z.deinit();
    var c = try z.local(now);
    c.hour = hour;
    c.minute = minute;
    c.second = 0;
    var date_kind: enum { implicit, fixed, weekday, month } = .implicit;
    if (l.peek()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "today")) {
            _ = l.next();
            date_kind = .fixed;
        } else if (std.ascii.eqlIgnoreCase(token, "tomorrow")) {
            _ = l.next();
            try addDays(&c, 1);
            date_kind = .fixed;
        } else if (nameIndex(token, &weekdays)) |wd| {
            _ = l.next();
            try addDays(&c, @mod(wd - @mod(days(c) + 4, 7), 7));
            date_kind = .weekday;
        } else if (nameIndex(token, &months)) |m| {
            _ = l.next();
            c.month = m + 1;
            c.day = try num(l.next() orelse return error.InvalidTime);
            date_kind = .month;
            if (l.accept(",")) {
                const y = l.next() orelse return error.InvalidTime;
                if (y.len != 4) return error.InvalidTime;
                c.year = try num(y);
                date_kind = .fixed;
            } else {
                const current = try z.local(now);
                if (c.month < current.month) c.year += 1;
            }
        }
    }
    if (!valid(c)) return error.InvalidTime;
    var result = z.resolve(c, now) catch |err| switch (err) {
        error.NonexistentTime => blk: {
            // An implicit clock time already passed in today's gap means
            // tomorrow, rather than a request for that nonexistent instant.
            if ((date_kind != .implicit and date_kind != .weekday) or try scalar(c) >= try scalar(try z.local(now))) return err;
            try addDays(&c, if (date_kind == .weekday) 7 else 1);
            break :blk try z.resolve(c, now);
        },
        error.PastTime => blk: {
            if (date_kind == .implicit or date_kind == .weekday) {
                try addDays(&c, if (date_kind == .weekday) 7 else 1);
            } else if (date_kind == .month and c.month != (try z.local(now)).month) {
                c.year += 1;
            } else return err;
            break :blk try z.resolve(c, now);
        },
        else => return err,
    };
    result = try increment(&l, &z, result);
    if (l.next() != null) return error.InvalidTime;
    return result;
}

/// Parse [[CC]YY]MMDDhhmm[.SS], using the touch two-digit-year pivot.
pub fn parseNumeric(allocator: std.mem.Allocator, now: i64, tz: ?[]const u8, token: []const u8) !i64 {
    var z = try zone(allocator, tz);
    defer z.deinit();
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse token.len;
    if (dot != 8 and dot != 10 and dot != 12) return error.InvalidTime;
    if (dot != token.len and token.len != dot + 3) return error.InvalidTime;
    var c = try z.local(now);
    const prefix = dot - 8;
    if (prefix == 2) {
        const y = try num(token[0..2]);
        c.year = if (y <= 68) 2000 + y else 1900 + y;
    }
    if (prefix == 4) c.year = try num(token[0..4]);
    c.month = try num(token[prefix..][0..2]);
    c.day = try num(token[prefix + 2 ..][0..2]);
    c.hour = try num(token[prefix + 4 ..][0..2]);
    c.minute = try num(token[prefix + 6 ..][0..2]);
    c.second = if (dot == token.len) 0 else try num(token[dot + 1 ..]);
    if (c.second > 60) return error.InvalidTime;
    const leap_second = c.second == 60;
    if (leap_second) c.second = 59;
    const result = try z.resolve(c, if (leap_second and now > std.math.minInt(i64)) now - 1 else now);
    const final = std.math.add(i64, result, @as(i64, if (leap_second) 1 else 0)) catch return error.OutOfRange;
    if (final < now) return error.PastTime;
    return final;
}

/// Format in the C locale as date +"%a %b %e %T %Y".
pub fn format(allocator: std.mem.Allocator, seconds: i64, tz: ?[]const u8, buf: []u8) ![]const u8 {
    var z = try zone(allocator, tz);
    defer z.deinit();
    const c = try z.local(seconds);
    const weekday: usize = @intCast(@mod(days(c) + 4, 7));
    const month: usize = @intCast(c.month - 1);
    return std.fmt.bufPrint(buf, "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d:0>4}", .{ weekdays[weekday][0..3], months[month][0..3], @as(u8, @intCast(c.day)), @as(u8, @intCast(c.hour)), @as(u8, @intCast(c.minute)), @as(u8, @intCast(c.second)), @as(u16, @intCast(c.year)) });
}

test "at: numeric pivot, leap seconds and formatting" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 0), try parseNumeric(a, -1, "UTC0", "197001010000"));
    try std.testing.expectEqual(@as(i64, 60), try parseNumeric(a, 0, "UTC0", "197001010000.60"));
    try std.testing.expectError(error.PastTime, parseNumeric(a, 0, "UTC0", "6901010000"));
    try std.testing.expectEqual(@as(i64, 3092601600), try parseNumeric(a, 0, "UTC0", "6801010000"));
    try std.testing.expectError(error.InvalidTime, parseNumeric(a, 0, "UTC0", "202302290100"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Thu Jan  1 00:00:00 1970", try format(a, 0, "UTC0", &buf));
    try std.testing.expectEqualStrings("Wed Dec 31 23:59:59 1969", try format(a, -1, "UTC0", &buf));
}
test "at: C locale grammar and injected now" {
    const a = std.testing.allocator;
    const now: i64 = 1704110400; // 2024-01-01 12:00 UTC
    try std.testing.expectEqual(now, try parse(a, now, "UTC0", &.{"now"}));
    try std.testing.expectEqual(now + 86400 + 3600, try parse(a, now, "UTC0", &.{ "1pm", "tomorrow" }));
    try std.testing.expectEqual(now + 1800, try parse(a, now, "UTC0", &.{ "12:30", "UTC" }));
    try std.testing.expectEqual(now + 86400, try parse(a, now, "UTC0", &.{ "now", "+1day" }));
    try std.testing.expectEqual(now + 3600, try parse(a, now, "UTC0", &.{ "1pm", "Monday" }));
    try std.testing.expectError(error.PastTime, parse(a, now, "UTC0", &.{ "11", "today" }));
    try std.testing.expectError(error.InvalidTime, parse(a, now, "UTC0", &.{ "now", "tomorrow" }));
    try std.testing.expectError(error.InvalidTime, parse(a, now, "UTC0", &.{ "123", "today" }));
}
test "at: dates, UTC override and invalid syntax" {
    const a = std.testing.allocator;
    const now: i64 = 1704110400;
    try std.testing.expectEqual(@as(i64, 1709208000), try parse(a, now, "UTC0", &.{ "12", "FEB", "29,2024" }));
    try std.testing.expectEqual(now + 3600, try parse(a, now, "EST5", &.{"13utc"}));
    try std.testing.expectEqual(@as(i64, 1735722000), try parse(a, 1735689600, "UTC0", &.{ "9", "Jan", "1" }));
    try std.testing.expectError(error.PastTime, parse(a, now, "UTC0", &.{ "11", "Jan", "1" }));
    try std.testing.expectError(error.InvalidTime, parse(a, now, "UTC0", &.{"13pm"}));
    try std.testing.expectError(error.InvalidTime, parse(a, now, "UTC0", &.{"12:60"}));
    try std.testing.expectError(error.InvalidTime, parse(a, now, "UTC0", &.{ "now", "+1", "fortnight" }));
    try std.testing.expectError(error.OutOfRange, parse(a, std.math.maxInt(i64), "UTC0", &.{"now"}));
    try std.testing.expectError(error.InvalidTimezone, parse(a, now, "invalid-zone", &.{"now"}));
    try std.testing.expectError(error.InvalidTime, parse(a, 1706659200, "UTC0", &.{ "now", "next", "month" }));
}
test "at: POSIX DST gap fold and calendar increments" {
    const a = std.testing.allocator;
    const tz = "EST5EDT,M3.2.0/2,M11.1.0/2";
    try std.testing.expectError(error.NonexistentTime, parseNumeric(a, 0, tz, "202403100230"));
    try std.testing.expectEqual(@as(i64, 1730611800), try parseNumeric(a, 0, tz, "202411030130"));
    try std.testing.expectEqual(@as(i64, 1730615400), try parseNumeric(a, 1730611801, tz, "202411030130"));
    try std.testing.expectEqual(@as(i64, 1710086400), try parse(a, 1710003600, tz, &.{ "now", "next", "day" }));
    try std.testing.expectError(error.NonexistentTime, parse(a, 1709969400, tz, &.{ "now", "next", "day" }));
    try std.testing.expectEqual(@as(i64, 1710138600), try parse(a, 1710057600, tz, &.{"2:30"}));
    try std.testing.expectError(error.NonexistentTime, parse(a, 1710057600, tz, &.{ "2:30", "today" }));
}
test "at: POSIX southern hemisphere and Julian rules" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const south = "AEST-10AEDT-11,M10.1.0,M4.1.0/3";
    try std.testing.expectEqualStrings("Mon Jan  1 11:00:00 2024", try format(a, 1704067200, south, &buf));
    try std.testing.expectEqualStrings("Mon Jul  1 10:00:00 2024", try format(a, 1719792000, south, &buf));
    const julian = "AAA0BBB,J60/0,J300/0";
    try std.testing.expectEqualStrings("Thu Feb 29 00:00:00 2024", try format(a, 1709164800, julian, &buf));
    try std.testing.expectEqualStrings("Fri Mar  1 01:00:00 2024", try format(a, 1709251200, julian, &buf));
}
test "at: system zoneinfo and future footer" {
    const a = std.testing.allocator;
    const tz = "America/New_York";
    const fixture = loadFile(a, "/usr/share/zoneinfo/America/New_York") catch |err| switch (err) {
        error.TimezoneNotFound => return error.SkipZigTest,
        else => return err,
    };
    a.free(fixture);
    try std.testing.expectError(error.NonexistentTime, parseNumeric(a, 0, tz, "202403100230"));
    try std.testing.expectEqual(@as(i64, 1730611800), try parseNumeric(a, 0, tz, "202411030130"));
    const x = try parseNumeric(a, 0, tz, "205007010800");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Fri Jul  1 08:00:00 2050", try format(a, x, tz, &buf));
}

test "at: unset timezone uses localtime" {
    const a = std.testing.allocator;
    var z = zone(a, null) catch |err| switch (err) {
        error.TimezoneNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer z.deinit();
    const instant: i64 = 1704110400;
    const local = try z.local(instant);
    try std.testing.expectEqual(instant, try z.resolve(local, instant));
    var buf: [64]u8 = undefined;
    _ = try format(a, instant, null, &buf);
}
