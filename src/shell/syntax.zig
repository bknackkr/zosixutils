//! Streaming shell syntax and complete-command parser.
const std = @import("std");
const alias = @import("../commands/alias.zig");
const Allocator = std.mem.Allocator;

pub const Input = struct { context: *anyopaque, next: *const fn (*anyopaque) anyerror!?u8 };
pub const Word = []const u8;
pub const Simple = struct { words: []const Word, redirs: []const Redirection };
pub const AndOr = struct {
    pub const Part = struct { op: enum { and_if, or_if }, node: *const Node };
    first: *const Node,
    rest: []const Part,
};
pub const Pipeline = struct { stages: []const *const Node, negate: bool };
pub const Conditional = struct {
    pub const Branch = struct { condition: *const Node, body: *const Node };
    branches: []const Branch,
    otherwise: ?*const Node,
};
pub const Loop = struct { condition: *const Node, body: *const Node, until: bool };
pub const ForLoop = struct { name: []const u8, words: ?[]const Word, body: *const Node };
pub const Case = struct {
    pub const Arm = struct { patterns: []const Word, body: *const Node, fallthrough: bool };
    word: Word,
    arms: []const Arm,
};
pub const Function = struct { name: []const u8, body: *const Node };
pub const Redirected = struct { node: *const Node, redirs: []const Redirection };
pub const Redirection = struct {
    pub const Op = enum { input, output, append, read_write, clobber, dup_input, dup_output, here, here_strip };
    target: i32,
    op: Op,
    word: Word,
    here_doc: ?*const HereDoc = null,
};
pub const HereDoc = struct { body: []const u8, expand: bool };
pub const Node = union(enum) {
    simple: Simple,
    sequence: []const *const Node,
    and_or: AndOr,
    pipeline: Pipeline,
    group: *const Node,
    subshell: *const Node,
    conditional: Conditional,
    loop: Loop,
    for_loop: ForLoop,
    case: Case,
    function: Function,
    redirected: Redirected,
};

fn nameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn nameChar(c: u8) bool {
    return nameStart(c) or std.ascii.isDigit(c);
}
fn isName(s: []const u8) bool {
    if (s.len == 0 or !nameStart(s[0])) return false;
    for (s[1..]) |c| if (!nameChar(c)) {
        return false;
    };
    return true;
}
pub fn assignment(word: Word) ?usize {
    const i = std.mem.findScalar(u8, word, '=') orelse return null;
    return if (isName(word[0..i])) i else null;
}

const Kind = enum { word, io_number, newline, semi, dsemi, semi_and, amp, and_if, pipe, or_if, lparen, rparen, redir, eof };
const Token = struct { kind: Kind, text: Word = "", op: Redirection.Op = .input, ancestry: []const []const u8 = &.{}, force_alias: bool = false };
const Frame = struct { text: []const u8, pos: usize = 0, name: []const u8, trailing: bool };
const Pending = struct { delimiter: []const u8, doc: *HereDoc, strip: bool };

