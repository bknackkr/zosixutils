const builtin = @import("builtin");
const linux = @import("std").os.linux;

pub const Device = struct { major: u32, minor: u32 };
pub const Identity = struct { dev: Device, ino: u64 };
pub const Metadata = struct { id: Identity, mode: u16, blocks: u64 };

pub fn lookup(dirfd: linux.fd_t, path: [*:0]const u8, flags: u32, comptime with_blocks: bool) !Metadata {
	if (builtin.os.tag != .linux) return error.OperationUnsupported;
	var stat: linux.Statx = undefined;
	const mask: linux.STATX = .{ .TYPE = true, .INO = true, .BLOCKS = with_blocks };
	while (true) {
		switch (linux.errno(linux.statx(dirfd, path, flags, mask, &stat))) {
			.SUCCESS => break,
			.INTR => continue,
			.NOSYS, .OPNOTSUPP => return error.StatxUnavailable,
			.NOENT => return error.FileNotFound,
			.ACCES => return error.AccessDenied,
			.PERM => return error.PermissionDenied,
			.NOTDIR => return error.NotDir,
			.LOOP => return error.SymLinkLoop,
			.NAMETOOLONG => return error.NameTooLong,
			.BADF => return error.BadFileDescriptor,
			.IO => return error.HardwareFailure,
			else => return error.StatxFailed,
		}
	}
	if (!stat.mask.TYPE or !stat.mask.INO or (with_blocks and !stat.mask.BLOCKS))
		return error.StatxMetadataUnavailable;
	// The containing device is returned unconditionally; there is no STATX bit for it.
	return .{
		.id = .{ .dev = .{ .major = stat.dev_major, .minor = stat.dev_minor }, .ino = stat.ino },
		.mode = stat.mode & linux.S.IFMT,
		.blocks = if (with_blocks) stat.blocks else 0,
	};
}
