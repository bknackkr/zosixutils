//! Define and display aliases in the current shell. No options; accepts a leading `--`.

const std = @import("std");
const common_error = @import("../common/error.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Table = struct {
	const Entry = struct { name: []const u8, value: []const u8 };

	allocator: Allocator,
	entries: std.ArrayList(Entry) = .empty,

	pub fn init(allocator: Allocator) Table {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Table) void {
		self.clear();
		self.entries.deinit(self.allocator);
	}

	pub fn clear(self: *Table) void {
		for (self.entries.items) |entry| {
			self.allocator.free(entry.name);
			self.allocator.free(entry.value);
		}
		self.entries.clearRetainingCapacity();
	}

	pub fn remove(self: *Table, name: []const u8) bool {
		const i = self.findIndex(name) orelse return false;
		const entry = self.entries.orderedRemove(i);
		self.allocator.free(entry.name);
		self.allocator.free(entry.value);
		return true;
	}

	/// Make an independent copy for an in-process subshell.
	pub fn clone(self: *const Table, allocator: Allocator) Allocator.Error!Table {
		var copy = Table.init(allocator);
		errdefer copy.deinit();
		for (self.entries.items) |entry| try copy.append(entry.name, entry.value);
		return copy;
	}

	/// The returned value is borrowed until this name is redefined or removed.
	pub fn lookup(self: *const Table, name: []const u8) ?[]const u8 {
		const i = self.findIndex(name) orelse return null;
		return self.entries.items[i].value;
	}

	fn findIndex(self: *const Table, name: []const u8) ?usize {
		for (self.entries.items, 0..) |entry, i| {
			if (std.mem.eql(u8, entry.name, name)) return i;
		}
		return null;
	}

	fn set(self: *Table, name: []const u8, value: []const u8) Allocator.Error!void {
		const i = self.findIndex(name) orelse return self.append(name, value);
		const replacement = try self.allocator.dupe(u8, value);
		self.allocator.free(self.entries.items[i].value);
		self.entries.items[i].value = replacement;
	}

	fn append(self: *Table, name: []const u8, value: []const u8) Allocator.Error!void {
		const owned_name = try self.allocator.dupe(u8, name);
		errdefer self.allocator.free(owned_name);
		const owned_value = try self.allocator.dupe(u8, value);
		errdefer self.allocator.free(owned_value);
		try self.entries.append(self.allocator, .{ .name = owned_name, .value = owned_value });
	}
};

/// This entry point is intentionally not registered as a multicall applet.
pub fn run(_: Allocator, _: []const [:0]const u8) u8 {
	std.debug.print("alias: requires the current shell\n", .{});
	return common_error.EXIT_FAILURE;
}

pub fn runBuiltin(table: *Table, args: []const [:0]const u8, stdout: *Writer, stderr: *Writer) u8 {
	const status = processOperands(table, args, stdout, stderr) catch |err| switch (err) {
		error.OutOfMemory => blk: {
			diagnose(stderr, null, "out of memory");
			break :blk common_error.EXIT_FAILURE;
		},
		error.WriteFailed => {
			diagnose(stderr, null, "cannot write to standard output");
			return common_error.EXIT_FAILURE;
		},
	};
	stdout.flush() catch {
		diagnose(stderr, null, "cannot write to standard output");
		return common_error.EXIT_FAILURE;
	};
	return status;
}