pub const Parser = struct {
    input: Input,
    aliases: *const alias.Table,
    persistent: Allocator,
    allocator: Allocator,
    byte: ?u8 = null,
    byte_valid: bool = false,
    eof: bool = false,
    line: usize = 1,
    column: usize = 1,
    diagnostic: struct { line: usize = 1, column: usize = 1 } = .{},
    token: ?Token = null,
    frames: std.ArrayList(Frame) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    alias_next: bool = false,
    boundary: bool = true,
    depth: usize = 0,

    pub fn init(allocator: Allocator, input: Input, aliases: *const alias.Table) Parser {
        return .{ .persistent = allocator, .allocator = allocator, .input = input, .aliases = aliases };
    }

    pub fn deinit(self: *Parser) void {
        self.clearFrames();
        self.frames.deinit(self.persistent);
    }

    fn clearFrames(self: *Parser) void {
        while (self.frames.pop()) |frame| {
            self.persistent.free(frame.text);
            self.persistent.free(frame.name);
        }
    }

    pub fn next(self: *Parser, allocator: Allocator) anyerror!?*const Node {
        self.allocator = allocator;
        self.pending = .empty;
        self.token = null;
        self.alias_next = false;
        self.depth = 0;
        self.boundary = false;
        const first = try self.peek();
        if (first.kind == .eof) {
            self.boundary = true;
            return null;
        }
        if (first.kind == .newline) {
            _ = self.take();
            self.boundary = true;
            return try self.make(.{ .sequence = &.{} });
        }
        var expanded = false;
        while (try self.expandAlias(true, &.{ "if", "while", "until", "for", "case", "{", "}", "then", "elif", "else", "fi", "do", "done", "esac", "!" })) expanded = true;
        if (expanded) {
            const t = try self.peek();
            if (t.kind == .newline or t.kind == .eof) {
                if (t.kind == .newline) _ = self.take();
                self.boundary = true;
                return try self.make(.{ .sequence = &.{} });
            }
        }
        self.boundary = false;
        const result = try self.list(&.{}, true);
        const end = try self.peek();
        if (end.kind == .newline) {
            _ = self.take();
            try self.readHereDocs();
            self.boundary = true;
        } else if (end.kind == .eof) {
            if (self.pending.items.len != 0) return self.fail(error.Incomplete);
            self.boundary = true;
        } else return self.fail(error.Syntax);
        return result;
    }

    /// Discard the remainder of a malformed physical line, but never the following line.
    pub fn recover(self: *Parser) void {
        self.clearFrames();
        self.pending = .empty;
        self.alias_next = false;
        if (self.token) |t| if (t.kind == .newline or t.kind == .eof) {
            self.boundary = true;
        };
        self.token = null;
        if (!self.boundary) {
            while (self.rawPeek() catch null) |c| {
                _ = self.rawTake() catch null;
                if (c == '\n') break;
            }
        }
        self.boundary = true;
    }

    /// SIGINT already discarded the pending terminal input. Do not read to drain it.
    pub fn interrupt(self: *Parser) void {
        self.clearFrames();
        self.pending = .empty;
        self.token = null;
        self.byte_valid = false;
        self.alias_next = false;
        self.boundary = true;
    }

    fn fail(self: *Parser, err: anyerror) anyerror {
        self.diagnostic = .{ .line = self.line, .column = self.column };
        return err;
    }
    fn enter(self: *Parser) !void {
        if (self.depth >= 128) return self.fail(error.DepthLimit);
        self.depth += 1;
    }
    fn rawPeek(self: *Parser) anyerror!?u8 {
        if (!self.byte_valid and !self.eof) {
            self.byte = try self.input.next(self.input.context);
            self.byte_valid = true;
            if (self.byte == null) self.eof = true;
        }
        return self.byte;
    }
    fn rawTake(self: *Parser) anyerror!?u8 {
        const c = try self.rawPeek();
        self.byte_valid = false;
        if (c) |ch| {
            if (ch == '\n') {
                self.line += 1;
                self.column = 1;
            } else self.column += 1;
        }
        return c;
    }
    fn charPeek(self: *Parser) anyerror!?u8 {
        while (self.frames.items.len != 0) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            if (frame.pos < frame.text.len) return frame.text[frame.pos];
            if (frame.trailing) self.alias_next = true;
            const ended = self.frames.pop().?;
            self.persistent.free(ended.text);
            self.persistent.free(ended.name);
        }
        return self.rawPeek();
    }
    fn charTake(self: *Parser) anyerror!?u8 {
        const c = try self.charPeek();
        if (self.frames.items.len != 0) self.frames.items[self.frames.items.len - 1].pos += 1 else _ = try self.rawTake();
        return c;
    }
    fn peek(self: *Parser) anyerror!Token {
        if (self.token == null) self.token = try self.lex();
        return self.token.?;
    }
    fn take(self: *Parser) Token {
        const t = self.token.?;
        self.token = null;
        return t;
    }
    fn make(self: *Parser, n: Node) !*const Node {
        const p = try self.allocator.create(Node);
        p.* = n;
        return p;
    }
    fn wordIs(t: Token, s: []const u8) bool {
        return t.kind == .word and std.mem.eql(u8, t.text, s);
    }
    fn stop(t: Token, stops: []const []const u8) bool {
        for (stops) |s| if (wordIs(t, s)) {
            return true;
        };
        return false;
    }
    fn expectKind(self: *Parser, kind: Kind) anyerror!Token {
        const t = try self.peek();
        if (t.kind != kind) return self.fail(if (t.kind == .eof) error.Incomplete else error.Syntax);
        return self.take();
    }
    fn expectWord(self: *Parser, s: []const u8) anyerror!void {
        const t = try self.peek();
        if (!wordIs(t, s)) return self.fail(if (t.kind == .eof) error.Incomplete else error.Syntax);
        _ = self.take();
    }
    fn linebreak(self: *Parser) anyerror!void {
        while ((try self.peek()).kind == .newline) {
            _ = self.take();
            try self.readHereDocs();
        }
    }

    fn lex(self: *Parser) anyerror!Token {
        while (true) if (try self.lexOne()) |token| return token;
    }

    fn lexOne(self: *Parser) anyerror!?Token {
        while (true) {
            const c = (try self.charPeek()) orelse return .{ .kind = .eof };
            if (c == ' ' or c == '\t') {
                _ = try self.charTake();
                continue;
            }
            if (c == '#') {
                while (try self.charPeek()) |ch| {
                    if (ch == '\n') break;
                    _ = try self.charTake();
                }
                continue;
            }
            break;
        }
        const c = (try self.charPeek()).?;
        switch (c) {
            '\n' => {
                _ = try self.charTake();
                return .{ .kind = .newline };
            },
            ';', '&', '|', '(', ')', '<', '>' => {
                const frame_depth = self.frames.items.len;
                _ = try self.charTake();
                if (c == '(') return .{ .kind = .lparen };
                if (c == ')') return .{ .kind = .rparen };
                // Do not fetch a byte past a newline to decide an operator.
                const frame_ended = frame_depth != 0 and self.frames.items[frame_depth - 1].pos == self.frames.items[frame_depth - 1].text.len;
                const n = if (frame_ended) null else try self.charPeek();
                if (c == ';') {
                    if (n == ';') {
                        _ = try self.charTake();
                        return .{ .kind = .dsemi };
                    }
                    if (n == '&') {
                        _ = try self.charTake();
                        return .{ .kind = .semi_and };
                    }
                    return .{ .kind = .semi };
                }
                if (c == '&') {
                    if (n == '&') {
                        _ = try self.charTake();
                        return .{ .kind = .and_if };
                    }
                    return .{ .kind = .amp };
                }
                if (c == '|') {
                    if (n == '|') {
                        _ = try self.charTake();
                        return .{ .kind = .or_if };
                    }
                    return .{ .kind = .pipe };
                }
                var op: Redirection.Op = if (c == '<') .input else .output;
                if (c == '<' and n == '<') {
                    _ = try self.charTake();
                    op = .here;
                    if ((frame_depth == 0 or self.frames.items[frame_depth - 1].pos < self.frames.items[frame_depth - 1].text.len) and try self.charPeek() == '-') {
                        _ = try self.charTake();
                        op = .here_strip;
                    }
                } else if (c == '>' and n == '>') {
                    _ = try self.charTake();
                    op = .append;
                } else if (c == '<' and n == '>') {
                    _ = try self.charTake();
                    op = .read_write;
                } else if (c == '>' and n == '|') {
                    _ = try self.charTake();
                    op = .clobber;
                } else if (n == '&') {
                    _ = try self.charTake();
                    op = if (c == '<') .dup_input else .dup_output;
                }
                return .{ .kind = .redir, .op = op };
            },
            else => {},
        }
        const force = self.alias_next;
        self.alias_next = false;
        var ancestry: std.ArrayList([]const u8) = .empty;
        for (self.frames.items) |f| try ancestry.append(self.allocator, try self.allocator.dupe(u8, f.name));
        const frame_depth = self.frames.items.len;
        var bytes: std.ArrayList(u8) = .empty;
        while (true) {
            // An alias replacement boundary delimits a token even without a blank.
            if (frame_depth != 0 and (self.frames.items.len < frame_depth or self.frames.items[frame_depth - 1].pos == self.frames.items[frame_depth - 1].text.len)) break;
            const ch = (try self.charPeek()) orelse break;
            if (ch == ' ' or ch == '\t' or ch == '\n' or std.mem.findScalar(u8, ";&|()<>", ch) != null) break;
            try self.wordPart(&bytes, 0, false);
        }
        if (bytes.items.len == 0) {
            self.alias_next = self.alias_next or force;
            return null;
        }
        const text = try bytes.toOwnedSlice(self.allocator);
        var digits = true;
        for (text) |ch| if (!std.ascii.isDigit(ch)) {
            digits = false;
            break;
        };
        const following = if (digits) try self.charPeek() else null;
        return .{ .kind = if (digits and (following == '<' or following == '>')) .io_number else .word, .text = text, .ancestry = try ancestry.toOwnedSlice(self.allocator), .force_alias = force };
    }

    fn wordPart(self: *Parser, out: *std.ArrayList(u8), depth: usize, in_double: bool) anyerror!void {
        if (depth >= 128) return self.fail(error.DepthLimit);
        const c = (try self.charTake()) orelse return self.fail(error.Incomplete);
        if (c == 0) return self.fail(error.Syntax);
        if (c == '`') return self.fail(error.Unsupported);
        if (c == '\\') {
            const n = (try self.charTake()) orelse return self.fail(error.Incomplete);
            if (n != '\n') {
                try out.append(self.allocator, c);
                try out.append(self.allocator, n);
            }
            return;
        }
        try out.append(self.allocator, c);
        if (c == '\'' or c == '"') {
            while (true) {
                const n = (try self.charPeek()) orelse return self.fail(error.Incomplete);
                if (n == c) {
                    _ = try self.charTake();
                    try out.append(self.allocator, n);
                    break;
                }
                if (c == '\'') {
                    _ = try self.charTake();
                    try out.append(self.allocator, n);
                } else if (n == '\'') {
                    _ = try self.charTake();
                    try out.append(self.allocator, n);
                } else try self.wordPart(out, depth + 1, true);
            }
        } else if (c == '$') {
            const n = try self.charPeek();
            if (n == '!' or (n == '\'' and !in_double)) return self.fail(error.Unsupported);
            if (n == '(' or n == '{') {
                _ = try self.charTake();
                try out.append(self.allocator, n.?);
                if (n == '(' and try self.charPeek() == '(') return self.fail(error.Unsupported);
                if (n == '(') {
                    try self.commandSubstitution(out, depth);
                    return;
                }
                const first = (try self.charPeek()) orelse return self.fail(error.Incomplete);
                if (std.ascii.isAlphanumeric(first) or std.mem.findScalar(u8, "_@*?#$-", first) != null) {
                    try out.append(self.allocator, (try self.charTake()).?);
                    if (std.ascii.isAlphanumeric(first) or first == '_') {
                        while (try self.charPeek()) |ch| {
                            if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
                            try out.append(self.allocator, (try self.charTake()).?);
                        }
                    }
                }
                const op = try self.charPeek();
                const inner_double = in_double and op != '#' and op != '%';
                while (true) {
                    const x = (try self.charPeek()) orelse return self.fail(error.Incomplete);
                    if (x == '}') {
                        _ = try self.charTake();
                        try out.append(self.allocator, x);
                        break;
                    }
                    if (inner_double and x == '\'') {
                        try out.append(self.allocator, (try self.charTake()).?);
                    } else try self.wordPart(out, depth + 1, inner_double);
                }
            }
        }
    }

    fn commandSubstitution(self: *Parser, out: *std.ArrayList(u8), depth: usize) anyerror!void {
        const Capture = struct {
            parser: *Parser,
            output: *std.ArrayList(u8),
            fn next(context: *anyopaque) anyerror!?u8 {
                const capture: *@This() = @ptrCast(@alignCast(context));
                const c = try capture.parser.charTake();
                if (c) |byte| try capture.output.append(capture.parser.allocator, byte);
                return c;
            }
        };
        var capture = Capture{ .parser = self, .output = out };
        var empty_aliases = alias.Table.init(self.persistent);
        defer empty_aliases.deinit();
        var sub = Parser.init(self.persistent, .{ .context = &capture, .next = Capture.next }, &empty_aliases);
        defer sub.deinit();
        sub.allocator = self.allocator;
        sub.depth = self.depth + depth + 1;
        sub.linebreak() catch |err| return self.fail(err);
        if ((try sub.peek()).kind != .rparen) _ = sub.list(&.{}, false) catch |err| return self.fail(err);
        _ = sub.expectKind(.rparen) catch |err| return self.fail(err);
    }

    fn expandAlias(self: *Parser, eligible: bool, reserved: []const []const u8) anyerror!bool {
        const t = try self.peek();
        if (t.kind != .word or (!eligible and !t.force_alias) or stop(t, reserved)) return false;
        for (t.text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!%,-@_", c) == null) {
            return false;
        };
        for (t.ancestry) |name| if (std.mem.eql(u8, name, t.text)) {
            return false;
        };
        const value = self.aliases.lookup(t.text) orelse return false;
        if (t.ancestry.len >= 128) return self.fail(error.DepthLimit);
        _ = self.take();
        // Preserve ancestry even when a replacement token ended at its frame boundary.
        for (t.ancestry) |name| {
            var present = false;
            for (self.frames.items) |frame| if (std.mem.eql(u8, frame.name, name)) {
                present = true;
                break;
            };
            if (!present) try self.pushFrame(name, "", false);
        }
        try self.pushFrame(t.text, value, trailingBlank(value));
        return true;
    }

    fn pushFrame(self: *Parser, name: []const u8, text: []const u8, trailing: bool) !void {
        const owned_name = try self.persistent.dupe(u8, name);
        errdefer self.persistent.free(owned_name);
        const owned_text = try self.persistent.dupe(u8, text);
        errdefer self.persistent.free(owned_text);
        try self.frames.append(self.persistent, .{ .name = owned_name, .text = owned_text, .trailing = trailing });
    }

    fn trailingBlank(text: []const u8) bool {
        var quote: u8 = 0;
        var escaped = false;
        var trailing = false;
        for (text) |c| {
            trailing = !escaped and quote == 0 and (c == ' ' or c == '\t');
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\' and quote != '\'') {
                escaped = true;
                continue;
            }
            if (quote == 0 and (c == '\'' or c == '"')) quote = c else if (quote == c) {
                quote = 0;
            }
        }
        return trailing;
    }

    fn list(self: *Parser, stops: []const []const u8, top: bool) anyerror!*const Node {
        try self.enter();
        defer self.depth -= 1;
        var nodes: std.ArrayList(*const Node) = .empty;
        try nodes.append(self.allocator, try self.andOr());
        while (true) {
            const t = try self.peek();
            if (t.kind == .amp) return self.fail(error.Unsupported);
            if (t.kind == .semi) {
                _ = self.take();
                if (!top) try self.linebreak();
            } else if (t.kind == .newline and !top) {
                try self.linebreak();
            } else break;
            const n = try self.peek();
            if (n.kind == .eof or n.kind == .newline or n.kind == .rparen or n.kind == .dsemi or n.kind == .semi_and or stop(n, stops)) break;
            try nodes.append(self.allocator, try self.andOr());
        }
        if (nodes.items.len == 1) return nodes.items[0];
        return self.make(.{ .sequence = try nodes.toOwnedSlice(self.allocator) });
    }
    fn andOr(self: *Parser) anyerror!*const Node {
        const first = try self.pipeline();
        var rest: std.ArrayList(AndOr.Part) = .empty;
        while (true) {
            const t = try self.peek();
            if (t.kind != .and_if and t.kind != .or_if) break;
            _ = self.take();
            try self.linebreak();
            try rest.append(self.allocator, .{ .op = if (t.kind == .and_if) .and_if else .or_if, .node = try self.pipeline() });
        }
        if (rest.items.len == 0) return first;
        return self.make(.{ .and_or = .{ .first = first, .rest = try rest.toOwnedSlice(self.allocator) } });
    }
    fn pipeline(self: *Parser) anyerror!*const Node {
        var negate = false;
        while (try self.expandAlias(true, &.{ "if", "while", "until", "for", "case", "{", "}", "then", "elif", "else", "fi", "do", "done", "esac", "!" })) {}
        if (wordIs(try self.peek(), "!")) {
            _ = self.take();
            negate = true;
        }
        var stages: std.ArrayList(*const Node) = .empty;
        try stages.append(self.allocator, try self.command());
        while ((try self.peek()).kind == .pipe) {
            _ = self.take();
            try self.linebreak();
            try stages.append(self.allocator, try self.command());
        }
        if (stages.items.len == 1 and !negate) return stages.items[0];
        return self.make(.{ .pipeline = .{ .stages = try stages.toOwnedSlice(self.allocator), .negate = negate } });
    }

    fn command(self: *Parser) anyerror!*const Node {
        try self.enter();
        defer self.depth -= 1;
        const reserved = &.{ "if", "while", "until", "for", "case", "{", "}", "then", "elif", "else", "fi", "do", "done", "esac", "!" };
        while (try self.expandAlias(true, reserved)) {}
        const t = try self.peek();
        var node: *const Node = undefined;
        if (t.kind == .lparen) {
            _ = self.take();
            try self.linebreak();
            const body = try self.list(&.{}, false);
            _ = try self.expectKind(.rparen);
            node = try self.make(.{ .subshell = body });
        } else if (wordIs(t, "{")) {
            _ = self.take();
            try self.linebreak();
            const body = try self.list(&.{"}"}, false);
            try self.expectWord("}");
            node = try self.make(.{ .group = body });
        } else if (wordIs(t, "if")) {
            _ = self.take();
            node = try self.parseIf();
        } else if (wordIs(t, "while") or wordIs(t, "until")) {
            _ = self.take();
            try self.linebreak();
            const cond = try self.list(&.{"do"}, false);
            try self.expectWord("do");
            try self.linebreak();
            const body = try self.list(&.{"done"}, false);
            try self.expectWord("done");
            node = try self.make(.{ .loop = .{ .condition = cond, .body = body, .until = wordIs(t, "until") } });
        } else if (wordIs(t, "for")) {
            _ = self.take();
            node = try self.parseFor();
        } else if (wordIs(t, "case")) {
            _ = self.take();
            node = try self.parseCase();
        } else {
            return self.simple();
        }
        var redirs: std.ArrayList(Redirection) = .empty;
        while (true) {
            const following = try self.peek();
            if (following.kind != .redir and following.kind != .io_number) break;
            try redirs.append(self.allocator, try self.redirection());
        }
        if (redirs.items.len != 0) node = try self.make(.{ .redirected = .{ .node = node, .redirs = try redirs.toOwnedSlice(self.allocator) } });
        return node;
    }

    fn simple(self: *Parser) anyerror!*const Node {
        var words: std.ArrayList(Word) = .empty;
        var redirs: std.ArrayList(Redirection) = .empty;
        var command_seen = false;
        while (true) {
            while (try self.expandAlias(!command_seen, if (command_seen) &.{} else &.{ "if", "while", "until", "for", "case", "{", "}", "then", "elif", "else", "fi", "do", "done", "esac", "!" })) {}
            const t = try self.peek();
            if (t.kind == .redir or t.kind == .io_number) {
                try redirs.append(self.allocator, try self.redirection());
                continue;
            }
            if (t.kind != .word) break;
            if (!command_seen and stop(t, &.{ "}", "then", "elif", "else", "fi", "do", "done", "esac" })) return self.fail(error.Syntax);
            _ = self.take();
            if (!command_seen and words.items.len == 0 and redirs.items.len == 0 and isName(t.text) and (try self.peek()).kind == .lparen) {
                _ = self.take();
                _ = try self.expectKind(.rparen);
                try self.linebreak();
                const body = try self.command();
                switch (body.*) {
                    .group, .subshell, .conditional, .loop, .for_loop, .case, .redirected => {},
                    else => return self.fail(error.Syntax),
                }
                return self.make(.{ .function = .{ .name = t.text, .body = body } });
            }
            try words.append(self.allocator, t.text);
            if (assignment(t.text) == null) command_seen = true;
        }
        if (words.items.len == 0 and redirs.items.len == 0) {
            return self.fail(if ((try self.peek()).kind == .eof) error.Incomplete else error.Syntax);
        }
        return self.make(.{ .simple = .{ .words = try words.toOwnedSlice(self.allocator), .redirs = try redirs.toOwnedSlice(self.allocator) } });
    }

    fn redirection(self: *Parser) anyerror!Redirection {
        var target: ?i32 = null;
        if ((try self.peek()).kind == .io_number) {
            const n = self.take();
            target = std.fmt.parseInt(i32, n.text, 10) catch return self.fail(error.Syntax);
        }
        const op = (try self.expectKind(.redir)).op;
        const word = (try self.expectKind(.word)).text;
        var doc: ?*HereDoc = null;
        if (op == .here or op == .here_strip) {
            var delimiter: std.ArrayList(u8) = .empty;
            var quoted = false;
            var quote: u8 = 0;
            var i: usize = 0;
            while (i < word.len) : (i += 1) {
                const c = word[i];
                if (quote == 0 and (c == '\'' or c == '"')) {
                    quote = c;
                    quoted = true;
                    continue;
                }
                if (quote == c) {
                    quote = 0;
                    continue;
                }
                if (c == '\\' and quote != '\'' and i + 1 < word.len and
                    (quote == 0 or std.mem.findScalar(u8, "$`\"\\", word[i + 1]) != null))
                {
                    quoted = true;
                    i += 1;
                    try delimiter.append(self.allocator, word[i]);
                    continue;
                }
                try delimiter.append(self.allocator, c);
            }
            const p = try self.allocator.create(HereDoc);
            p.* = .{ .body = "", .expand = !quoted };
            doc = p;
            try self.pending.append(self.allocator, .{ .delimiter = try delimiter.toOwnedSlice(self.allocator), .doc = p, .strip = op == .here_strip });
        }
        return .{ .target = target orelse switch (op) {
            .input, .read_write, .dup_input, .here, .here_strip => 0,
            else => 1,
        }, .op = op, .word = word, .here_doc = doc };
    }
    fn readHereDocs(self: *Parser) anyerror!void {
        for (self.pending.items) |p| {
            var body: std.ArrayList(u8) = .empty;
            while (true) {
                var line: std.ArrayList(u8) = .empty;
                var at_start = true;
                while (true) {
                    const c = (try self.charTake()) orelse return self.fail(error.Incomplete);
                    if (at_start and p.strip and c == '\t') continue;
                    at_start = false;
                    if (c == '\n') {
                        var slashes: usize = 0;
                        while (slashes < line.items.len and line.items[line.items.len - 1 - slashes] == '\\') : (slashes += 1) {}
                        if (p.doc.expand and slashes % 2 == 1) {
                            _ = line.pop();
                            at_start = true;
                            continue;
                        }
                        break;
                    }
                    try line.append(self.allocator, c);
                }
                if (std.mem.eql(u8, line.items, p.delimiter)) break;
                try body.appendSlice(self.allocator, line.items);
                try body.append(self.allocator, '\n');
            }
            p.doc.body = try body.toOwnedSlice(self.allocator);
        }
        self.pending = .empty;
    }

    fn parseIf(self: *Parser) anyerror!*const Node {
        var branches: std.ArrayList(Conditional.Branch) = .empty;
        while (true) {
            try self.linebreak();
            const cond = try self.list(&.{"then"}, false);
            try self.expectWord("then");
            try self.linebreak();
            const body = try self.list(&.{ "elif", "else", "fi" }, false);
            try branches.append(self.allocator, .{ .condition = cond, .body = body });
            if (!wordIs(try self.peek(), "elif")) break;
            _ = self.take();
        }
        var otherwise: ?*const Node = null;
        if (wordIs(try self.peek(), "else")) {
            _ = self.take();
            try self.linebreak();
            otherwise = try self.list(&.{"fi"}, false);
        }
        try self.expectWord("fi");
        return self.make(.{ .conditional = .{ .branches = try branches.toOwnedSlice(self.allocator), .otherwise = otherwise } });
    }
    fn parseFor(self: *Parser) anyerror!*const Node {
        const name = (try self.expectKind(.word)).text;
        if (!isName(name)) return self.fail(error.Syntax);
        var words: ?[]const Word = null;
        try self.linebreak();
        if (wordIs(try self.peek(), "in")) {
            _ = self.take();
            var items: std.ArrayList(Word) = .empty;
            while ((try self.peek()).kind == .word) try items.append(self.allocator, self.take().text);
            words = try items.toOwnedSlice(self.allocator);
        }
        const t = try self.peek();
        if (t.kind == .semi) {
            _ = self.take();
            try self.linebreak();
        } else if (t.kind == .newline) {
            try self.linebreak();
        } else if (words != null) return self.fail(if (t.kind == .eof) error.Incomplete else error.Syntax);
        try self.expectWord("do");
        try self.linebreak();
        const body = try self.list(&.{"done"}, false);
        try self.expectWord("done");
        return self.make(.{ .for_loop = .{ .name = name, .words = words, .body = body } });
    }
    fn parseCase(self: *Parser) anyerror!*const Node {
        const word = (try self.expectKind(.word)).text;
        try self.linebreak();
        try self.expectWord("in");
        try self.linebreak();
        var arms: std.ArrayList(Case.Arm) = .empty;
        while (!wordIs(try self.peek(), "esac")) {
            if ((try self.peek()).kind == .eof) return self.fail(error.Incomplete);
            if ((try self.peek()).kind == .lparen) _ = self.take();
            var patterns: std.ArrayList(Word) = .empty;
            try patterns.append(self.allocator, (try self.expectKind(.word)).text);
            while ((try self.peek()).kind == .pipe) {
                _ = self.take();
                try patterns.append(self.allocator, (try self.expectKind(.word)).text);
            }
            _ = try self.expectKind(.rparen);
            try self.linebreak();
            const t = try self.peek();
            const body = if (t.kind == .dsemi or t.kind == .semi_and or wordIs(t, "esac")) try self.make(.{ .simple = .{ .words = &.{}, .redirs = &.{} } }) else try self.list(&.{"esac"}, false);
            const end = try self.peek();
            const fallthrough = end.kind == .semi_and;
            if (end.kind == .dsemi or end.kind == .semi_and) {
                _ = self.take();
                try self.linebreak();
            } else if (!wordIs(end, "esac")) return self.fail(if (end.kind == .eof) error.Incomplete else error.Syntax);
            try arms.append(self.allocator, .{ .patterns = try patterns.toOwnedSlice(self.allocator), .body = body, .fallthrough = fallthrough });
        }
        _ = self.take();
        return self.make(.{ .case = .{ .word = word, .arms = try arms.toOwnedSlice(self.allocator) } });
    }
};

