//! POSIX.1-2024 `du`: report allocated storage for files and directory trees.

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const statx = @import("../common/statx.zig");
const linux = std.os.linux;

const FollowMode = enum {
	physical,
	operands,
	all,
};

const Options = struct {
	all: bool = false,
	summary: bool = false,
	kib: bool = false,
	one_file_system: bool = false,
	follow: FollowMode = .physical,
};

const Frame = struct {
	dir: std.Io.Dir,
	iterator: std.Io.Dir.Iterator,
	id: statx.Identity,
	subtotal: u64,
	restore_path_len: usize,
};

fn sameDevice(a: statx.Device, b: statx.Device) bool {
	return a.major == b.major and a.minor == b.minor;
}

fn displayBlocks(blocks: u64, kib: bool) u64 {
	if (!kib) return blocks;
	return blocks / 2 + blocks % 2;
}

fn parseOptions(args: []const [:0]const u8, options: *Options) ![]const [:0]const u8 {
	var parser = common_args.ArgParser.init(args);
	while (parser.next("askxHL")) |opt| {
		switch (opt) {
			'a' => options.all = true,
			's' => options.summary = true,
			'k' => options.kib = true,
			'x' => options.one_file_system = true,
			'H' => options.follow = .operands,
			'L' => options.follow = .all,
			else => return error.InvalidArgument,
		}
	}
	if (options.all and options.summary) return error.InvalidArgument;
	return parser.remaining();
}

fn reportFailure(path: []const u8, err: anyerror, failed: *bool) void {
	const context = if (std.mem.indexOfScalar(u8, path, '\n') == null) path else "pathname contains newline";
	common_error.report("du", context, err);
	failed.* = true;
}

fn recordIdentity(
	seen: *std.AutoHashMap(statx.Identity, void),
	id: statx.Identity,
) !bool {
	const result = try seen.getOrPut(id);
	if (result.found_existing) return false;
	result.value_ptr.* = {};
	return true;
}

fn appendChildPath(allocator: std.mem.Allocator, path: *std.ArrayList(u8), name: []const u8) !void {
	const current_len = path.items.len;
	if (current_len != 0 and path.items[current_len - 1] != '/') try path.append(allocator, '/');
	try path.appendSlice(allocator, name);
}

fn addToParent(parent: *Frame, amount: u64, path: []const u8, failed: *bool) void {
	parent.subtotal = std.math.add(u64, parent.subtotal, amount) catch {
		reportFailure(path, error.FileTooBig, failed);
		return;
	};
}

fn emitRow(writer: *std.Io.Writer, path: []const u8, blocks: u64, options: Options, failed: *bool) !void {
	if (std.mem.indexOfScalar(u8, path, '\n') != null) {
		reportFailure(path, error.NewlineInName, failed);
		return;
	}
	try writer.print("{d} {s}\n", .{ displayBlocks(blocks, options.kib), path });
}

fn openDirectoryAt(dirfd: linux.fd_t, path: [*:0]const u8, follow: bool) !std.Io.Dir {
	const flags: linux.O = .{
		.ACCMODE = .RDONLY,
		.DIRECTORY = true,
		.NOFOLLOW = !follow,
		.CLOEXEC = true,
	};
	while (true) {
		const rc = linux.openat(dirfd, path, flags, 0);
		const err = linux.errno(rc);
		if (err == .SUCCESS) return .{ .handle = @intCast(rc) };
		switch (err) {
			.INTR => continue,
			.NOENT => return error.FileNotFound,
			.ACCES => return error.AccessDenied,
			.PERM => return error.PermissionDenied,
			.NOTDIR => return error.NotDir,
			.LOOP => return error.SymLinkLoop,
			.NAMETOOLONG => return error.NameTooLong,
			.MFILE, .NFILE => return error.SystemResources,
			else => return error.Unexpected,
		}
	}
}

fn pushDirectory(
	io: std.Io,
	allocator: std.mem.Allocator,
	stack: *std.ArrayList(Frame),
	dirfd: linux.fd_t,
	name: [*:0]const u8,
	follow: bool,
	expected: statx.Identity,
	restore_path_len: usize,
) !void {
	const dir = try openDirectoryAt(dirfd, name, follow);
	errdefer dir.close(io);
	const opened = try statx.lookup(dir.handle, "", linux.AT.EMPTY_PATH, true);
	if (!std.meta.eql(expected, opened.id)) return error.DirectoryChangedDuringTraversal;
	try stack.append(allocator, .{
		.dir = dir,
		.iterator = dir.iterateAssumeFirstIteration(),
		.id = opened.id,
		.subtotal = opened.blocks,
		.restore_path_len = restore_path_len,
	});
}

