//! Shell word expansion and C-locale pattern matching.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const syntax = @import("syntax.zig");

pub const Mode = enum { arguments, assignment, redirection, pattern, heredoc };

const Byte = struct { value: u8, split: bool = false, quoted: bool = false, empty: bool = false };
const Field = struct { bytes: std.ArrayList(Byte) = .empty, keep: bool = false };

fn append(a: Allocator, field: *Field, text: []const u8, split: bool, quoted: bool) !void {
    for (text) |c| try field.bytes.append(a, .{ .value = c, .split = split, .quoted = quoted });
}

fn empty(a: Allocator, field: *Field) !void {
    try field.bytes.append(a, .{ .value = 0, .quoted = true, .empty = true });
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isName(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

// Locate a parameter's closing brace without confusing quoted or nested substitutions.
fn parameterEnd(a: Allocator, raw: []const u8, start: usize, outer_double: bool, depth: usize) anyerror!usize {
    if (depth >= 128) return error.DepthLimit;
    if (start == raw.len) return error.BadExpansion;
    var op = start + 1;
    if (isName(raw[start])) while (op < raw.len and isName(raw[op])) : (op += 1) {};
    const double = outer_double and (op == raw.len or (raw[op] != '%' and raw[op] != '#'));
    var i = start;
    var quote: u8 = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and quote != '\'') {
            i += 1;
            continue;
        }
        if (c == '\'' and quote != '"' and !double) {
            quote = if (quote == '\'') 0 else '\'';
            continue;
        }
        if (c == '"' and quote != '\'') {
            quote = if (quote == '"') 0 else '"';
            continue;
        }
        if (quote == '\'') continue;
        if (c == '$' and i + 1 < raw.len and (raw[i + 1] == '(' or raw[i + 1] == '{')) {
            if (raw[i + 1] == '(') {
                i += 1 + try syntax.substitutionEnd(a, raw[i + 2 ..]);
            } else {
                i = try parameterEnd(a, raw, i + 2, double or quote == '"', depth + 1);
            }
            continue;
        }
        if (quote == 0 and c == '}') return i;
    }
    return error.BadExpansion;
}

fn plain(a: Allocator, bytes: []const Byte) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| if (!b.empty) try out.append(a, b.value);
    return out.toOwnedSlice(a);
}

fn patternBytes(a: Allocator, bytes: []const Byte) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| {
        if (b.empty) continue;
        if (b.quoted and (b.value == '*' or b.value == '?' or b.value == '[' or b.value == ']' or b.value == '\\' or b.value == '-' or b.value == '!' or b.value == '^')) try out.append(a, '\\');
        try out.append(a, b.value);
    }
    return out.toOwnedSlice(a);
}

fn addFields(a: Allocator, fields: *std.ArrayList(Field), values: []const []const u8, quoted: bool, split: bool) !void {
    for (values, 0..) |value, i| {
        if (i != 0) try fields.append(a, .{});
        const f = &fields.items[fields.items.len - 1];
        try append(a, f, value, split, quoted);
        if (quoted and value.len == 0) try empty(a, f);
    }
}