/// Return the number of bytes through the matching `)` after a `$(` prefix.
pub fn substitutionEnd(allocator: Allocator, text: []const u8) anyerror!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Source = struct {
        bytes: []const u8,
        pos: usize = 0,
        fn next(context: *anyopaque) anyerror!?u8 {
            const source: *@This() = @ptrCast(@alignCast(context));
            if (source.pos == source.bytes.len) return null;
            const c = source.bytes[source.pos];
            source.pos += 1;
            return c;
        }
    };
    var source = Source{ .bytes = text };
    var aliases = alias.Table.init(a);
    var parser = Parser.init(a, .{ .context = &source, .next = Source.next }, &aliases);
    defer parser.deinit();
    try parser.linebreak();
    if ((try parser.peek()).kind != .rparen) _ = try parser.list(&.{}, false);
    _ = try parser.expectKind(.rparen);
    return source.pos;
}

const TestInput = struct {
    text: []const u8,
    pos: usize = 0,
    fn next(ctx: *anyopaque) anyerror!?u8 {
        const self: *TestInput = @ptrCast(@alignCast(ctx));
        if (self.pos == self.text.len) return null;
        const c = self.text[self.pos];
        self.pos += 1;
        return c;
    }
    fn input(self: *TestInput) Input {
        return .{ .context = self, .next = next };
    }
};

