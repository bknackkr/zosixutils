//! Report space usage for mounted filesystems or the filesystems containing named paths.
//!
//! - `-k`: Use 1024-byte blocks instead of 512-byte blocks.
//! - `-P`: Request the portable output format, which is already the default.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

const Mount = struct {
	id: u64,
	point: []u8,
	source: []u8,
};

const Counters = struct {
	blocks: u64,
	free: u64,
	available: i64,
	fragment_size: u64,
};

const DisplayCounters = struct {
	total: i128,
	used: i128,
	available: i128,
	capacity: ?i128,
};

const StatFsNative = extern struct {
	f_type: isize,
	f_bsize: isize,
	f_blocks: usize,
	f_bfree: usize,
	f_bavail: isize,
	f_files: isize,
	f_ffree: isize,
	f_fsid: [2]i32,
	f_namelen: isize,
	f_frsize: isize,
	f_flags: isize,
	f_spare: [4]isize,
};

// Linux statfs64 uses 32-bit words around 64-bit counters. Byte arrays
// preserve its four-byte alignment and 84-byte size on ARM EABI and i386.
const StatFs64 = extern struct {
	f_type: u32,
	f_bsize: u32,
	f_blocks: [8]u8,
	f_bfree: [8]u8,
	f_bavail: [8]u8,
	f_files: [8]u8,
	f_ffree: [8]u8,
	f_fsid: [2]u32,
	f_namelen: u32,
	f_frsize: u32,
	f_flags: u32,
	f_spare: [4]u32,
};

const supported = builtin.os.tag == .linux and switch (builtin.cpu.arch) {
	.x86_64, .aarch64 => @sizeOf(usize) == 8,
	.x86, .arm => true,
	else => false,
};

fn decodeMountField(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
	const decoded = try allocator.alloc(u8, field.len);
	errdefer allocator.free(decoded);
	var source_index: usize = 0;
	var dest_index: usize = 0;
	while (source_index < field.len) {
		if (field[source_index] != '\\') {
			decoded[dest_index] = field[source_index];
			source_index += 1;
			dest_index += 1;
			continue;
		}
		if (source_index + 3 >= field.len) return error.MalformedMountInfo;
		const escaped = field[source_index + 1 .. source_index + 4];
		decoded[dest_index] = if (std.mem.eql(u8, escaped, "040")) ' ' else if (std.mem.eql(u8, escaped, "011")) '\t' else if (std.mem.eql(u8, escaped, "012")) '\n' else if (std.mem.eql(u8, escaped, "134")) '\\' else return error.MalformedMountInfo;
		source_index += 4;
		dest_index += 1;
	}
	return try allocator.realloc(decoded, dest_index);
}

fn nextField(line: []const u8, cursor: *usize) ?[]const u8 {
	while (cursor.* < line.len and line[cursor.*] == ' ') cursor.* += 1;
	if (cursor.* == line.len) return null;
	const start = cursor.*;
	while (cursor.* < line.len and line[cursor.*] != ' ') cursor.* += 1;
	return line[start..cursor.*];
}

fn parseDecimal(comptime T: type, value: []const u8) !T {
	for (value) |c| if (!std.ascii.isDigit(c)) return error.MalformedMountInfo;
	return std.fmt.parseInt(T, value, 10) catch error.MalformedMountInfo;
}

fn parseDeviceField(field: []const u8) !void {
	const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.MalformedMountInfo;
	_ = try parseDecimal(u32, field[0..colon]);
	_ = try parseDecimal(u32, field[colon + 1 ..]);
}

fn parseMountLine(allocator: std.mem.Allocator, line: []const u8) !Mount {
	var cursor: usize = 0;
	const id_field = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	const id = try parseDecimal(u64, id_field);
	if (id == 0) return error.MalformedMountInfo;
	const parent_field = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	_ = try parseDecimal(u64, parent_field);
	try parseDeviceField(nextField(line, &cursor) orelse return error.MalformedMountInfo);
	_ = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	const point_field = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	_ = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	if (point_field[0] != '/') return error.MalformedMountInfo;

	var separator_found = false;
	while (nextField(line, &cursor)) |field| {
		if (std.mem.eql(u8, field, "-")) {
			separator_found = true;
			break;
		}
	}
	if (!separator_found) return error.MalformedMountInfo;
	_ = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	const source_field = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	_ = nextField(line, &cursor) orelse return error.MalformedMountInfo;
	if (nextField(line, &cursor) != null) return error.MalformedMountInfo;

	const point = try decodeMountField(allocator, point_field);
	errdefer allocator.free(point);
	const source = try decodeMountField(allocator, source_field);
	return .{ .id = id, .point = point, .source = source };
}