fn scanRoot(
	io: std.Io,
	allocator: std.mem.Allocator,
	operand: [:0]const u8,
	options: Options,
	seen: *std.AutoHashMap(statx.Identity, void),
	writer: *std.Io.Writer,
) !bool {
	var failed = false;
	var path: std.ArrayList(u8) = .empty;
	defer path.deinit(allocator);
	try path.appendSlice(allocator, operand);

	const follow_operand = options.follow != .physical;
	const root_meta = statx.lookup(
		linux.AT.FDCWD,
		operand,
		if (follow_operand) 0 else linux.AT.SYMLINK_NOFOLLOW,
		true,
	) catch |err| {
		reportFailure(operand, err, &failed);
		return failed;
	};

	const root_device = root_meta.id.dev;
	if (!linux.S.ISDIR(root_meta.mode)) {
		const fresh = recordIdentity(seen, root_meta.id) catch {
			reportFailure(operand, error.SystemResources, &failed);
			return failed;
		};
		if (fresh) try emitRow(writer, path.items, root_meta.blocks, options, &failed);
		return failed;
	}

	const root_fresh = recordIdentity(seen, root_meta.id) catch {
		reportFailure(operand, error.SystemResources, &failed);
		return failed;
	};
	if (!root_fresh) return failed;

	var stack: std.ArrayList(Frame) = .empty;
	defer {
		for (stack.items) |frame| frame.dir.close(io);
		stack.deinit(allocator);
	}

	pushDirectory(io, allocator, &stack, linux.AT.FDCWD, operand, follow_operand, root_meta.id, 0) catch |err| {
		reportFailure(operand, err, &failed);
		try emitRow(writer, path.items, root_meta.blocks, options, &failed);
		return failed;
	};

	while (stack.items.len != 0) {
		const frame_index = stack.items.len - 1;
		const maybe_entry = stack.items[frame_index].iterator.next(io) catch |err| blk: {
			reportFailure(path.items, err, &failed);
			break :blk null;
		};
		const entry = maybe_entry orelse {
			const frame = stack.pop().?;
			frame.dir.close(io);
			if (!options.summary or stack.items.len == 0) try emitRow(writer, path.items, frame.subtotal, options, &failed);
			if (stack.items.len != 0) addToParent(&stack.items[stack.items.len - 1], frame.subtotal, path.items, &failed);
			path.items.len = frame.restore_path_len;
			continue;
		};
		if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

		const restore_len = path.items.len;
		appendChildPath(allocator, &path, entry.name) catch {
			reportFailure(entry.name, error.SystemResources, &failed);
			path.items.len = restore_len;
			continue;
		};
		var name_buffer: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
		if (entry.name.len >= name_buffer.len) {
			reportFailure(path.items, error.NameTooLong, &failed);
			path.items.len = restore_len;
			continue;
		}
		@memcpy(name_buffer[0..entry.name.len], entry.name);
		name_buffer[entry.name.len] = 0;
		const child_name = name_buffer[0..entry.name.len :0];

		const parent_dir = stack.items[frame_index].dir;
		const follow_child = options.follow == .all;
		const child_meta = statx.lookup(
			parent_dir.handle,
			child_name,
			if (follow_child) 0 else linux.AT.SYMLINK_NOFOLLOW,
			true,
		) catch |err| {
			reportFailure(path.items, err, &failed);
			path.items.len = restore_len;
			continue;
		};

		if (options.one_file_system and !sameDevice(child_meta.id.dev, root_device)) {
			path.items.len = restore_len;
			continue;
		}

		const child_is_dir = linux.S.ISDIR(child_meta.mode);
		if (child_is_dir) {
			var cycle = false;
			for (stack.items) |ancestor| {
				if (std.meta.eql(ancestor.id, child_meta.id)) {
					cycle = true;
					break;
				}
			}
			if (cycle) {
				reportFailure(path.items, error.SymLinkLoop, &failed);
				path.items.len = restore_len;
				continue;
			}
		}

		const fresh = recordIdentity(seen, child_meta.id) catch {
			reportFailure(path.items, error.SystemResources, &failed);
			path.items.len = restore_len;
			continue;
		};
		if (!fresh) {
			path.items.len = restore_len;
			continue;
		}
		if (!child_is_dir) {
			addToParent(&stack.items[frame_index], child_meta.blocks, path.items, &failed);
			if (options.all) try emitRow(writer, path.items, child_meta.blocks, options, &failed);
			path.items.len = restore_len;
			continue;
		}

		pushDirectory(io, allocator, &stack, parent_dir.handle, child_name, follow_child, child_meta.id, restore_len) catch |err| {
			reportFailure(path.items, err, &failed);
			if (!options.summary) try emitRow(writer, path.items, child_meta.blocks, options, &failed);
			addToParent(&stack.items[frame_index], child_meta.blocks, path.items, &failed);
			path.items.len = restore_len;
		};
	}

	return failed;
}