test "sh: command boundaries and raw words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "# blank\necho 'a b' \"$x\" c\\\nd\nread data\n" };
    var p = Parser.init(a, source.input(), &aliases);
    const empty = (try p.next(a)).?;
    try std.testing.expectEqual(@as(usize, 0), empty.sequence.len);
    try std.testing.expectEqual(@as(usize, 8), source.pos);
    const cmd = (try p.next(a)).?;
    try std.testing.expectEqualStrings("'a b'", cmd.simple.words[1]);
    try std.testing.expectEqualStrings("\"$x\"", cmd.simple.words[2]);
    try std.testing.expectEqualStrings("cd", cmd.simple.words[3]);
    try std.testing.expectEqualStrings("read data\n", source.text[source.pos..]);
    try std.testing.expectEqual(@as(?usize, 3), assignment("abc=\"value\""));
    try std.testing.expectEqual(@as(?usize, null), assignment("'abc'=value"));
}

test "sh: here documents and no read ahead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "cat <<A 3<<-'B'\none\nA\n\t$x\n\tB\nnext\n" };
    var p = Parser.init(a, source.input(), &aliases);
    const n = (try p.next(a)).?;
    try std.testing.expectEqualStrings("one\n", n.simple.redirs[0].here_doc.?.body);
    try std.testing.expect(n.simple.redirs[0].here_doc.?.expand);
    try std.testing.expectEqual(@as(i32, 3), n.simple.redirs[1].target);
    try std.testing.expectEqualStrings("$x\n", n.simple.redirs[1].here_doc.?.body);
    try std.testing.expect(!n.simple.redirs[1].here_doc.?.expand);
    try std.testing.expectEqualStrings("next\n", source.text[source.pos..]);
}

