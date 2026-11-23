//! Copy data in blocks, optionally converting it. Options use `key=value` syntax.
//!
//! - `if=file`, `of=file`: Set the input and output files (default: standard input and output).
//! - `ibs=size`, `obs=size`: Set the input and output block sizes (default: 512 bytes).
//! - `bs=size`: Set both block sizes, overriding `ibs` and `obs`.
//! - `cbs=size`: Set the record size for `block` and `unblock` conversions.
//! - `skip=n`, `seek=n`: Skip input blocks or start writing at an output block offset.
//! - `count=n`: Copy at most this many input blocks.
//! - `iflags=fullblock`: Accumulate short reads into full input blocks.
//! - `conv=list`: Apply comma-separated conversions: `block`, `unblock`, `lcase`,
//!   `ucase`, `swab`, `noerror`, `notrunc`, or `sync`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common_error = @import("../common/error.zig");
const statx = @import("../common/statx.zig");

const Key = enum { @"if", of, ibs, obs, bs, cbs, skip, seek, count, conv, iflags };
const Conversion = enum { block, unblock, lcase, ucase, swab, noerror, notrunc, sync };

const Settings = struct {
	input: ?[:0]const u8 = null,
	output: ?[:0]const u8 = null,
	ibs: usize = 512,
	obs: usize = 512,
	cbs: u64 = 0,
	skip: u64 = 0,
	skip_offset: i64 = 0,
	seek_offset: ?i64 = null,
	count: ?u64 = null,
	conv: std.EnumSet(Conversion) = .{},
	fullblock: bool = false,
	direct: bool = false,

	fn parse(args: []const [:0]const u8) !Settings {
		var opts: Settings = .{};
		var seen: std.EnumSet(Key) = .{};
		var bs: ?usize = null;
		var seek_blocks: ?u64 = null;
		const operands = if (args.len != 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
		for (operands) |arg| {
			const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidArgument;
			const key = std.meta.stringToEnum(Key, arg[0..eq]) orelse return error.InvalidArgument;
			const value = arg[eq + 1 ..];
			if (value.len == 0 or (key != .conv and seen.contains(key))) return error.InvalidArgument;
			seen.insert(key);
			switch (key) {
				.@"if" => opts.input = value,
				.of => opts.output = value,
				.ibs => opts.ibs = try bufferSize(value),
				.obs => opts.obs = try bufferSize(value),
				.bs => bs = try bufferSize(value),
				.cbs => opts.cbs = try size(value),
				.skip => opts.skip = try decimal(value),
				.seek => seek_blocks = try decimal(value),
				.count => opts.count = try decimal(value),
				.iflags => {
					if (!std.mem.eql(u8, value, "fullblock")) return error.InvalidArgument;
					opts.fullblock = true;
				},
				.conv => {
					var conversions = std.mem.splitScalar(u8, value, ',');
					while (conversions.next()) |name| {
						opts.conv.insert(std.meta.stringToEnum(Conversion, name) orelse return error.InvalidArgument);
					}
				},
			}
		}
		if (opts.conv.contains(.block) and opts.conv.contains(.unblock)) return error.InvalidArgument;
		if (opts.conv.contains(.lcase) and opts.conv.contains(.ucase)) return error.InvalidArgument;
		if (opts.cbs == 0 and (opts.conv.contains(.block) or opts.conv.contains(.unblock))) return error.InvalidArgument;
		if (bs) |n| {
			opts.ibs = n;
			opts.obs = n;
			const direct_conversions = std.EnumSet(Conversion).initMany(&.{ .sync, .noerror, .notrunc });
			opts.direct = opts.conv.subsetOf(direct_conversions);
		}
		opts.skip_offset = try blockOffset(opts.skip, opts.ibs);
		if (seek_blocks) |n| opts.seek_offset = try blockOffset(n, opts.obs);
		return opts;
	}
};

fn decimal(text: []const u8) !u64 {
	if (text.len == 0) return error.InvalidArgument;
	var n: u64 = 0;
	for (text) |c| {
		if (!std.ascii.isDigit(c)) return error.InvalidArgument;
		n = try std.math.add(u64, try std.math.mul(u64, n, 10), c - '0');
	}
	return n;
}

fn size(text: []const u8) !u64 {
	var factors = std.mem.splitScalar(u8, text, 'x');
	var n: u64 = 1;
	while (factors.next()) |factor| {
		if (factor.len == 0) return error.InvalidArgument;
		const scale: u64 = switch (factor[factor.len - 1]) {
			'k' => 1024,
			'b' => 512,
			else => 1,
		};
		const value = try decimal(factor[0 .. factor.len - @intFromBool(scale != 1)]);
		if (value == 0) return error.InvalidArgument;
		n = try std.math.mul(u64, n, try std.math.mul(u64, value, scale));
	}
	return n;
}

fn bufferSize(text: []const u8) !usize {
	const n = try size(text);
	if (n > std.math.maxInt(isize)) return error.Overflow;
	return @intCast(n);
}

fn blockOffset(n: u64, block_size: usize) !i64 {
	return std.math.cast(i64, try std.math.mul(u64, n, block_size)) orelse error.Overflow;
}

const Counts = struct {
	in_full: u64 = 0,
	in_partial: u64 = 0,
	out_full: u64 = 0,
	out_partial: u64 = 0,
	truncated: u64 = 0,

	fn publish(counts: Counts) void {
		// The applet runs on one thread. SIGINT sees the previous complete
		// snapshot if it interrupts the update, even on a 32-bit target.
		const next = snapshot_index.load(.monotonic) ^ 1;
		snapshots[next] = counts;
		snapshot_index.store(next, .release);
	}

	fn print(counts: Counts) void {
		var buffer: [192]u8 = undefined;
		var writer = std.Io.Writer.fixed(&buffer);
		writer.print("{d}+{d} records in\n{d}+{d} records out\n", .{
			counts.in_full, counts.in_partial, counts.out_full, counts.out_partial,
		}) catch unreachable;
		if (counts.truncated != 0) {
			writer.print("{d} truncated {s}\n", .{ counts.truncated, if (counts.truncated == 1) "record" else "records" }) catch unreachable;
		}
		_ = writeAll(Fd{ .fd = linux.STDERR_FILENO }, writer.buffered());
	}
};

var snapshots: [2]Counts = .{ .{}, .{} };
var snapshot_index: std.atomic.Value(usize) = .init(0);

fn interrupt(_: linux.SIG) callconv(.c) void {
	snapshots[snapshot_index.load(.acquire)].print();
	const default: linux.Sigaction = .{ .handler = .{ .handler = null }, .mask = linux.sigemptyset(), .flags = 0 };
	if (linux.errno(linux.sigaction(.INT, &default, null)) != .SUCCESS or
		linux.errno(linux.tgkill(linux.getpid(), linux.gettid(), .INT)) != .SUCCESS)
		linux.exit_group(130);
	// SIGINT is blocked in its handler; the pending signal takes effect on return.
}

fn installInterruptHandler() !?linux.Sigaction {
	var previous: linux.Sigaction = undefined;
	if (linux.errno(linux.sigaction(.INT, null, &previous)) != .SUCCESS) return error.SigactionFailed;
	if (previous.handler.handler == linux.SIG.IGN) return null;
	const action: linux.Sigaction = .{ .handler = .{ .handler = interrupt }, .mask = linux.sigemptyset(), .flags = 0 };
	if (linux.errno(linux.sigaction(.INT, &action, null)) != .SUCCESS) return error.SigactionFailed;
	return previous;
}

fn syscallError(err: linux.E) anyerror {
	return switch (err) {
		.ACCES => error.AccessDenied,
		.PERM => error.PermissionDenied,
		.NOENT => error.FileNotFound,
		.ISDIR => error.IsDir,
		.NOTDIR => error.NotDir,
		.LOOP => error.SymLinkLoop,
		.NAMETOOLONG => error.NameTooLong,
		.NOMEM, .MFILE, .NFILE, .AGAIN => error.SystemResources,
		.BADF => error.BadFileDescriptor,
		.FBIG, .OVERFLOW => error.FileTooBig,
		.ROFS => error.ReadOnlyFileSystem,
		.NOSPC => error.NoSpaceLeft,
		.DQUOT => error.DiskQuota,
		.PIPE => error.BrokenPipe,
		.SPIPE => error.Unseekable,
		.INVAL => error.InvalidArgument,
		.IO => error.HardwareFailure,
		.NXIO, .NODEV => error.NoSuchDevice,
		else => error.UnexpectedIoError,
	};
}

const Fd = struct {
	fd: linux.fd_t,
	device: bool = false,

	fn read(self: Fd, bytes: []u8) !usize {
		while (true) {
			const rc = linux.read(self.fd, bytes.ptr, bytes.len);
			switch (linux.errno(rc)) {
				.SUCCESS => return rc,
				.INTR => continue,
				else => |e| return syscallError(e),
			}
		}
	}

	fn write(self: Fd, bytes: []const u8) !usize {
		while (true) {
			const rc = linux.write(self.fd, bytes.ptr, bytes.len);
			switch (linux.errno(rc)) {
				.SUCCESS => return rc,
				.INTR => continue,
				else => |e| return syscallError(e),
			}
		}
	}

	fn seek(self: Fd, offset: i64, whence: u32) !i64 {
		while (true) {
			var position: i64 = undefined;
			const rc = if (@bitSizeOf(usize) == 32)
				linux.llseek(self.fd, offset, &position, whence)
			else
				linux.lseek(self.fd, offset, whence);
			switch (linux.errno(if (@bitSizeOf(usize) == 32) @as(u32, @truncate(rc)) else rc)) {
				.SUCCESS => return if (@bitSizeOf(usize) == 32) position else @bitCast(rc),
				.INTR => continue,
				else => |e| return syscallError(e),
			}
		}
	}

	fn recover(self: Fd, remaining: usize, read_err: anyerror, repeated: bool) !void {
		// Errors such as EISDIR or EBADF are not tied to a record. In
		// particular, a directory can seek but can never be read this way.
		if (read_err != error.HardwareFailure) return error.InputDidNotAdvance;
		const before = self.seek(0, linux.SEEK.CUR) catch |err| {
			if (err != error.Unseekable) return err;
			// A sequential device may have consumed a bad record. Permit a
			// retry, but not an endless stream of errors with no verified progress.
			if (self.device and !repeated) return;
			return error.InputDidNotAdvance;
		};
		const after = try self.seek(@intCast(remaining), linux.SEEK.CUR);
		if (after <= before) return error.InputDidNotAdvance;
	}
};

fn open(path: [:0]const u8, options: linux.O) !Fd {
	var flags = options;
	flags.CLOEXEC = true;
	if (@hasField(linux.O, "LARGEFILE")) flags.LARGEFILE = true;
	while (true) {
		const rc = linux.openat(linux.AT.FDCWD, path, flags, 0o666);
		switch (linux.errno(rc)) {
			.SUCCESS => return .{ .fd = @intCast(rc) },
			.INTR => continue,
			else => |e| return syscallError(e),
		}
	}
}

fn openOutput(path: [:0]const u8, seek_offset: i64) !Fd {
	if (seek_offset > 0) {
		if (open(path, .{ .CREAT = true, .ACCMODE = .RDWR })) |file| {
			return file;
		} else |err| switch (err) {
			// Seekable files need not grant read access, and some devices are write-only.
			error.AccessDenied, error.PermissionDenied, error.InvalidArgument, error.NoSuchDevice => {},
			else => return err,
		}
	}
	return open(path, .{ .CREAT = true, .ACCMODE = .WRONLY });
}

const Transfer = struct { len: usize, failure: ?anyerror = null };
const InputRecord = struct { len: usize, failure: ?anyerror = null, eof: bool = false };

fn readRecord(input: anytype, buffer: []u8, fullblock: bool) InputRecord {
	var n: usize = 0;
	while (n < buffer.len) {
		const bytes = input.read(buffer[n..]) catch |err| return .{ .len = n, .failure = err };
		if (bytes == 0) return .{ .len = n, .eof = true };
		n += bytes;
		if (!fullblock) break;
	}
	return .{ .len = n };
}

fn writeAll(sink: anytype, bytes: []const u8) Transfer {
	var n: usize = 0;
	while (n < bytes.len) {
		const written = sink.write(bytes[n..]) catch |err| return .{ .len = n, .failure = err };
		if (written == 0) return .{ .len = n, .failure = error.ZeroLengthWrite };
		n += written;
	}
	return .{ .len = n };
}

fn positionOutput(file: Fd, opts: Settings, mode: u16, scratch: []u8) !void {
	if (opts.seek_offset) |offset| {
		if (file.seek(offset, linux.SEEK.SET)) |_| {} else |err| {
			if (err != error.Unseekable) return err;
			if (offset > 0) {
				const rc = linux.fcntl(file.fd, linux.F.GETFL, 0);
				const status = linux.errno(rc);
				if (status != .SUCCESS) return syscallError(status);
				const flags: linux.O = @bitCast(@as(u32, @truncate(rc)));
				// An O_RDWR FIFO keeps its own writer alive and cannot reach EOF.
				if (flags.ACCMODE != .RDWR or linux.S.ISFIFO(mode)) return error.OutputSeekRequiresReadableStream;
				var remaining: u64 = @intCast(offset);
				while (remaining != 0) {
					const n: usize = @intCast(@min(remaining, scratch.len));
					const got = try file.read(scratch[0..n]);
					if (got == 0) break;
					remaining -= got;
				}
				@memset(scratch, 0);
				while (remaining != 0) {
					const n: usize = @intCast(@min(remaining, scratch.len));
					if (writeAll(file, scratch[0..n]).failure) |write_err| return write_err;
					remaining -= n;
				}
			}
		}
	}
	if (opts.output != null and linux.S.ISREG(mode) and !opts.conv.contains(.notrunc)) {
		while (true) {
			switch (linux.errno(linux.ftruncate(file.fd, opts.seek_offset orelse 0))) {
				.SUCCESS => break,
				.INTR => continue,
				else => |e| return syscallError(e),
			}
		}
	}
}

const SkipResult = struct { damaged: bool = false, eof: bool = false };

fn skipInput(input: Fd, opts: Settings, buffer: []u8, counts: Counts) !SkipResult {
	if (opts.skip == 0) return .{};
	if (input.seek(opts.skip_offset, linux.SEEK.CUR)) |_| return .{} else |err| {
		if (err != error.Unseekable) return err;
	}
	var result: SkipResult = .{};
	var repeated = false;
	var left = opts.skip;
	while (left != 0) : (left -= 1) {
		const record = readRecord(input, buffer, opts.fullblock);
		if (record.failure) |err| {
			if (!opts.conv.contains(.noerror)) return err;
			common_error.report("dd", opts.input orelse "standard input", err);
			counts.print();
			try input.recover(buffer.len - record.len, err, repeated and record.len == 0);
			result.damaged = true;
			repeated = true;
		} else {
			if (record.eof) {
				result.eof = true;
				break;
			}
			repeated = false;
		}
	}
	return result;
}

const Output = struct {
	buffer: []u8,
	block_size: usize,
	counts: *Counts,
	used: usize = 0,

	fn block(self: *Output, sink: anytype, bytes: []const u8) !void {
		const done = writeAll(sink, bytes);
		if (done.len != 0) {
			if (done.len == self.block_size) self.counts.out_full +|= 1 else self.counts.out_partial +|= 1;
			self.counts.publish();
		}
		if (done.failure) |err| return err;
	}

	fn flush(self: *Output, sink: anytype) !void {
		if (self.used == 0) return;
		try self.block(sink, self.buffer[0..self.used]);
		self.used = 0;
	}

	fn append(self: *Output, sink: anytype, bytes: []const u8) !void {
		var remaining = bytes;
		while (remaining.len != 0) {
			const n = @min(self.buffer.len - self.used, remaining.len);
			@memcpy(self.buffer[self.used..][0..n], remaining[0..n]);
			self.used += n;
			remaining = remaining[n..];
			if (self.used == self.buffer.len) try self.flush(sink);
		}
	}

	fn spaces(self: *Output, sink: anytype, count: u64) !void {
		const pad: [256]u8 = @splat(' ');
		var left = count;
		while (left != 0) {
			const n: usize = @intCast(@min(left, pad.len));
			try self.append(sink, pad[0..n]);
			left -= n;
		}
	}
};

const Records = struct {
	column: u64 = 0,
	trailing_spaces: u64 = 0,
	overlong: bool = false,

	fn convert(self: *Records, opts: Settings, out: *Output, sink: anytype, bytes: []const u8) !void {
		if (opts.conv.contains(.block)) {
			for (bytes) |c| {
				if (c == '\n') {
					try out.spaces(sink, opts.cbs - self.column);
					self.column = 0;
					self.overlong = false;
				} else if (self.column < opts.cbs) {
					try out.append(sink, &.{c});
					self.column += 1;
				} else if (!self.overlong) {
					self.overlong = true;
					out.counts.truncated +|= 1;
					out.counts.publish();
				}
			}
		} else if (opts.conv.contains(.unblock)) {
			for (bytes) |c| {
				if (c == ' ') {
					self.trailing_spaces += 1;
				} else {
					try out.spaces(sink, self.trailing_spaces);
					self.trailing_spaces = 0;
					try out.append(sink, &.{c});
				}
				self.column += 1;
				if (self.column == opts.cbs) {
					try out.append(sink, "\n");
					self.column = 0;
					self.trailing_spaces = 0;
				}
			}
		} else {
			try out.append(sink, bytes);
		}
	}
};

// Returns whether any input error occurred. Output errors are propagated.
fn copy(opts: Settings, input: anytype, sink: anytype, buffer: []u8, out: *Output) !bool {
	var records: Records = .{};
	var damaged = false;
	var repeated = false;
	var eof = false;
	var left = opts.count;
	while (!eof and (left == null or left.? != 0)) {
		const record = readRecord(input, buffer, opts.fullblock);
		eof = record.eof;
		if (record.failure) |err| {
			if (!opts.conv.contains(.noerror)) {
				const flushed = out.flush(sink);
				common_error.report("dd", opts.input orelse "standard input", err);
				try flushed;
				return true;
			}
			damaged = true;
			common_error.report("dd", opts.input orelse "standard input", err);
			out.counts.print();
			input.recover(buffer.len - record.len, err, repeated and record.len == 0) catch |recover_err| {
				common_error.report("dd", opts.input orelse "standard input", recover_err);
				try out.flush(sink);
				return true;
			};
			repeated = true;
		} else {
			if (record.len == 0) break;
			repeated = false;
		}
		if (left) |*n| n.* -= 1;

		const sync = opts.conv.contains(.sync);
		if (record.len == buffer.len) {
			out.counts.in_full +|= 1;
		} else if (record.len != 0 or sync) {
			out.counts.in_partial +|= 1;
		}
		out.counts.publish();
		if (record.failure != null and !sync) continue;
		if (sync) {
			const fill: u8 = if (opts.conv.contains(.block) or opts.conv.contains(.unblock)) ' ' else 0;
			@memset(buffer[record.len..], fill);
		}
		const bytes = buffer[0..if (sync) buffer.len else record.len];
		if (opts.direct) {
			try out.block(sink, bytes);
			continue;
		}
		if (opts.conv.contains(.swab)) {
			var i: usize = 0;
			while (i + 1 < bytes.len) : (i += 2) std.mem.swap(u8, &bytes[i], &bytes[i + 1]);
		}
		if (opts.conv.contains(.lcase)) {
			for (bytes) |*c| c.* = std.ascii.toLower(c.*);
		} else if (opts.conv.contains(.ucase)) {
			for (bytes) |*c| c.* = std.ascii.toUpper(c.*);
		}
		try records.convert(opts, out, sink, bytes);
	}
	if (records.column != 0) {
		if (opts.conv.contains(.block)) {
			try out.spaces(sink, opts.cbs - records.column);
		} else if (opts.conv.contains(.unblock)) {
			try out.append(sink, "\n");
		}
	}
	try out.flush(sink);
	return damaged;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
	if (builtin.os.tag != .linux) return failure(null, error.OperationUnsupported);
	const opts = Settings.parse(args) catch |err| {
		common_error.report("dd", "operands", err);
		return common_error.EXIT_SYNTAX;
	};
	const read_buffer = allocator.alloc(u8, opts.ibs) catch |err| return failure("input buffer", err);
	defer allocator.free(read_buffer);
	const write_buffer = allocator.alloc(u8, if (opts.direct) 0 else opts.obs) catch |err| return failure("output buffer", err);
	defer allocator.free(write_buffer);

	var counts: Counts = .{};
	counts.publish();
	const previous = installInterruptHandler() catch |err| return failure("SIGINT", err);
	defer if (previous) |action| {
		_ = linux.sigaction(.INT, &action, null);
	};
	defer counts.print();

	const in_name = opts.input orelse "standard input";
	const out_name = opts.output orelse "standard output";
	var input = if (opts.input) |path| open(path, .{}) catch |err| return failure(in_name, err) else Fd{ .fd = linux.STDIN_FILENO };
	defer if (opts.input != null) {
		_ = linux.close(input.fd);
	};
	const in_stat = statx.lookup(input.fd, "", linux.AT.EMPTY_PATH, false) catch |err| return failure(in_name, err);
	input.device = linux.S.ISCHR(in_stat.mode) or linux.S.ISBLK(in_stat.mode);
	const output = if (opts.output) |path|
		openOutput(path, opts.seek_offset orelse 0) catch |err| return failure(out_name, err)
	else
		Fd{ .fd = linux.STDOUT_FILENO };
	const result = copyFiles(opts, input, in_stat, output, read_buffer, write_buffer, &counts);
	if (opts.output != null) {
		// On Linux the descriptor is closed even if close reports EINTR.
		const status = linux.errno(linux.close(output.fd));
		if (status != .SUCCESS) return failure(out_name, syscallError(status));
	}
	return result;
}

fn copyFiles(opts: Settings, input: Fd, in_stat: statx.Metadata, output: Fd, read_buffer: []u8, write_buffer: []u8, counts: *Counts) u8 {
	const in_name = opts.input orelse "standard input";
	const out_name = opts.output orelse "standard output";
	const out_stat = statx.lookup(output.fd, "", linux.AT.EMPTY_PATH, false) catch |err| return failure(out_name, err);
	if (linux.S.ISREG(in_stat.mode) and linux.S.ISREG(out_stat.mode) and std.meta.eql(in_stat.id, out_stat.id))
		return failure(out_name, error.SameInputAndOutputFile);
	positionOutput(output, opts, out_stat.mode, if (opts.direct) read_buffer else write_buffer) catch |err| return failure(out_name, err);
	const skipped = skipInput(input, opts, read_buffer, counts.*) catch |err| return failure(in_name, err);
	var out: Output = .{ .buffer = write_buffer, .block_size = opts.obs, .counts = counts };
	const damaged = if (skipped.eof) false else copy(opts, input, output, read_buffer, &out) catch |err| return failure(out_name, err);
	return if (damaged or skipped.damaged) common_error.EXIT_FAILURE else common_error.EXIT_SUCCESS;
}

fn failure(context: ?[]const u8, err: anyerror) u8 {
	common_error.report("dd", context, err);
	return common_error.EXIT_FAILURE;
}

test "dd: operand expressions, precedence, and invalid syntax" {
	const opts = try Settings.parse(&.{ "--", "if=-", "of=x=y", "bs=2x1kx3b", "ibs=4", "obs=5", "skip=2", "seek=1", "count=0", "conv=sync", "conv=noerror,notrunc", "iflags=fullblock" });
	try std.testing.expectEqualStrings("-", opts.input.?);
	try std.testing.expectEqualStrings("x=y", opts.output.?);
	try std.testing.expectEqual(@as(usize, 3 * 1024 * 1024), opts.ibs);
	try std.testing.expectEqual(opts.ibs, opts.obs);
	try std.testing.expectEqual(@as(i64, 2 * 3 * 1024 * 1024), opts.skip_offset);
	try std.testing.expectEqual(@as(i64, 3 * 1024 * 1024), opts.seek_offset.?);
	try std.testing.expectEqual(@as(u64, 0), opts.count.?);
	try std.testing.expect(opts.direct and opts.fullblock and opts.conv.contains(.sync));
	for ([_][]const [:0]const u8{
		&.{"bs=0"},                   &.{"ibs=1xx2"},                  &.{"cbs=k"},                    &.{"skip=1k"},        &.{"seek=+2"},                    &.{"count=-1"},
		&.{"bs=9223372036854775808"}, &.{"bs=18446744073709551615x2"}, &.{"seek=9223372036854775808"}, &.{ "bs=1", "bs=2" }, &.{"count=1_2"},                  &.{"iflag=fullblock"},
		&.{"iflags=noerror"},         &.{"conv=block"},                &.{"conv=ascii"},               &.{"conv=sync,"},     &.{ "conv=lcase", "conv=ucase" }, &.{ "cbs=1", "conv=block,unblock" },
		&.{"status=none"},            &.{ "--", "--" },
	}) |args| {
		if (Settings.parse(args)) |_| return error.ExpectedSyntaxError else |_| {}
	}
}

const TestInput = struct {
	const Step = union(enum) { data: []const u8, failure: anyerror };
	steps: []const Step,
	next: usize = 0,
	advanced: usize = 0,
	can_advance: bool = true,

	fn read(self: *TestInput, bytes: []u8) !usize {
		if (self.next == self.steps.len) return 0;
		const step = self.steps[self.next];
		self.next += 1;
		switch (step) {
			.data => |data| {
				try std.testing.expect(bytes.len >= data.len);
				@memcpy(bytes[0..data.len], data);
				return data.len;
			},
			.failure => |err| return err,
		}
	}

	fn recover(self: *TestInput, remaining: usize, _: anyerror, _: bool) !void {
		if (!self.can_advance) return error.InputDidNotAdvance;
		self.advanced += remaining;
	}
};

const TestSink = struct {
	bytes: [64]u8 = undefined,
	len: usize = 0,
	limit: usize = 64,
	chunk: usize = 2,

	fn write(self: *TestSink, bytes: []const u8) !usize {
		if (self.len == self.limit) return error.NoSpaceLeft;
		const n = @min(bytes.len, self.chunk, self.limit - self.len);
		@memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
		self.len += n;
		return n;
	}
};

fn testCopy(args: []const [:0]const u8, input: *TestInput, sink: *TestSink, counts: *Counts) !bool {
	const opts = try Settings.parse(args);
	var ib: [8]u8 = undefined;
	var ob: [8]u8 = undefined;
	var out: Output = .{ .buffer = ob[0..opts.obs], .block_size = opts.obs, .counts = counts };
	return copy(opts, input, sink, ib[0..opts.ibs], &out);
}

test "dd: short reads and writes, fullblock, and count" {
	for ([_]bool{ false, true }) |fullblock| {
		var input: TestInput = .{ .steps = &.{ .{ .data = "ab" }, .{ .data = "cd" }, .{ .data = "unread" } } };
		var sink: TestSink = .{};
		var counts: Counts = .{};
		const args: []const [:0]const u8 = if (fullblock) &.{ "bs=4", "count=1", "iflags=fullblock" } else &.{ "bs=4", "count=1" };
		try std.testing.expect(!try testCopy(args, &input, &sink, &counts));
		try std.testing.expectEqualStrings(if (fullblock) "abcd" else "ab", sink.bytes[0..sink.len]);
		try std.testing.expectEqual(@as(usize, if (fullblock) 2 else 1), input.next);
		try std.testing.expectEqual(if (fullblock) Counts{ .in_full = 1, .out_full = 1 } else Counts{ .in_partial = 1, .out_partial = 1 }, counts);
	}
	var input: TestInput = .{ .steps = &.{ .{ .data = "ab" }, .{ .data = "cd" } } };
	var sink: TestSink = .{};
	var counts: Counts = .{};
	try std.testing.expect(!try testCopy(&.{ "ibs=4", "obs=4" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("abcd", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(Counts{ .in_partial = 2, .out_full = 1 }, counts);

	input = .{ .steps = &.{ .{ .data = "ab" }, .{ .data = "" }, .{ .data = "late" } } };
	sink = .{};
	counts = .{};
	try std.testing.expect(!try testCopy(&.{ "bs=4", "iflags=fullblock" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("ab", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(@as(usize, 2), input.next);
}

test "dd: read error flush, noerror recovery, and partial write failure" {
	const steps: []const TestInput.Step = &.{ .{ .data = "ab" }, .{ .failure = error.HardwareFailure }, .{ .data = "cdef" } };
	var input: TestInput = .{ .steps = steps };
	var sink: TestSink = .{};
	var counts: Counts = .{};
	try std.testing.expect(try testCopy(&.{ "ibs=4", "obs=8" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("ab", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(@as(usize, 2), input.next);
	try std.testing.expectEqual(Counts{ .in_partial = 1, .out_partial = 1 }, counts);

	for ([_]bool{ false, true }) |sync| {
		input = .{ .steps = steps };
		sink = .{};
		counts = .{};
		const args: []const [:0]const u8 = if (sync) &.{ "bs=4", "iflags=fullblock", "conv=noerror,sync" } else &.{ "bs=4", "iflags=fullblock", "conv=noerror" };
		try std.testing.expect(try testCopy(args, &input, &sink, &counts));
		try std.testing.expectEqual(@as(usize, 2), input.advanced);
		try std.testing.expectEqualStrings(if (sync) "ab\x00\x00cdef" else "cdef", sink.bytes[0..sink.len]);
		try std.testing.expectEqual(Counts{ .in_full = 1, .in_partial = 1, .out_full = if (sync) 2 else 1 }, counts);
	}

	input = .{ .steps = steps, .can_advance = false };
	sink = .{};
	counts = .{};
	try std.testing.expect(try testCopy(&.{ "ibs=4", "obs=8", "conv=noerror" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("ab", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(@as(usize, 2), input.next);

	input = .{ .steps = &.{ .{ .data = "abcd" }, .{ .data = "efgh" } } };
	sink = .{ .limit = 3 };
	counts = .{};
	try std.testing.expectError(error.NoSpaceLeft, testCopy(&.{"bs=4"}, &input, &sink, &counts));
	try std.testing.expectEqualStrings("abc", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(Counts{ .in_full = 1, .out_partial = 1 }, counts);
	try std.testing.expectEqual(@as(usize, 1), input.next);
}

test "dd: a seekable directory read error cannot be recovered" {
	if (builtin.os.tag != .linux) return error.SkipZigTest;
	var tmp = std.testing.tmpDir(.{ .iterate = true });
	defer tmp.cleanup();
	const directory: Fd = .{ .fd = tmp.dir.handle };
	var buffer: [4]u8 = undefined;
	const record = readRecord(directory, &buffer, false);
	try std.testing.expectEqual(error.IsDir, record.failure.?);
	try std.testing.expectError(error.InputDidNotAdvance, directory.recover(buffer.len, record.failure.?, false));
}

test "dd: case, swab, sync, and streaming record conversions" {
	var input: TestInput = .{ .steps = &.{ .{ .data = "ABC" }, .{ .data = "dE" } } };
	var sink: TestSink = .{};
	var counts: Counts = .{};
	try std.testing.expect(!try testCopy(&.{ "bs=3", "conv=swab,lcase" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("baced", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(Counts{ .in_full = 1, .in_partial = 1, .out_full = 1, .out_partial = 1 }, counts);

	input = .{ .steps = &.{ .{ .data = "a\nb" }, .{ .data = "cde" }, .{ .data = "f\nx" }, .{ .data = "y" } } };
	sink = .{};
	counts = .{};
	try std.testing.expect(!try testCopy(&.{ "ibs=3", "obs=5", "cbs=4", "conv=block,ucase" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("A   BCDEXY  ", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(Counts{ .in_full = 3, .in_partial = 1, .out_full = 2, .out_partial = 1, .truncated = 1 }, counts);

	input = .{ .steps = &.{ .{ .data = " A " }, .{ .data = " B " }, .{ .data = "  C" } } };
	sink = .{};
	counts = .{};
	try std.testing.expect(!try testCopy(&.{ "ibs=3", "obs=5", "cbs=4", "conv=unblock" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings(" A\nB\nC\n", sink.bytes[0..sink.len]);

	input = .{ .steps = &.{.{ .data = "a" }} };
	sink = .{};
	counts = .{};
	try std.testing.expect(!try testCopy(&.{ "bs=4", "cbs=4", "conv=unblock,sync" }, &input, &sink, &counts));
	try std.testing.expectEqualStrings("a\n", sink.bytes[0..sink.len]);
	try std.testing.expectEqual(Counts{ .in_partial = 1, .out_partial = 1 }, counts);
}

test "dd: binary copy, syntax and aliases preserve destination, skip and notrunc" {
	if (builtin.os.tag != .linux) return error.SkipZigTest;
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
	defer allocator.free(path);
	const in_arg = try std.fmt.allocPrintSentinel(allocator, "if={s}/in", .{path}, 0);
	defer allocator.free(in_arg);
	const out_arg = try std.fmt.allocPrintSentinel(allocator, "of={s}/out=file", .{path}, 0);
	defer allocator.free(out_arg);
	const payload = "a\x00\xffdef";
	try tmp.dir.writeFile(io, .{ .sub_path = "in", .data = payload });
	try tmp.dir.writeFile(io, .{ .sub_path = "out=file", .data = "original" });
	var bytes: [32]u8 = undefined;
	try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ in_arg, out_arg, "bs=2", "seek=9223372036854775807" }));
	try std.testing.expectEqualStrings("original", try tmp.dir.readFile(io, "out=file", &bytes));
	try tmp.dir.hardLink("in", tmp.dir, "hard", io, .{});
	try tmp.dir.symLink(io, "in", "symlink", .{});
	for ([_][]const u8{ "in", "hard", "symlink" }) |alias| {
		const alias_arg = try std.fmt.allocPrintSentinel(allocator, "of={s}/{s}", .{ path, alias }, 0);
		defer allocator.free(alias_arg);
		try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{ in_arg, alias_arg }));
		try std.testing.expectEqualStrings(payload, try tmp.dir.readFile(io, "in", &bytes));
	}
	try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ in_arg, out_arg, "bs=4" }));
	try std.testing.expectEqualStrings(payload, try tmp.dir.readFile(io, "out=file", &bytes));
	try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ in_arg, out_arg, "bs=2", "skip=2", "seek=1", "count=1", "conv=notrunc" }));
	try std.testing.expectEqualStrings("a\x00efef", try tmp.dir.readFile(io, "out=file", &bytes));
	try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ in_arg, out_arg, "obs=2", "seek=1", "count=0" }));
	try std.testing.expectEqualStrings("a\x00", try tmp.dir.readFile(io, "out=file", &bytes));
}

test "dd: empty input still establishes a sparse output beyond 2 GiB" {
	if (builtin.os.tag != .linux) return error.SkipZigTest;
	const io = std.testing.io;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
	defer allocator.free(path);
	const in_arg = try std.fmt.allocPrintSentinel(allocator, "if={s}/empty", .{path}, 0);
	defer allocator.free(in_arg);
	const out_arg = try std.fmt.allocPrintSentinel(allocator, "of={s}/out", .{path}, 0);
	defer allocator.free(out_arg);
	try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
	try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = "prefix" });
	try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ in_arg, out_arg, "bs=1", "seek=2147483677" }));
	const output = try tmp.dir.openFile(io, "out", .{});
	defer output.close(io);
	try std.testing.expectEqual(@as(u64, 2147483677), (try output.stat(io)).size);
	var prefix: [6]u8 = undefined;
	try std.testing.expectEqual(@as(usize, 6), try output.readStreaming(io, &.{&prefix}));
	try std.testing.expectEqualStrings("prefix", &prefix);
}