fn expand(ctx: anytype, a: Allocator, raw: []const u8, mode: Mode, inherited_quote: bool, depth: usize) anyerror!std.ArrayList(Field) {
    if (depth >= 128) return error.DepthLimit;
    var fields: std.ArrayList(Field) = .empty;
    try fields.append(a, .{});
    var quote: u8 = if (inherited_quote) '"' else 0;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        const heredoc = mode == .heredoc;
        if (inherited_quote and c == '"') {
            if (i + 1 < raw.len and raw[i + 1] == '"') try empty(a, &fields.items[fields.items.len - 1]);
            i += 1;
            continue;
        }
        if (!heredoc and !inherited_quote and c == '\'' and quote != '"') {
            if (quote == 0 and i + 1 < raw.len and raw[i + 1] == '\'') try empty(a, &fields.items[fields.items.len - 1]);
            quote = if (quote == '\'') 0 else '\'';
            i += 1;
            continue;
        }
        if (!heredoc and !inherited_quote and c == '"' and quote != '\'') {
            if (quote == 0 and i + 1 < raw.len and raw[i + 1] == '"') try empty(a, &fields.items[fields.items.len - 1]);
            quote = if (quote == '"') 0 else '"';
            i += 1;
            continue;
        }
        const quoted = quote != 0;
        if (c == '\\' and quote != '\'' and i + 1 < raw.len) {
            const next = raw[i + 1];
            if (next == '\n') {
                i += 2;
                continue;
            }
            if ((!heredoc and quote == 0) or next == '$' or next == '`' or next == '\\' or (!heredoc and (next == '"' or (inherited_quote and next == '}')))) {
                try append(a, &fields.items[fields.items.len - 1], raw[i + 1 .. i + 2], false, true);
                i += 2;
                continue;
            }
        }
        if (heredoc and c == '`') return error.Unsupported;
        if (c == '~' and quote == 0 and !heredoc and (i == 0 or (mode == .assignment and raw[i - 1] == ':')) and (i + 1 == raw.len or raw[i + 1] == '/' or (mode == .assignment and raw[i + 1] == ':'))) {
            if (ctx.parameter("HOME")) |home| {
                try append(a, &fields.items[fields.items.len - 1], home, false, true);
                if (home.len == 0) try empty(a, &fields.items[fields.items.len - 1]);
                i += 1;
                continue;
            }
        }
        if (c != '$' or quote == '\'' or i + 1 == raw.len) {
            try append(a, &fields.items[fields.items.len - 1], raw[i .. i + 1], false, quoted);
            i += 1;
            continue;
        }
        const next = raw[i + 1];
        if (next == '!') return error.Unsupported;
        if (next == '(') {
            const end = i + 1 + try syntax.substitutionEnd(a, raw[i + 2 ..]);
            const result = try ctx.substitute(a, raw[i + 2 .. end]);
            try append(a, &fields.items[fields.items.len - 1], result, !quoted, quoted);
            if (quoted and result.len == 0) try empty(a, &fields.items[fields.items.len - 1]);
            i = end + 1;
            continue;
        }
        var name: []const u8 = undefined;
        var op: []const u8 = "";
        var operand: []const u8 = "";
        if (next == '{') {
            const end = try parameterEnd(a, raw, i + 2, quoted, 0);
            const body = raw[i + 2 .. end];
            if (body.len == 0) return error.BadExpansion;
            var n: usize = 0;
            if (body[0] == '#' and body.len > 1 and body[1] != '}' and (isNameStart(body[1]) or std.ascii.isDigit(body[1]) or std.mem.indexOfScalar(u8, "@*?#$-", body[1]) != null)) {
                n = 1;
                if (isNameStart(body[n])) {
                    n += 1;
                    while (n < body.len and isName(body[n])) : (n += 1) {}
                } else if (std.ascii.isDigit(body[n])) {
                    while (n < body.len and std.ascii.isDigit(body[n])) : (n += 1) {}
                } else n += 1;
                if (n != body.len) return error.BadExpansion;
                const value = ctx.parameter(body[1..n]);
                const len = if (body[1] == '@' or body[1] == '*') ctx.positionals().len else if (value) |v| v.len else 0;
                const s = try std.fmt.allocPrint(a, "{d}", .{len});
                try append(a, &fields.items[fields.items.len - 1], s, !quoted, quoted);
                i = end + 1;
                continue;
            }
            if (isNameStart(body[0])) {
                n = 1;
                while (n < body.len and isName(body[n])) : (n += 1) {}
            } else if (std.ascii.isDigit(body[0])) {
                while (n < body.len and std.ascii.isDigit(body[n])) : (n += 1) {}
            } else if (std.mem.indexOfScalar(u8, "@*?#$-", body[0]) != null) n = 1 else return error.BadExpansion;
            name = body[0..n];
            if (n < body.len) {
                const start = n;
                if (body[n] == ':') n += 1;
                if (n >= body.len or std.mem.indexOfScalar(u8, "-+=?%#", body[n]) == null) return error.BadExpansion;
                const operator = body[n];
                n += 1;
                if (body[start] == ':' and (operator == '%' or operator == '#')) return error.BadExpansion;
                if ((operator == '%' or operator == '#') and n < body.len and body[n] == operator) n += 1;
                op = body[start..n];
                operand = body[n..];
            }
            i = end + 1;
        } else {
            var n = i + 1;
            if (isNameStart(next)) {
                n += 1;
                while (n < raw.len and isName(raw[n])) : (n += 1) {}
            } else if (std.ascii.isDigit(next) or std.mem.indexOfScalar(u8, "@*?#$-", next) != null) n += 1 else {
                try append(a, &fields.items[fields.items.len - 1], "$", false, quoted);
                i += 1;
                continue;
            }
            name = raw[i + 1 .. n];
            i = n;
        }
        if (op.len == 0 and (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*"))) {
            const pos = ctx.positionals();
            if (name[0] == '@' and mode != .assignment and mode != .heredoc and mode != .pattern) {
                try addFields(a, &fields, pos, quoted, !quoted);
            } else {
                const old_len = fields.items[fields.items.len - 1].bytes.items.len;
                const ifs = ctx.parameter("IFS") orelse " \t\n";
                const sep: []const u8 = if (ifs.len == 0) "" else ifs[0..1];
                for (pos, 0..) |v, j| {
                    if (j != 0) try append(a, &fields.items[fields.items.len - 1], sep, !quoted, quoted);
                    try append(a, &fields.items[fields.items.len - 1], v, !quoted, quoted);
                }
                if (quoted and fields.items[fields.items.len - 1].bytes.items.len == old_len) try empty(a, &fields.items[fields.items.len - 1]);
            }
            continue;
        }
        // Copy immediately: the runtime may reuse its parameter scratch buffer.
        const maybe = if (ctx.parameter(name)) |v| try a.dupe(u8, v) else null;
        var value: []const u8 = maybe orelse "";
        if (op.len != 0) {
            const colon = op[0] == ':';
            const operator = op[if (colon) @as(usize, 1) else 0];
            const absent = maybe == null or (colon and value.len == 0);
            if (operator == '%' or operator == '#') {
                const expanded = try expand(ctx, a, operand, .pattern, false, depth + 1);
                var pattern: std.ArrayList(Byte) = .empty;
                for (expanded.items) |f| try pattern.appendSlice(a, f.bytes.items);
                const p = try patternBytes(a, pattern.items);
                const longest = op.len == 2;
                var k: usize = 0;
                while (k <= value.len) : (k += 1) {
                    const cut = if (longest) value.len - k else k;
                    const candidate = if (operator == '#') value[0..cut] else value[value.len - cut ..];
                    if (matches(p, candidate)) {
                        value = if (operator == '#') value[cut..] else value[0 .. value.len - cut];
                        break;
                    }
                }
            } else if ((operator == '+' and !absent) or (operator != '+' and absent)) {
                const operand_mode: Mode = if (operator == '=' or operator == '?') .assignment else mode;
                const expanded = try expand(ctx, a, operand, operand_mode, quoted, depth + 1);
                var temp: std.ArrayList(u8) = .empty;
                for (expanded.items) |f| for (f.bytes.items) |b| {
                    if (!b.empty) try temp.append(a, b.value);
                };
                value = temp.items;
                if (operator == '=') try ctx.assignParameter(name, value);
                if (operator == '?') {
                    if (@hasDecl(@TypeOf(ctx.*), "expansionError")) ctx.expansionError(name, if (value.len == 0) "parameter not set" else value);
                    return error.ExpansionError;
                }
                for (expanded.items, 0..) |f, field_index| {
                    if (field_index != 0) try fields.append(a, .{});
                    const target = &fields.items[fields.items.len - 1];
                    for (f.bytes.items) |b| try target.bytes.append(a, .{ .value = b.value, .quoted = b.quoted, .split = !b.quoted, .empty = b.empty });
                    if (quoted and f.bytes.items.len == 0) try empty(a, target);
                }
                continue;
            } else if (operator == '+') value = "";
        }
        try append(a, &fields.items[fields.items.len - 1], value, !quoted, quoted);
        if (quoted and value.len == 0) try empty(a, &fields.items[fields.items.len - 1]);
    }
    if (mode != .heredoc and !inherited_quote and quote != 0) return error.BadExpansion;
    return fields;
}