test "sh: lists compound commands and functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "f() { if a && b; then for x in a b; do echo $x; done; else while c; do d; done; fi; } >out\ncase x in a|b) echo yes ;; c) echo no ;; esac\n" };
    var p = Parser.init(a, source.input(), &aliases);
    const n = (try p.next(a)).?;
    try std.testing.expectEqualStrings("f", n.function.name);
    try std.testing.expect(n.function.body.* == .redirected);
    const c = (try p.next(a)).?;
    try std.testing.expectEqual(@as(usize, 2), c.case.arms.len);
    try std.testing.expectEqual(@as(usize, 2), c.case.arms[0].patterns.len);
}

test "sh: aliases and replacement cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var out = std.Io.Writer.failing;
    var err = std.Io.Writer.failing;
    try std.testing.expectEqual(@as(u8, 0), alias.runBuiltin(&aliases, &.{ "lead=echo ", "word=expanded", "a=b", "b=a" }, &out, &err));
    var source = TestInput{ .text = "lead word\na\n" };
    var p = Parser.init(a, source.input(), &aliases);
    const n = (try p.next(a)).?;
    try std.testing.expectEqualStrings("echo", n.simple.words[0]);
    try std.testing.expectEqualStrings("expanded", n.simple.words[1]);
    const cycle = (try p.next(a)).?;
    try std.testing.expectEqualStrings("a", cycle.simple.words[0]);
}