fn runLinux(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
	const io = std.Io.Threaded.global_single_threaded.io();
	var options: Options = .{};
	const operands = parseOptions(args, &options) catch {
		common_error.report("du", "invalid option", error.InvalidArgument);
		return common_error.EXIT_SYNTAX;
	};

	const stdout = std.Io.File.stdout();
	var stdout_buffer: [16 * 1024]u8 = undefined;
	var stdout_writer = stdout.writerStreaming(io, &stdout_buffer);
	const writer = &stdout_writer.interface;
	var seen = std.AutoHashMap(statx.Identity, void).init(allocator);
	defer seen.deinit();
	var failed = false;
	if (operands.len == 0) {
		failed = scanRoot(io, allocator, ".", options, &seen, writer) catch |err| blk: {
			common_error.report("du", null, err);
			break :blk true;
		};
	} else {
		for (operands) |operand| {
			const root_failed = scanRoot(io, allocator, operand, options, &seen, writer) catch |err| {
				common_error.report("du", operand, err);
				failed = true;
				if (err == error.WriteFailed) return common_error.EXIT_FAILURE;
				continue;
			};
			if (root_failed) failed = true;
		}
	}
	stdout_writer.flush() catch |err| {
		common_error.report("du", null, err);
		return common_error.EXIT_FAILURE;
	};
	return if (failed) common_error.EXIT_FAILURE else common_error.EXIT_SUCCESS;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
	if (comptime builtin.os.tag != .linux) {
		common_error.report("du", null, error.OperationUnsupported);
		return common_error.EXIT_FAILURE;
	} else {
		return runLinux(allocator, args);
	}
}

test "du: option parsing, terminator, and incompatible modes" {
	var options: Options = .{};
	const operands = try parseOptions(&.{ "-kHL", "--", "-tree" }, &options);
	try std.testing.expect(options.kib);
	try std.testing.expectEqual(FollowMode.all, options.follow);
	try std.testing.expectEqualStrings("-tree", operands[0]);
	options = .{};
	try std.testing.expectError(error.InvalidArgument, parseOptions(&.{"-as"}, &options));
	options = .{};
	try std.testing.expectError(error.InvalidArgument, parseOptions(&.{"-z"}, &options));
}

test "du: block rounding uses allocated 512-byte units" {
	try std.testing.expectEqual(@as(u64, 0), displayBlocks(0, true));
	try std.testing.expectEqual(@as(u64, 1), displayBlocks(1, true));
	try std.testing.expectEqual(@as(u64, 1), displayBlocks(2, true));
	try std.testing.expectEqual(@as(u64, 2), displayBlocks(3, true));
	try std.testing.expectEqual(std.math.maxInt(u64) / 2 + 1, displayBlocks(std.math.maxInt(u64), true));
}

test "du: newline paths are rejected instead of split into rows" {
	var output: [64]u8 = undefined;
	var writer = std.Io.Writer.fixed(&output);
	var failed = false;
	try emitRow(&writer, "bad\npath", 4, .{}, &failed);
	try std.testing.expect(failed);
	try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "du: post-order traversal and summary output" {
	if (builtin.os.tag != .linux) return error.SkipZigTest;
	const allocator = std.testing.allocator;
	const io = std.Io.Threaded.global_single_threaded.io();
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.createDir(io, "tree", .default_dir);
	try tmp.dir.writeFile(io, .{ .sub_path = "tree/item", .data = "payload" });
	try tmp.dir.hardLink("tree/item", tmp.dir, "tree/other", io, .{});
	try tmp.dir.symLink(io, ".", "tree/cycle", .{});

	const root_path = try tmp.dir.realPathFileAlloc(io, "tree", allocator);
	defer allocator.free(root_path);
	var seen = std.AutoHashMap(statx.Identity, void).init(allocator);
	defer seen.deinit();
	var output: [512]u8 = undefined;
	var writer = std.Io.Writer.fixed(&output);
	const failed = try scanRoot(io, allocator, root_path, .{ .all = true }, &seen, &writer);
	try std.testing.expect(!failed);
	const text = writer.buffered();
	try std.testing.expect((std.mem.indexOf(u8, text, "item\n") != null) != (std.mem.indexOf(u8, text, "other\n") != null));
	try std.testing.expect(std.mem.indexOf(u8, text, "cycle\n") != null);
	try std.testing.expectEqual(@as(u32, 3), seen.count());
	const root_row = std.mem.lastIndexOf(u8, text, root_path) orelse return error.TestUnexpectedResult;
	try std.testing.expectEqual(@as(u8, '\n'), text[root_row + root_path.len]);
	try std.testing.expectEqual(@as(usize, 0), text.len - root_row - root_path.len - 1);
	try std.testing.expect(!try scanRoot(io, allocator, root_path, .{}, &seen, &writer));
	try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, writer.buffered(), "\n"));

	seen.clearRetainingCapacity();
	var follow_output: [512]u8 = undefined;
	var follow_writer = std.Io.Writer.fixed(&follow_output);
	const follow_failed = try scanRoot(io, allocator, root_path, .{ .follow = .all }, &seen, &follow_writer);
	try std.testing.expect(follow_failed);

	seen.clearRetainingCapacity();
	var summary_output: [128]u8 = undefined;
	var summary_writer = std.Io.Writer.fixed(&summary_output);
	const summary_failed = try scanRoot(io, allocator, root_path, .{ .summary = true }, &seen, &summary_writer);
	try std.testing.expect(!summary_failed);
	try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, summary_writer.buffered(), "\n"));
}