fn isIfs(b: Byte, ifs: []const u8) bool {
    return b.split and std.mem.indexOfScalar(u8, ifs, b.value) != null;
}
fn isWhite(b: Byte, ifs: []const u8) bool {
    return isIfs(b, ifs) and (b.value == ' ' or b.value == '\t' or b.value == '\n');
}

fn splitFields(a: Allocator, input: []const Field, ifs: []const u8) !std.ArrayList(Field) {
    var result: std.ArrayList(Field) = .empty;
    for (input) |f| {
        const bytes = f.bytes.items;
        var i: usize = 0;
        while (i < bytes.len and isWhite(bytes[i], ifs)) : (i += 1) {}
        var current: Field = .{ .keep = f.keep };
        while (i < bytes.len) {
            if (bytes[i].empty) {
                current.keep = true;
                i += 1;
                continue;
            }
            if (!isIfs(bytes[i], ifs)) {
                try current.bytes.append(a, bytes[i]);
                i += 1;
                continue;
            }
            const white = isWhite(bytes[i], ifs);
            if (white) {
                while (i < bytes.len and isWhite(bytes[i], ifs)) : (i += 1) {}
                if (i < bytes.len and isIfs(bytes[i], ifs) and !isWhite(bytes[i], ifs)) {
                    i += 1;
                    while (i < bytes.len and isWhite(bytes[i], ifs)) : (i += 1) {}
                }
            } else {
                i += 1;
                while (i < bytes.len and isWhite(bytes[i], ifs)) : (i += 1) {}
            }
            if (current.bytes.items.len != 0 or current.keep or !white) try result.append(a, current);
            current = .{};
        }
        if (current.bytes.items.len != 0 or current.keep) try result.append(a, current);
    }
    return result;
}