test "sh: recovery keeps next physical line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "echo >\necho ok\n" };
    var p = Parser.init(a, source.input(), &aliases);
    try std.testing.expectError(error.Syntax, p.next(a));
    p.recover();
    try std.testing.expectEqualStrings("echo ok\n", source.text[source.pos..]);
    const n = (try p.next(a)).?;
    try std.testing.expectEqualStrings("ok", n.simple.words[1]);
}

test "sh: multiline aliases survive command arena disposal" {
    const a = std.testing.allocator;
    var aliases = alias.Table.init(a);
    defer aliases.deinit();
    var out = std.Io.Writer.failing;
    var err = std.Io.Writer.failing;
    try std.testing.expectEqual(@as(u8, 0), alias.runBuiltin(&aliases, &.{"multi=echo first\necho second\n"}, &out, &err));
    var source = TestInput{ .text = "multi\nnext\n" };
    var p = Parser.init(a, source.input(), &aliases);
    defer p.deinit();
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const n = (try p.next(arena.allocator())).?;
        try std.testing.expectEqualStrings("first", n.simple.words[1]);
    }
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const n = (try p.next(arena.allocator())).?;
        try std.testing.expectEqualStrings("second", n.simple.words[1]);
    }
    try std.testing.expectEqualStrings("next\n", source.text[source.pos..]);
}