fn freeMounts(allocator: std.mem.Allocator, mounts: []Mount) void {
	for (mounts) |mount| {
		allocator.free(mount.point);
		allocator.free(mount.source);
	}
	allocator.free(mounts);
}

fn parseMountInfo(allocator: std.mem.Allocator, contents: []const u8) ![]Mount {
	var mounts: std.ArrayList(Mount) = .empty;
	errdefer {
		for (mounts.items) |mount| {
			allocator.free(mount.point);
			allocator.free(mount.source);
		}
		mounts.deinit(allocator);
	}

	var lines = std.mem.splitScalar(u8, contents, '\n');
	while (lines.next()) |line| {
		if (line.len == 0) continue;
		const mount = try parseMountLine(allocator, line);
		mounts.append(allocator, mount) catch |err| {
			allocator.free(mount.point);
			allocator.free(mount.source);
			return err;
		};
	}
	if (mounts.items.len == 0) return error.MalformedMountInfo;
	return mounts.toOwnedSlice(allocator);
}

fn ceilUnits(value: i128, unit: i128) i128 {
	return @divTrunc(value, unit) + @as(i128, @intFromBool(@rem(value, unit) > 0));
}

fn displayCounters(counters: Counters, kib: bool) !DisplayCounters {
	if (counters.free > counters.blocks or counters.fragment_size == 0) return error.InvalidCounters;
	const used: i128 = counters.blocks - counters.free;
	const unit: i128 = if (kib) 1024 else 512;
	const fragment_bytes = std.math.mul(i128, counters.fragment_size, used) catch return error.Overflow;
	const free_bytes = std.math.mul(i128, counters.fragment_size, counters.available) catch return error.Overflow;
	const total_bytes = std.math.mul(i128, counters.fragment_size, counters.blocks) catch return error.Overflow;
	const denominator = used + counters.available;
	const capacity: ?i128 = if (denominator <= 0) null else ceilUnits(used * 100, denominator);
	return .{
		.total = ceilUnits(total_bytes, unit),
		.used = ceilUnits(fragment_bytes, unit),
		.available = ceilUnits(free_bytes, unit),
		.capacity = capacity,
	};
}

fn mapErrno(err: linux.E) anyerror {
	return switch (err) {
		.NOENT => error.FileNotFound,
		.ACCES, .PERM => error.AccessDenied,
		.NOTDIR => error.NotDir,
		.LOOP => error.SymLinkLoop,
		.NAMETOOLONG => error.NameTooLong,
		.NOMEM, .MFILE, .NFILE => error.SystemResources,
		.STALE => error.StaleMount,
		.NOSYS => error.OperationUnsupported,
		else => error.Unexpected,
	};
}

fn openPath(path: [:0]const u8) !linux.fd_t {
	while (true) {
		const rc = linux.openat(linux.AT.FDCWD, path, .{ .PATH = true, .CLOEXEC = true }, 0);
		switch (linux.errno(rc)) {
			.SUCCESS => return @intCast(rc),
			.INTR => continue,
			else => |err| return mapErrno(err),
		}
	}
}

fn readMountId(allocator: std.mem.Allocator, io: std.Io, fd: linux.fd_t) !u64 {
	const path = try std.fmt.allocPrint(allocator, "/proc/self/fdinfo/{d}", .{fd});
	defer allocator.free(path);
	var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
	defer file.close(io);
	var file_buffer: [256]u8 = undefined;
	var reader = file.readerStreaming(io, &file_buffer);
	const contents = try reader.interface.allocRemaining(allocator, .unlimited);
	defer allocator.free(contents);
	var lines = std.mem.splitScalar(u8, contents, '\n');
	while (lines.next()) |line| {
		if (!std.mem.startsWith(u8, line, "mnt_id:")) continue;
		const value = std.mem.trim(u8, line[7..], " \t\r");
		const id = parseDecimal(u64, value) catch return error.MalformedFdInfo;
		if (id == 0) return error.MalformedFdInfo;
		return id;
	}
	return error.MissingMountId;
}

