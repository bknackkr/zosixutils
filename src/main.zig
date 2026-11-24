//! Run an applet as `zosixutils <applet>`, or invoke the binary by the applet's name.
//! If no applet matches, print usage and exit with status 1.

const std = @import("std");

pub const commands = struct {
	pub const at = @import("commands/at.zig");
	pub const atd = @import("commands/atd.zig");
	pub const awk = @import("commands/awk.zig");
	pub const basename = @import("commands/basename.zig");
	pub const batch = @import("commands/batch.zig");
	pub const cat = @import("commands/cat.zig");
	pub const chmod = @import("commands/chmod.zig");
	pub const chown = @import("commands/chown.zig");
	pub const cp = @import("commands/cp.zig");
	pub const csplit = @import("commands/csplit.zig");
	pub const cut = @import("commands/cut.zig");
	pub const dd = @import("commands/dd.zig");
	pub const df = @import("commands/df.zig");
	pub const dirname = @import("commands/dirname.zig");
	pub const du = @import("commands/du.zig");
	pub const echo = @import("commands/echo.zig");
	pub const @"false" = @import("commands/false.zig");
	pub const grep = @import("commands/grep.zig");
	pub const kill = @import("commands/kill.zig");
	pub const ln = @import("commands/ln.zig");
	pub const logname = @import("commands/logname.zig");
	pub const ls = @import("commands/ls.zig");
	pub const mkdir = @import("commands/mkdir.zig");
	pub const mv = @import("commands/mv.zig");
	pub const nice = @import("commands/nice.zig");
	pub const nohup = @import("commands/nohup.zig");
	pub const paste = @import("commands/paste.zig");
	pub const ps = @import("commands/ps.zig");
	pub const pwd = @import("commands/pwd.zig");
	pub const readlink = @import("commands/readlink.zig");
	pub const renice = @import("commands/renice.zig");
	pub const rm = @import("commands/rm.zig");
	pub const rmdir = @import("commands/rmdir.zig");
	pub const sed = @import("commands/sed.zig");
	pub const sh = @import("commands/sh.zig");
	pub const sleep = @import("commands/sleep.zig");
	pub const @"true" = @import("commands/true.zig");
	pub const uname = @import("commands/uname.zig");
};

pub const common = struct {
	pub const args = @import("common/args.zig");
	pub const error_mod = @import("common/error.zig");
	pub const io = @import("common/io.zig");
	pub const mode = @import("common/mode.zig");
	pub const priority = @import("common/priority.zig");
	pub const regex = @import("common/regex.zig");
	pub const statx = @import("common/statx.zig");
	pub const user = @import("common/user.zig");
};

pub const Applet = struct {
	name: []const u8,
	run: *const fn (allocator: std.mem.Allocator, args: []const [:0]const u8) u8,
	description: []const u8,
};