fn classMatch(name: []const u8, c: u8) bool {
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return c < 32 or c == 127;
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "graph")) return c >= 33 and c <= 126;
    if (std.mem.eql(u8, name, "lower")) return c >= 'a' and c <= 'z';
    if (std.mem.eql(u8, name, "print")) return c >= 32 and c <= 126;
    if (std.mem.eql(u8, name, "punct")) return c >= 33 and c <= 126 and !std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "space")) return c == ' ' or (c >= '\t' and c <= '\r');
    if (std.mem.eql(u8, name, "upper")) return c >= 'A' and c <= 'Z';
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    return false;
}

fn bracket(p: []const u8, c: u8) ?struct { len: usize, matched: bool } {
    var i: usize = 1;
    const negate = i < p.len and (p[i] == '!' or p[i] == '^');
    if (negate) i += 1;
    var hit = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ .len = i + 1, .matched = hit != negate };
        first = false;
        if (i + 1 < p.len and p[i] == '[' and p[i + 1] == ':') {
            if (std.mem.indexOf(u8, p[i + 2 ..], ":]")) |end| {
                hit = hit or classMatch(p[i + 2 .. i + 2 + end], c);
                i += end + 4;
                continue;
            }
        }
        if (p[i] == '\\' and i + 1 < p.len) i += 1;
        const lo = p[i];
        i += 1;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            i += 1;
            if (p[i] == '\\' and i + 1 < p.len) i += 1;
            hit = hit or (c >= lo and c <= p[i]);
            i += 1;
        } else hit = hit or c == lo;
    }
    return null;
}