fn queryCounters(fd: linux.fd_t) !Counters {
	while (true) {
		if (@sizeOf(usize) == 8) {
			comptime std.debug.assert(@sizeOf(StatFsNative) == 120 and @offsetOf(StatFsNative, "f_frsize") == 72);
			var raw: StatFsNative = undefined;
			const rc = linux.syscall2(.fstatfs, @as(u32, @bitCast(fd)), @intFromPtr(&raw));
			switch (linux.errno(rc)) {
				.SUCCESS => return .{
					.blocks = raw.f_blocks,
					.free = raw.f_bfree,
					.available = raw.f_bavail,
					.fragment_size = std.math.cast(u64, if (raw.f_frsize != 0) raw.f_frsize else raw.f_bsize) orelse return error.InvalidCounters,
				},
				.INTR => continue,
				else => |err| return mapErrno(err),
			}
		} else {
			comptime std.debug.assert(@sizeOf(StatFs64) == 84 and @offsetOf(StatFs64, "f_frsize") == 60);
			var raw: StatFs64 = undefined;
			const rc = linux.syscall3(.fstatfs64, @as(u32, @bitCast(fd)), @sizeOf(StatFs64), @intFromPtr(&raw));
			const endian = builtin.cpu.arch.endian();
			switch (linux.errno(rc)) {
				.SUCCESS => return .{
					.blocks = std.mem.readInt(u64, &raw.f_blocks, endian),
					.free = std.mem.readInt(u64, &raw.f_bfree, endian),
					.available = std.mem.readInt(i64, &raw.f_bavail, endian),
					.fragment_size = if (raw.f_frsize != 0) raw.f_frsize else raw.f_bsize,
				},
				.INTR => continue,
				else => |err| return mapErrno(err),
			}
		}
	}
}

fn findMount(mounts: []const Mount, id: u64) ?usize {
	for (mounts, 0..) |mount, index| {
		if (mount.id == id) return index;
	}
	return null;
}

fn inaccessible(err: anyerror) bool {
	return switch (err) {
		error.FileNotFound, error.AccessDenied, error.NotDir, error.SymLinkLoop, error.NameTooLong, error.StaleMount => true,
		else => false,
	};
}

fn writeRow(writer: *std.Io.Writer, mount: Mount, counters: Counters, kib: bool) !void {
	if (std.mem.indexOfScalar(u8, mount.source, '\n') != null or std.mem.indexOfScalar(u8, mount.point, '\n') != null) return error.NewlineInName;
	const values = try displayCounters(counters, kib);
	try writer.print("{s} {d} {d} {d} ", .{ mount.source, values.total, values.used, values.available });
	if (values.capacity) |capacity| {
		try writer.print("{d}%", .{capacity});
	} else {
		try writer.writeAll("-");
	}
	try writer.print(" {s}\n", .{mount.point});
}

fn header(kib: bool) []const u8 {
	return if (kib) "Filesystem 1024-blocks Used Available Capacity Mounted on\n" else "Filesystem 512-blocks Used Available Capacity Mounted on\n";
}

fn printHeader(writer: *std.Io.Writer, kib: bool) !void {
	try writer.writeAll(header(kib));
}