/// Built-in applets and their usage descriptions.
pub const applets = [_]Applet{
	.{
		.name = "at",
		.run = commands.at.run,
		.description = "execute commands at a later time",
	},
	.{
		.name = "atd",
		.run = commands.atd.run,
		.description = "run the same-user at and batch scheduler",
	},
	.{
		.name = "awk",
		.run = commands.awk.run,
		.description = "pattern scanning and processing language",
	},
	.{
		.name = "basename",
		.run = commands.basename.run,
		.description = "return non-directory portion of a pathname",
	},
	.{
		.name = "batch",
		.run = commands.batch.run,
		.description = "execute commands when system load permits",
	},
	.{
		.name = "cat",
		.run = commands.cat.run,
		.description = "concatenate and print files",
	},
	.{
		.name = "chmod",
		.run = commands.chmod.run,
		.description = "change file modes",
	},
	.{
		.name = "chown",
		.run = commands.chown.run,
		.description = "change file ownership",
	},
	.{
		.name = "cp",
		.run = commands.cp.run,
		.description = "copy files",
	},
	.{
		.name = "csplit",
		.run = commands.csplit.run,
		.description = "split files based on context",
	},
	.{
		.name = "cut",
		.run = commands.cut.run,
		.description = "cut out selected fields of each line of a file",
	},
	.{
		.name = "dd",
		.run = commands.dd.run,
		.description = "convert and copy a file",
	},
	.{
		.name = "df",
		.run = commands.df.run,
		.description = "report free file system space",
	},
	.{
		.name = "dirname",
		.run = commands.dirname.run,
		.description = "return directory portion of a pathname",
	},
	.{
		.name = "du",
		.run = commands.du.run,
		.description = "estimate allocated file space",
	},
	.{
		.name = "echo",
		.run = commands.echo.run,
		.description = "write arguments to standard output",
	},
	.{
		.name = "false",
		.run = commands.false.run,
		.description = "return false value",
	},
	.{
		.name = "grep",
		.run = commands.grep.run,
		.description = "search a file for a pattern",
	},
	.{
		.name = "kill",
		.run = commands.kill.run,
		.description = "terminate or signal processes",
	},
	.{
		.name = "ln",
		.run = commands.ln.run,
		.description = "link files",
	},
	.{
		.name = "logname",
		.run = commands.logname.run,
		.description = "return the user's login name",
	},
	.{
		.name = "ls",
		.run = commands.ls.run,
		.description = "list directory contents",
	},
	.{
		.name = "mkdir",
		.run = commands.mkdir.run,
		.description = "make directories",
	},
	.{
		.name = "mv",
		.run = commands.mv.run,
		.description = "move files",
	},
	.{
		.name = "nice",
		.run = commands.nice.run,
		.description = "invoke a utility with an altered nice value",
	},
	.{
		.name = "nohup",
		.run = commands.nohup.run,
		.description = "invoke a utility immune to hangups",
	},
	.{
		.name = "paste",
		.run = commands.paste.run,
		.description = "merge corresponding or subsequent lines of files",
	},
	.{
		.name = "ps",
		.run = commands.ps.run,
		.description = "report process status",
	},
	.{
		.name = "pwd",
		.run = commands.pwd.run,
		.description = "return working directory name",
	},
	.{
		.name = "readlink",
		.run = commands.readlink.run,
		.description = "display the contents of a symbolic link",
	},
	.{
		.name = "renice",
		.run = commands.renice.run,
		.description = "set nice values of running processes",
	},
	.{
		.name = "rm",
		.run = commands.rm.run,
		.description = "remove directory entries",
	},
	.{
		.name = "rmdir",
		.run = commands.rmdir.run,
		.description = "remove directories",
	},
	.{
		.name = "sed",
		.run = commands.sed.run,
		.description = "stream editor",
	},
	.{
		.name = "sh",
		.run = commands.sh.run,
		.description = "interpret a POSIX shell subset",
	},
	.{
		.name = "sleep",
		.run = commands.sleep.run,
		.description = "suspend execution for an interval",
	},
	.{
		.name = "true",
		.run = commands.true.run,
		.description = "return true value",
	},
	.{
		.name = "uname",
		.run = commands.uname.run,
		.description = "return system name",
	},
};

/// Locate an applet by exact name.
pub fn findApplet(name: []const u8) ?Applet {
	for (applets) |applet| {
		if (std.mem.eql(u8, applet.name, name)) {
			return applet;
		}
	}
	return null;
}

/// Strip directory prefixes (both '/' and '\') and optional '.exe' suffix.
pub fn getBaseName(path: []const u8) []const u8 {
	var last_sep: ?usize = null;
	for (path, 0..) |c, i| {
		if (c == '/' or c == '\\') {
			last_sep = i;
		}
	}
	const name = if (last_sep) |idx| path[idx + 1 ..] else path;
	if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) {
		return name[0 .. name.len - 4];
	}
	return name;
}

/// Print formatted usage and list of built-in applets.
pub fn printUsage(io: std.Io, is_error: bool) void {
	const file = if (is_error) std.Io.File.stderr() else std.Io.File.stdout();
	var buf: [1024]u8 = undefined;
	var fw = file.writerStreaming(io, &buf);
	const writer = &fw.interface;

	_ = writer.writeAll(
		\\zosixutils - POSIX multicall binary
		\\
		\\Usage: zosixutils <applet> [arguments...]
		\\   or: <applet> [arguments...] (when symlinked/hardlinked)
		\\
		\\Currently defined applets:
		\\
	) catch {};

	for (applets, 0..) |applet, idx| {
		if (idx > 0) {
			_ = writer.writeAll(", ") catch {};
		} else {
			_ = writer.writeAll("    ") catch {};
		}
		_ = writer.writeAll(applet.name) catch {};
	}
	_ = writer.writeAll("\n\n") catch {};
	_ = fw.flush() catch {};
}

/// Print unknown applet error message followed by usage.
pub fn printUnknownApplet(io: std.Io, applet_name: []const u8) void {
	const stderr = std.Io.File.stderr();
	var buf: [256]u8 = undefined;
	var fw = stderr.writerStreaming(io, &buf);
	const writer = &fw.interface;

	_ = writer.print("zosixutils: unknown applet '{s}'\n\n", .{applet_name}) catch {};
	_ = fw.flush() catch {};
	printUsage(io, true);
}