/// Match a byte-oriented shell pattern; backslash quotes the following byte.
pub fn matches(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and pattern[p] == '*') {
            p += 1;
            star = p;
            retry = v;
            continue;
        }
        var consumed: usize = 0;
        if (p < pattern.len) {
            if (pattern[p] == '?') consumed = 1 else if (pattern[p] == '[') {
                if (bracket(pattern[p..], value[v])) |b| {
                    if (b.matched) consumed = b.len;
                } else if (value[v] == '[') consumed = 1;
            } else if (pattern[p] == '\\' and p + 1 < pattern.len) {
                if (pattern[p + 1] == value[v]) consumed = 2;
            } else if (pattern[p] == value[v]) consumed = 1;
        }
        if (consumed != 0) {
            p += consumed;
            v += 1;
            continue;
        }
        if (star) |s| {
            retry += 1;
            v = retry;
            p = s;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn glob(a: Allocator, bytes: []const Byte) !std.ArrayList([]const u8) {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(a, if (bytes.len != 0 and bytes[0].value == '/') "/" else "");
    var start: usize = if (bytes.len != 0 and bytes[0].value == '/') 1 else 0;
    var any_magic = false;
    while (start < bytes.len) {
        var end = start;
        while (end < bytes.len and bytes[end].value != '/') : (end += 1) {}
        const component = bytes[start..end];
        var magic = false;
        for (component) |b| if (!b.quoted and (b.value == '*' or b.value == '?' or b.value == '[')) {
            magic = true;
            break;
        };
        any_magic = any_magic or magic;
        var next: std.ArrayList([]const u8) = .empty;
        for (paths.items) |prefix| {
            if (!magic) {
                const part = try plain(a, component);
                const path = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, if (prefix.len != 0 and (prefix[prefix.len - 1] != '/' or part.len == 0)) "/" else "", part });
                if (any_magic) {
                    const z = try a.dupeSentinel(u8, if (path.len == 0) "." else path, 0);
                    var stat: linux.Statx = undefined;
                    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &stat)) != .SUCCESS) continue;
                }
                try next.append(a, path);
                continue;
            }
            const dir = try a.dupeSentinel(u8, if (prefix.len == 0) "." else prefix, 0);
            const rc = linux.openat(linux.AT.FDCWD, dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: linux.fd_t = @intCast(rc);
            defer _ = linux.close(fd);
            const pat = try patternBytes(a, component);
            var buf: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
            while (true) {
                const n = linux.getdents64(fd, &buf, buf.len);
                if (linux.errno(n) == .INTR) continue;
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
                    if (ent.reclen < @offsetOf(linux.dirent64, "name") + 1 or off + ent.reclen > n) break;
                    const names = buf[off + @offsetOf(linux.dirent64, "name") .. off + ent.reclen];
                    const len = std.mem.indexOfScalar(u8, names, 0) orelse names.len;
                    const name = names[0..len];
                    off += ent.reclen;
                    if (name.len == 0 or (name[0] == '.' and (component.len == 0 or component[0].value != '.'))) continue;
                    if (!matches(pat, name)) continue;
                    try next.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, if (prefix.len != 0 and prefix[prefix.len - 1] != '/') "/" else "", name }));
                }
            }
        }
        paths = next;
        start = end + 1;
        if (end < bytes.len and start == bytes.len) {
            var dirs: std.ArrayList([]const u8) = .empty;
            for (paths.items) |path| {
                const z = try a.dupeSentinel(u8, path, 0);
                const rc = linux.openat(linux.AT.FDCWD, z, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
                if (linux.errno(rc) != .SUCCESS) continue;
                _ = linux.close(@intCast(rc));
                try dirs.append(a, try std.fmt.allocPrint(a, "{s}/", .{path}));
            }
            paths = dirs;
        }
    }
    if (!any_magic) paths = .empty;
    std.mem.sort([]const u8, paths.items, {}, less);
    return paths;
}

/// Expand a raw word. The caller owns the returned slice and each of its strings.
pub fn word(ctx: anytype, allocator: Allocator, raw: []const u8, mode: Mode) anyerror![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fields = try expand(ctx, a, raw, mode, false, 0);
    if (mode == .arguments) {
        const ifs = if (ctx.parameter("IFS")) |v| try a.dupe(u8, v) else " \t\n";
        fields = try splitFields(a, fields.items, ifs);
    }
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |s| allocator.free(s);
        result.deinit(allocator);
    }
    for (fields.items) |f| {
        if (mode == .arguments and !ctx.noglob()) {
            const paths = try glob(a, f.bytes.items);
            if (paths.items.len != 0) {
                for (paths.items) |path| {
                    const copy = try allocator.dupe(u8, path);
                    result.append(allocator, copy) catch |err| {
                        allocator.free(copy);
                        return err;
                    };
                }
                continue;
            }
        }
        const value = if (mode == .pattern) try patternBytes(a, f.bytes.items) else try plain(a, f.bytes.items);
        const copy = try allocator.dupe(u8, value);
        result.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };
    }
    return result.toOwnedSlice(allocator);
}

const TestContext = struct {
    value: ?[]const u8 = null,
    ifs: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    assigned: std.ArrayList(u8) = .empty,
    no_glob: bool = true,

    pub fn parameter(self: *@This(), name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "x")) return self.value;
        if (std.mem.eql(u8, name, "IFS")) return self.ifs;
        if (std.mem.eql(u8, name, "HOME")) return "/home/test";
        return null;
    }
    pub fn positionals(self: *@This()) []const []const u8 {
        return self.args;
    }
    pub fn assignParameter(self: *@This(), _: []const u8, value: []const u8) !void {
        try self.assigned.appendSlice(std.testing.allocator, value);
    }
    pub fn substitute(_: *@This(), a: Allocator, script: []const u8) ![]const u8 {
        return a.dupe(u8, script);
    }
    pub fn noglob(self: *@This()) bool {
        return self.no_glob;
    }
};