test "sh: substitution follows shell grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "echo $(case x in x) echo ok;; esac) $(cat <<EOF\n)\nEOF\n)\nnext\n" };
    var p = Parser.init(a, source.input(), &aliases);
    defer p.deinit();
    const n = (try p.next(a)).?;
    try std.testing.expectEqualStrings("$(case x in x) echo ok;; esac)", n.simple.words[1]);
    try std.testing.expectEqualStrings("$(cat <<EOF\n)\nEOF\n)", n.simple.words[2]);
    try std.testing.expectEqualStrings("next\n", source.text[source.pos..]);
    const text = "case x in x) echo ok;; esac) trailing";
    const end = try substitutionEnd(a, text);
    try std.testing.expectEqualStrings(" trailing", text[end..]);
}

test "sh: quoting, continuation and unsupported syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var source = TestInput{ .text = "echo \"it's $x\" $(echo 'x y')\ncat <<EOF\na\\\nb\nEOF\necho $((1+2))\n" };
    var p = Parser.init(a, source.input(), &aliases);
    defer p.deinit();
    const first = (try p.next(a)).?;
    try std.testing.expectEqualStrings("\"it's $x\"", first.simple.words[1]);
    try std.testing.expectEqualStrings("$(echo 'x y')", first.simple.words[2]);
    const second = (try p.next(a)).?;
    try std.testing.expectEqualStrings("ab\n", second.simple.redirs[0].here_doc.?.body);
    try std.testing.expectError(error.Unsupported, p.next(a));
}