fn diagnostic(context: ?[]const u8, err: anyerror) void {
	const name = if (context) |path| (if (std.mem.indexOfScalar(u8, path, '\n') == null) path else "mount pathname") else null;
	common_error.report("df", name, err);
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
	if (!supported) {
		diagnostic(null, error.OperationUnsupported);
		return common_error.EXIT_FAILURE;
	}
	const io = std.Io.Threaded.global_single_threaded.io();
	var parser = common_args.ArgParser.init(args);
	var kib = false;
	while (parser.next("kP")) |option| {
		switch (option) {
			'k' => kib = true,
			'P' => {},
			else => {
				diagnostic("invalid option", error.InvalidArgument);
				return common_error.EXIT_SYNTAX;
			},
		}
	}
	const operands = parser.remaining();

	var mountinfo = std.Io.Dir.openFileAbsolute(io, "/proc/self/mountinfo", .{}) catch |err| {
		diagnostic("/proc/self/mountinfo", err);
		return common_error.EXIT_FAILURE;
	};
	defer mountinfo.close(io);
	var input_buffer: [4096]u8 = undefined;
	var input_reader = mountinfo.readerStreaming(io, &input_buffer);
	const contents = input_reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
		diagnostic("/proc/self/mountinfo", err);
		return common_error.EXIT_FAILURE;
	};
	defer allocator.free(contents);
	const mounts = parseMountInfo(allocator, contents) catch |err| {
		diagnostic("/proc/self/mountinfo", err);
		return common_error.EXIT_FAILURE;
	};
	defer freeMounts(allocator, mounts);

	const stdout = std.Io.File.stdout();
	var output_buffer: [4096]u8 = undefined;
	var output = stdout.writerStreaming(io, &output_buffer);
	const writer = &output.interface;
	printHeader(writer, kib) catch |err| {
		diagnostic(null, err);
		return common_error.EXIT_FAILURE;
	};

	var selected = std.AutoHashMap(u64, void).init(allocator);
	defer selected.deinit();
	var status: u8 = common_error.EXIT_SUCCESS;

	if (operands.len == 0) {
		for (mounts) |mount| {
			if (selected.contains(mount.id)) continue;
			const path = allocator.dupeSentinel(u8, mount.point, 0) catch {
				diagnostic(mount.point, error.OutOfMemory);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			defer allocator.free(path);
			const fd = openPath(path) catch |err| {
				if (inaccessible(err)) continue;
				diagnostic(mount.point, err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			defer _ = linux.close(fd);
			const current_id = readMountId(allocator, io, fd) catch |err| {
				diagnostic("/proc/self/fdinfo", err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			if (current_id != mount.id) continue;
			const counters = queryCounters(fd) catch |err| {
				if (inaccessible(err)) continue;
				diagnostic(mount.point, err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			selected.put(mount.id, {}) catch {
				diagnostic(null, error.OutOfMemory);
				return common_error.EXIT_FAILURE;
			};
			writeRow(writer, mount, counters, kib) catch |err| {
				diagnostic(mount.point, err);
				if (err == error.WriteFailed) return common_error.EXIT_FAILURE;
				status = common_error.EXIT_FAILURE;
			};
		}
	} else {
		for (operands) |operand_z| {
			const operand: []const u8 = operand_z;
			const fd = openPath(operand_z) catch |err| {
				diagnostic(operand, err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			defer _ = linux.close(fd);
			const id = readMountId(allocator, io, fd) catch |err| {
				diagnostic(operand, err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			if (selected.contains(id)) continue;
			const mount_index = findMount(mounts, id) orelse {
				diagnostic(operand, error.MountIdNotInMountInfo);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			const counters = queryCounters(fd) catch |err| {
				diagnostic(operand, err);
				status = common_error.EXIT_FAILURE;
				continue;
			};
			selected.put(id, {}) catch {
				diagnostic(null, error.OutOfMemory);
				return common_error.EXIT_FAILURE;
			};
			writeRow(writer, mounts[mount_index], counters, kib) catch |err| {
				diagnostic(operand, err);
				if (err == error.WriteFailed) return common_error.EXIT_FAILURE;
				status = common_error.EXIT_FAILURE;
			};
		}
	}

	output.flush() catch |err| {
		diagnostic(null, err);
		return common_error.EXIT_FAILURE;
	};
	return status;
}

test "df: mountinfo optional fields and escapes" {
	const allocator = std.testing.allocator;
	const contents = "36 25 8:1 /root /mnt/a\\040b rw,nosuid shared:1 master:2 - ext4 /dev/disk\\134name rw\n";
	const mounts = try parseMountInfo(allocator, contents);
	defer freeMounts(allocator, mounts);
	try std.testing.expectEqual(@as(usize, 1), mounts.len);
	try std.testing.expectEqual(@as(u64, 36), mounts[0].id);
	try std.testing.expectEqualStrings("/mnt/a b", mounts[0].point);
	try std.testing.expectEqualStrings("/dev/disk\\name", mounts[0].source);
}

test "df: long mountinfo records" {
	const allocator = std.testing.allocator;
	const long_point = try allocator.alloc(u8, 12_000);
	defer allocator.free(long_point);
	@memset(long_point, 'x');
	const contents = try std.fmt.allocPrint(allocator, "1 1 0:1 / /{s} rw - tmpfs tmpfs rw\n", .{long_point});
	defer allocator.free(contents);
	const mounts = try parseMountInfo(allocator, contents);
	defer freeMounts(allocator, mounts);
	try std.testing.expectEqual(@as(usize, 1), mounts.len);
	try std.testing.expectEqual(@as(usize, 12_001), mounts[0].point.len);
}

test "df: malformed mountinfo is rejected" {
	try std.testing.expectError(error.MalformedMountInfo, parseMountLine(std.testing.allocator, "1 1 0:1 / /mnt rw shared:1 ext4 /dev/x rw"));
	try std.testing.expectError(error.MalformedMountInfo, parseMountLine(std.testing.allocator, "1 1 0:1 / /mnt\\777 rw - ext4 /dev/x rw"));
	try std.testing.expectError(error.MalformedMountInfo, parseMountLine(std.testing.allocator, "1_2 1 0:1 / /mnt rw - ext4 /dev/x rw"));
}

test "df: bind and stacked mounts keep separate mount IDs" {
	const allocator = std.testing.allocator;
	const mounts = try parseMountInfo(allocator, "10 1 8:1 / /mnt rw - ext4 /dev/x rw\n" ++
		"11 1 8:1 /dir /bind rw - ext4 /dev/x rw\n" ++
		"12 10 0:1 / /mnt rw - tmpfs tmpfs rw\n");
	defer freeMounts(allocator, mounts);
	try std.testing.expectEqual(@as(?usize, 0), findMount(mounts, 10));
	try std.testing.expectEqual(@as(?usize, 1), findMount(mounts, 11));
	try std.testing.expectEqual(@as(?usize, 2), findMount(mounts, 12));
	try std.testing.expectEqualStrings(mounts[0].point, mounts[2].point);
	try std.testing.expectEqualStrings(mounts[0].source, mounts[1].source);
}

test "df: block rounding and capacity" {
	const kib = try displayCounters(.{ .blocks = 100, .free = 40, .available = 30, .fragment_size = 4096 }, true);
	try std.testing.expectEqual(@as(i128, 400), kib.total);
	try std.testing.expectEqual(@as(i128, 240), kib.used);
	try std.testing.expectEqual(@as(i128, 120), kib.available);
	try std.testing.expectEqual(@as(?i128, 67), kib.capacity);

	const reserved = try displayCounters(.{ .blocks = 100, .free = 40, .available = -5, .fragment_size = 512 }, false);
	try std.testing.expectEqual(@as(i128, 100), reserved.total);
	try std.testing.expectEqual(@as(i128, 60), reserved.used);
	try std.testing.expectEqual(@as(i128, -5), reserved.available);
	try std.testing.expectEqual(@as(?i128, 110), reserved.capacity);

	const undefined_capacity = try displayCounters(.{ .blocks = 50, .free = 50, .available = 0, .fragment_size = 1024 }, false);
	try std.testing.expectEqual(@as(?i128, null), undefined_capacity.capacity);

	const large = try displayCounters(.{ .blocks = 4_000_000_000_000, .free = 1, .available = 1, .fragment_size = 4096 }, true);
	try std.testing.expectEqual(@as(i128, 16_000_000_000_000), large.total);
	try std.testing.expectEqual(@as(?i128, 100), large.capacity);

	try std.testing.expectError(error.Overflow, displayCounters(.{ .blocks = std.math.maxInt(u64), .free = 0, .available = 0, .fragment_size = std.math.maxInt(u64) }, false));
}

test "df: POSIX headers in both block modes" {
	try std.testing.expectEqualStrings("Filesystem 512-blocks Used Available Capacity Mounted on\n", header(false));
	try std.testing.expectEqualStrings("Filesystem 1024-blocks Used Available Capacity Mounted on\n", header(true));
}