fn expectWord(ctx: *TestContext, raw: []const u8, mode: Mode, expected: []const []const u8) !void {
    const a = std.testing.allocator;
    const actual = try word(ctx, a, raw, mode);
    defer {
        for (actual) |s| a.free(s);
        a.free(actual);
    }
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "sh: expansion quotes splitting and positional fields" {
    var ctx: TestContext = .{ .value = "a b", .args = &.{ "one", "two three", "" } };
    try expectWord(&ctx, "pre${x}post", .arguments, &.{ "prea", "bpost" });
    try expectWord(&ctx, "\"$x\"", .arguments, &.{"a b"});
    try expectWord(&ctx, "a\"$@\"z", .arguments, &.{ "aone", "two three", "z" });
    ctx.args = &.{};
    try expectWord(&ctx, "\"$@\"", .arguments, &.{});
    try expectWord(&ctx, "''", .arguments, &.{""});
    ctx.args = &.{ "a a", "b" };
    try expectWord(&ctx, "\"${missing:-$@}\"", .arguments, &.{ "a a", "b" });
    ctx.value = "a ";
    try expectWord(&ctx, "$x\"\"", .arguments, &.{ "a", "" });
    ctx.value = "  ";
    try expectWord(&ctx, "$x\"\"", .arguments, &.{""});
    ctx.ifs = ":";
    ctx.value = "a::b";
    try expectWord(&ctx, "$x", .arguments, &.{ "a", "", "b" });
    try expectWord(&ctx, "x:y", .arguments, &.{"x:y"});
}

test "sh: parameter operators and patterns" {
    var ctx: TestContext = .{ .value = "abcabc" };
    defer ctx.assigned.deinit(std.testing.allocator);
    try expectWord(&ctx, "${x#a*c}", .arguments, &.{"abc"});
    try expectWord(&ctx, "${x##a*c}", .assignment, &.{""});
    try expectWord(&ctx, "${x%a*c}", .arguments, &.{"abc"});
    try expectWord(&ctx, "${missing:-$(abc)}", .arguments, &.{"abc"});
    try expectWord(&ctx, "${missing:=hello}", .assignment, &.{"hello"});
    try std.testing.expectEqualStrings("hello", ctx.assigned.items);
    try expectWord(&ctx, "${missing:-\"a b\"}", .arguments, &.{"a b"});
    try expectWord(&ctx, "\"${missing:-\"hello\"}\"", .arguments, &.{"hello"});
    try expectWord(&ctx, "$x", .redirection, &.{"abcabc"});
    try expectWord(&ctx, "'a*'b?", .pattern, &.{"a\\*b?"});
    try std.testing.expect(matches("a[[:digit:]]*[!x]", "a3zzz"));
    try std.testing.expect(!matches("a[[:digit:]]*[!x]", "a3zx"));
    try std.testing.expect(matches("a\\*", "a*"));
}

test "sh: heredoc and substitution boundaries" {
    var ctx: TestContext = .{ .value = "ok" };
    try expectWord(&ctx, "'\"$x\"' \\$x $(a$(b)c)", .heredoc, &.{"'\"ok\"' $x a$(b)c"});
    try expectWord(&ctx, "\"$(foo # )\nbar)\"", .arguments, &.{"foo # )\nbar"});
    try expectWord(&ctx, "\"$(case x in x) :;; esac)\"", .arguments, &.{"case x in x) :;; esac"});
    try expectWord(&ctx, "\"$(cat <<EOF\n)\nEOF\n)\"", .arguments, &.{"cat <<EOF\n)\nEOF\n"});
    try expectWord(&ctx, "~/file", .assignment, &.{"/home/test/file"});
}

test "sh: pathname expansion sorts and excludes hidden names" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden.txt", .data = "" });
    const a = std.testing.allocator;
    const prefix = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/", .{temp.sub_path});
    defer a.free(prefix);
    const pat = try std.fmt.allocPrint(a, "{s}*.txt", .{prefix});
    defer a.free(pat);
    const first = try std.fmt.allocPrint(a, "{s}a.txt", .{prefix});
    defer a.free(first);
    const second = try std.fmt.allocPrint(a, "{s}b.txt", .{prefix});
    defer a.free(second);
    var ctx: TestContext = .{ .no_glob = false };
    try expectWord(&ctx, pat, .arguments, &.{ first, second });
    ctx.no_glob = true;
    try expectWord(&ctx, pat, .arguments, &.{pat});
}

fn allocationTest(a: Allocator) !void {
    var ctx: TestContext = .{ .value = "abc def", .no_glob = false };
    const result = try word(&ctx, a, "prefix${x:-fallback}suffix", .arguments);
    defer {
        for (result) |s| a.free(s);
        a.free(result);
    }
}

test "sh: expansion releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTest, .{});
}