pub fn main(init: std.process.Init.Minimal) u8 {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	const allocator = arena.allocator();
	const all_args = init.args.toSlice(allocator) catch |err| {
		@import("common/error.zig").report("zosixutils", null, err);
		return 1;
	};

	const invocation_name = if (all_args.len != 0) getBaseName(all_args[0]) else "zosixutils";
	const multicall = std.mem.eql(u8, invocation_name, "zosixutils");
	const applet_name = if (!multicall) invocation_name else if (all_args.len >= 2) all_args[1] else null;
	const applet = if (applet_name) |name| findApplet(name) else null;
	const operands = all_args[@min(all_args.len, @as(usize, if (multicall) 2 else 1))..];
	const gpa = std.heap.smp_allocator;
	if (applet) |entry| {
		// These applets run before Threaded changes inherited signal dispositions.
		const envp = init.environ.block.slice.ptr;
		if (entry.run == &commands.sh.run) {
			if (multicall and operands.len != 0 and std.mem.eql(u8, operands[0], "--zosix-at-source"))
				return commands.sh.launchScheduled(gpa, operands[1..], envp);
			return commands.sh.launch(gpa, if (multicall) "sh" else all_args[0], operands, envp);
		}
		if (entry.run == &commands.nohup.run) return commands.nohup.launch(gpa, operands, envp);
		if (entry.run == &commands.at.run) return commands.at.launch(gpa, operands, envp);
		if (entry.run == &commands.batch.run) return commands.batch.launch(gpa, operands, envp);
		if (entry.run == &commands.atd.run) return commands.atd.launch(gpa, operands, envp);
	}

	var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(init.args), .environ = init.environ });
	defer threaded.deinit();
	const io = threaded.io();
	if (applet_name) |name| {
		if (multicall and (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h"))) {
			printUsage(io, false);
			return 0;
		}
		if (applet) |entry| return entry.run(allocator, operands);
		printUnknownApplet(io, name);
	} else {
		printUsage(io, true);
	}
	return 1;
}

// ============================================================================
// Multicall Router Tests
// ============================================================================

test "getBaseName extraction" {
	try std.testing.expectEqualStrings("echo", getBaseName("echo"));
	try std.testing.expectEqualStrings("echo", getBaseName("/bin/echo"));
	try std.testing.expectEqualStrings("echo", getBaseName("/usr/bin/echo"));
	try std.testing.expectEqualStrings("zosixutils", getBaseName("C:\\bin\\zosixutils.exe"));
	try std.testing.expectEqualStrings("zosixutils", getBaseName("zosixutils.EXE"));
	try std.testing.expectEqualStrings("false", getBaseName("false.exe"));
}

test "findApplet lookup" {
	try std.testing.expect(findApplet("at") != null);
	try std.testing.expect(findApplet("atd") != null);
	try std.testing.expect(findApplet("awk") != null);
	try std.testing.expect(findApplet("basename") != null);
	try std.testing.expect(findApplet("batch") != null);
	try std.testing.expect(findApplet("cat") != null);
	try std.testing.expect(findApplet("chmod") != null);
	try std.testing.expect(findApplet("chown") != null);
	try std.testing.expect(findApplet("cp") != null);
	try std.testing.expect(findApplet("csplit") != null);
	try std.testing.expect(findApplet("cut") != null);
	try std.testing.expect(findApplet("dd") != null);
	try std.testing.expect(findApplet("df") != null);
	try std.testing.expect(findApplet("dirname") != null);
	try std.testing.expect(findApplet("du") != null);
	try std.testing.expect(findApplet("echo") != null);
	try std.testing.expect(findApplet("false") != null);
	try std.testing.expect(findApplet("grep") != null);
	try std.testing.expect(findApplet("kill") != null);
	try std.testing.expect(findApplet("ln") != null);
	try std.testing.expect(findApplet("logname") != null);
	try std.testing.expect(findApplet("ls") != null);
	try std.testing.expect(findApplet("mkdir") != null);
	try std.testing.expect(findApplet("mv") != null);
	try std.testing.expect(findApplet("nice") != null);
	try std.testing.expect(findApplet("nohup") != null);
	try std.testing.expect(findApplet("paste") != null);
	try std.testing.expect(findApplet("ps") != null);
	try std.testing.expect(findApplet("pwd") != null);
	try std.testing.expect(findApplet("readlink") != null);
	try std.testing.expect(findApplet("renice") != null);
	try std.testing.expect(findApplet("rm") != null);
	try std.testing.expect(findApplet("rmdir") != null);
	try std.testing.expect(findApplet("sed") != null);
	try std.testing.expect(findApplet("sh") != null);
	try std.testing.expect(findApplet("sleep") != null);
	try std.testing.expect(findApplet("true") != null);
	try std.testing.expect(findApplet("uname") != null);
	try std.testing.expect(findApplet("alias") == null);
	try std.testing.expect(findApplet("wait") == null);
	try std.testing.expect(findApplet("nonexistent") == null);
}

test {
	_ = @import("commands/alias.zig");
	_ = @import("commands/wait.zig");
	_ = @import("common/at_spool.zig");
	_ = @import("common/at_time.zig");
	_ = @import("common/at_mail.zig");
	_ = @import("shell/builtins.zig");
	_ = @import("shell/expand.zig");
	_ = @import("shell/process.zig");
	_ = @import("shell/redirection.zig");
	_ = @import("shell/runtime.zig");
	_ = @import("shell/syntax.zig");
	std.testing.refAllDecls(common);
	std.testing.refAllDecls(commands);
}