fn processOperands(table: *Table, args: []const [:0]const u8, stdout: *Writer, stderr: *Writer) !u8 {
	const operands = if (args.len != 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
	if (operands.len == 0) {
		for (table.entries.items) |entry| try writeDefinition(stdout, entry.name, entry.value);
		return common_error.EXIT_SUCCESS;
	}

	var status: u8 = common_error.EXIT_SUCCESS;
	for (operands) |operand| {
		const equals = std.mem.findScalar(u8, operand, '=');
		const name = operand[0 .. equals orelse operand.len];
		if (!isName(name)) {
			diagnose(stderr, operand, "invalid alias name");
			status = common_error.EXIT_FAILURE;
		} else if (equals) |i| {
			try table.set(name, operand[i + 1 ..]);
		} else if (table.lookup(name)) |value| {
			try writeDefinition(stdout, name, value);
		} else {
			diagnose(stderr, name, "alias not found");
			status = common_error.EXIT_FAILURE;
		}
	}
	return status;
}

fn isName(name: []const u8) bool {
	if (name.len == 0) return false;
	for (name) |c| {
		if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!%,-@_", c) == null) return false;
	}
	return true;
}

fn writeDefinition(writer: *Writer, name: []const u8, value: []const u8) Writer.Error!void {
	try writer.print("{s}='", .{name});
	var start: usize = 0;
	for (value, 0..) |c, i| {
		if (c != '\'') continue;
		try writer.writeAll(value[start..i]);
		try writer.writeAll("'\\''");
		start = i + 1;
	}
	try writer.writeAll(value[start..]);
	try writer.writeAll("'\n");
}

fn diagnose(stderr: *Writer, operand: ?[]const u8, message: []const u8) void {
	if (operand) |arg| {
		stderr.print("alias: {s}: {s}\n", .{ arg, message }) catch return;
	} else {
		stderr.print("alias: {s}\n", .{message}) catch return;
	}
	stderr.flush() catch {};
}

test "alias: list and query in order, with silent definitions" {
	var table = Table.init(std.testing.allocator);
	defer table.deinit();
	var out_buf: [128]u8 = undefined;
	var out = Writer.fixed(&out_buf);
	var err = Writer.failing;

	try std.testing.expectEqual(0, runBuiltin(&table, &.{}, &out, &err));
	try std.testing.expectEqual(0, runBuiltin(&table, &.{ "b=old", "a=", "b=one=two" }, &out, &err));
	try std.testing.expectEqualStrings("", out.buffered());
	try std.testing.expectEqual(0, runBuiltin(&table, &.{}, &out, &err));
	try std.testing.expectEqualStrings("b='one=two'\na=''\n", out.buffered());

	out = Writer.fixed(&out_buf);
	try std.testing.expectEqual(0, runBuiltin(&table, &.{ "a", "b", "b=new", "b" }, &out, &err));
	try std.testing.expectEqualStrings("a=''\nb='one=two'\nb='new'\n", out.buffered());
}

test "alias: portable names, delimiter, and continued processing after errors" {
	var table = Table.init(std.testing.allocator);
	defer table.deinit();
	var out_buf: [128]u8 = undefined;
	var err_buf: [192]u8 = undefined;
	var out = Writer.fixed(&out_buf);
	var err = Writer.fixed(&err_buf);

	const args = &.{ "--", "-0=x", "--=y", "=empty", "bad/name=x", "missing", "1!%,-@_=ok", "1!%,-@_", "-0", "--" };
	try std.testing.expectEqual(1, runBuiltin(&table, args, &out, &err));
	try std.testing.expectEqualStrings("1!%,-@_='ok'\n-0='x'\n--='y'\n", out.buffered());
	try std.testing.expectEqualStrings(
		"alias: =empty: invalid alias name\nalias: bad/name=x: invalid alias name\nalias: missing: alias not found\n",
		err.buffered(),
	);
}

test "alias: quote only the value and preserve its bytes" {
	var table = Table.init(std.testing.allocator);
	defer table.deinit();
	var out_buf: [128]u8 = undefined;
	var out = Writer.fixed(&out_buf);
	var err = Writer.failing;

	const value = "'a' \\${x};\t\n\xff ";
	try std.testing.expectEqual(0, runBuiltin(&table, &.{ "quote=" ++ value, "quote" }, &out, &err));
	try std.testing.expectEqualStrings(value, table.lookup("quote").?);
	try std.testing.expectEqualStrings("quote=''\\''a'\\'' \\${x};\t\n\xff '\n", out.buffered());
}

test "alias: owns its inputs and isolates subshell copies" {
	const allocator = std.testing.allocator;
	var parent = Table.init(allocator);
	defer parent.deinit();
	var definition = "say=old".*;
	var out = Writer.failing;
	var err = Writer.failing;

	try std.testing.expectEqual(0, runBuiltin(&parent, &.{&definition}, &out, &err));
	@memset(&definition, 'x');
	var child = try parent.clone(allocator);
	defer child.deinit();
	try std.testing.expectEqualStrings("old", child.lookup("say").?);
	try std.testing.expectEqual(0, runBuiltin(&child, &.{ "say=new", "added=yes" }, &out, &err));
	try std.testing.expectEqualStrings("new", child.lookup("say").?);
	try std.testing.expectEqualStrings("old", parent.lookup("say").?);
	try std.testing.expect(parent.lookup("added") == null);
}

test "alias: insertion and cloning clean up after allocation failure" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
		fn insertAndClone(allocator: Allocator) !void {
			var parent = Table.init(allocator);
			defer parent.deinit();
			try parent.set("a", "first");
			try parent.set("b", "second");
			var child = try parent.clone(allocator);
			defer child.deinit();
		}
	}.insertAndClone, .{});
}

test "alias: failed replacement leaves the old value and stops the builtin" {
	var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
	var table = Table.init(allocator.allocator());
	defer table.deinit();
	try table.set("a", "old");
	allocator.fail_index = allocator.alloc_index;
	var out_buf: [64]u8 = undefined;
	var err_buf: [64]u8 = undefined;
	var out = Writer.fixed(&out_buf);
	var err = Writer.fixed(&err_buf);

	try std.testing.expectEqual(1, runBuiltin(&table, &.{ "a", "a=new", "a" }, &out, &err));
	try std.testing.expectEqualStrings("old", table.lookup("a").?);
	try std.testing.expectEqualStrings("a='old'\n", out.buffered());
	try std.testing.expectEqualStrings("alias: out of memory\n", err.buffered());
}

test "alias: write and flush failures return nonzero without undoing definitions" {
	var table = Table.init(std.testing.allocator);
	defer table.deinit();
	var err_buf: [64]u8 = undefined;
	var err = Writer.fixed(&err_buf);
	var out = Writer.failing;

	try std.testing.expectEqual(1, runBuiltin(&table, &.{ "a=kept", "a", "a=skipped" }, &out, &err));
	try std.testing.expectEqualStrings("kept", table.lookup("a").?);
	try std.testing.expectEqualStrings("alias: cannot write to standard output\n", err.buffered());

	var out_buf: [64]u8 = undefined;
	out = .{ .buffer = &out_buf, .vtable = &.{ .drain = Writer.failingDrain } };
	err = Writer.fixed(&err_buf);
	try std.testing.expectEqual(1, runBuiltin(&table, &.{"a"}, &out, &err));
	try std.testing.expectEqualStrings("a='kept'\n", out.buffered());
	try std.testing.expectEqualStrings("alias: cannot write to standard output\n", err.buffered());
}