test "sh: aliases can introduce pipeline negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var out = std.Io.Writer.failing;
    var err = std.Io.Writer.failing;
    try std.testing.expectEqual(@as(u8, 0), alias.runBuiltin(&aliases, &.{"not=!"}, &out, &err));
    var source = TestInput{ .text = "not false\n" };
    var p = Parser.init(a, source.input(), &aliases);
    defer p.deinit();
    const n = (try p.next(a)).?;
    try std.testing.expect(n.pipeline.negate);
    try std.testing.expectEqualStrings("false", n.pipeline.stages[0].simple.words[0]);
}

test "sh: empty alias produces an empty command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aliases = alias.Table.init(a);
    var out = std.Io.Writer.failing;
    var err = std.Io.Writer.failing;
    try std.testing.expectEqual(@as(u8, 0), alias.runBuiltin(&aliases, &.{"empty="}, &out, &err));
    var source = TestInput{ .text = "empty\necho ok\n" };
    var p = Parser.init(a, source.input(), &aliases);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try p.next(a)).?.sequence.len);
    try std.testing.expectEqualStrings("echo ok\n", source.text[source.pos..]);
    try std.testing.expectEqualStrings("ok", (try p.next(a)).?.simple.words[1]);
}

test "sh: allocation failures release parser storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var aliases = alias.Table.init(allocator);
            defer aliases.deinit();
            var source = TestInput{ .text = "if echo $(echo ok); then cat <<EOF\nbody\nEOF\nfi\n" };
            var p = Parser.init(allocator, source.input(), &aliases);
            defer p.deinit();
            _ = try p.next(arena.allocator());
        }
    }.run, .{});
}
