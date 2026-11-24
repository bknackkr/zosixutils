# ZOSIXutils Usage

Run an applet as `zosixutils <applet> [arguments...]`, or through a symlink or hard link named after the applet. For a local build, use `zig-out/bin/zosixutils` if the binary is not on `PATH`. Run `zosixutils --help` (or `zosixutils -h`) to list the available applets. These are options for the multicall launcher, not for every applet.

```sh
zosixutils echo 'hello'
zosixutils sh -c 'echo "$1"' example hello
```

This guide lists options implemented by ZOSIXutils. Do not assume every option from another implementation is available. In the command forms below, brackets mark optional arguments and `...` marks arguments that can repeat.

## sh

```text
zosixutils sh [-i] [-f | +f] [--] [script [argument ...]]
zosixutils sh [-i] [-f | +f] -c [--] command_string [command_name [argument ...]]
zosixutils sh [-i] [-f | +f] -s [--] [argument ...]
```

- With no script or command string, read commands from stdin. `-s` explicitly reads commands from stdin and makes the remaining arguments positional parameters. A script filename is opened directly, not searched for on `PATH`.
- `-c` runs a command string. The optional `command_name` sets `$0`, and subsequent arguments set `$1`, `$2`, and so on. For a script file, `$0` is the script operand.
- `-i` forces interactive mode. When reading commands from stdin, the shell also becomes interactive if both stdin and stderr are terminals. It prints `PS1` and `PS2` to stderr (default `$ ` and `> `) and recovers from Ctrl-C at the prompt or during a foreground pipeline.
- `-f` disables pathname expansion; `+f` enables it. `--` ends option parsing; a leading `-` in the option position is also consumed as an option terminator.

The shell supports foreground lists and pipelines, grouped commands and subshells, `if`, `case` (including `;&`), loops, and functions. It implements shell variables and positional parameters, quoting, parameter expansion, `$(...)`, field splitting, C-locale globbing, descriptor redirections, and here-documents.

Commands that are not builtins or functions are found through `PATH` and run externally. To use another ZOSIXutils applet from `sh`, invoke it as `zosixutils <applet>` or put a link named after that applet on `PATH`. Aliases are local to the shell and only affect commands parsed after their definition.

### Shell Builtins

These commands run inside `sh`; they are not standalone applets.

| Builtin | Usage |
| --- | --- |
| `:` | Do nothing and return success. |
| `. file [argument ...]` | Run a readable script in the current shell. Search `PATH` if `file` has no slash. |
| `alias [--] [name[=value] ...]` | Define or query aliases; with no operands, list them. |
| `break [n]`, `continue [n]` | Leave or continue the enclosing loop; `n` selects how many levels, defaulting to one. |
| `cd [-L] [-P] [directory]` | Change directory. `-L` uses the logical path (default); `-P` resolves symlinks. No operand uses `HOME`; `cd -` uses `OLDPWD`. |
| `command [-p] name [argument ...]` | Run a command without using a shell function. `-p` uses the default search path; `-v` or `-V` queries one or more names instead, with `-V` giving a description. |
| `exec [--] [command [argument ...]]` | Replace the shell with an external command. With no command, keep the redirections in the current shell. |
| `exit [status]`, `return [status]` | Exit the shell or return from a function or sourced script. The status defaults to that of the last command. |
| `export [name[=value] ...]`, `readonly [name[=value] ...]` | Mark variables for export or prevent reassignment, respectively. `-p` or no operands lists marked variables. |
| `read [-r] name ...` | Read a line from stdin and assign fields to variables. `-r` treats backslashes literally. |
| `set [-f] [+f] [--] [argument ...]` | With no operands, list shell variables. `-f` disables globbing, `+f` enables it, and `set --` replaces positional parameters with the remaining arguments (or clears them). |
| `shift [n]` | Drop the first `n` positional parameters (default one). |
| `unalias name ...` | Remove named aliases; `-a` removes all aliases instead. |
| `unset [-f] [-v] name ...` | Remove names. `-f` removes functions; `-v` removes variables (default). Do not combine them. |

### Shell Limits

This is not a fully conforming POSIX shell. Background lists, job control, `trap`, arithmetic expansion, backquotes, dollar-single-quoting, `ENV` startup processing, `~user`, locale-sensitive matching, and other unlisted shell options and builtins are not supported. With a multiline alias on shared stdin, the byte delimiting the original alias word may already be in parser lookahead when a child reads stdin. The shell uses the Linux `statx` and `memfd_create` system calls.

Run the focused and end-to-end tests after building:

```bash
zig test src/main.zig --test-filter 'sh:'
python3 tests/sh_integration.py zig-out/bin/zosixutils
```

## Other Applets

### awk
`awk [-F separator] [-v name=value] [-f program_file] [program] [file ...]` runs a pattern/action program over input records. `-F` sets the field separator, `-v` sets a variable before `BEGIN`, and `-f` loads program text from a file. Repeat `-v` to set more variables or `-f` to combine program files. Without `-f`, the first operand is the program. With no input files, or with `-` as a file, read stdin. The applet implements a subset of awk.

### basename
`basename path [suffix]` prints the last component of a pathname, removing a matching suffix if a nonempty name remains. No flags; `--` ends option parsing.

### cat
`cat [-u] [file ...]` concatenates files to stdout. `-u` writes without buffering. With no files, or with `-` as a file, read stdin.

### chmod
`chmod [-R] mode file ...` changes file permissions. The mode can be octal or symbolic. `-R` recurses through directories without following symlinks encountered during traversal.

### chown
`chown [-Rh] owner[:group] file ...` changes file ownership. Owner and group can be names or numeric IDs; `owner.group` is also accepted. An empty side, as in `:group`, is left unchanged. `-R` recurses through directories; `-h` changes the symlink itself rather than its target.

### cp
`cp [-fipRrHLP] source ... target` copies files or directory trees. With multiple sources, the target must be an existing directory.

- `-f` removes the destination and retries if it cannot be opened for writing; `-i` prompts before overwriting; `-p` attempts to preserve permissions and timestamps.
- `-R` or `-r` recurses through directories. `-H` follows source symlinks given as operands, `-L` follows all symlinks, and `-P` copies symlinks as links. The last of these three wins. The default is `-P` for recursive copies and `-L` otherwise.

### csplit
`csplit [-ks] [-f prefix] [-n digits] file pattern ...` splits a file into numbered pieces. `-k` keeps pieces created before an error; `-s` suppresses piece sizes; `-f` changes the output prefix (default `xx`); and `-n` changes the zero-padded number width (default `2`). Use `-` for stdin. Patterns include a line number, `/BRE/[offset]` to split at a match, `%BRE%[offset]` to skip a section, and `{n}` to repeat the preceding pattern `n` more times. A BRE is a basic regular expression.

### cut
`cut (-b list | -c list | -f list) [-d delimiter] [-sn] [file ...]` selects bytes (`-b`), UTF-8 character positions (`-c`), or fields (`-f`). Choose exactly one. Lists use one-based positions and ranges such as `1,3-5,8-`. In field mode, `-d` uses the first byte of `delimiter` instead of tab, and `-s` skips lines without a delimiter. In byte mode, `-n` avoids printing partial UTF-8 characters. With no files, or with `-` as a file, read stdin.

### dd
`dd [--] [key=value ...]` copies or converts data in blocks. It uses operands rather than short flags:

- `if=file` and `of=file` set input and output (default stdin and stdout).
- `ibs=size` and `obs=size` set input and output block sizes (default 512 bytes each); `bs=size` overrides both. `cbs=size` sets the record size for `block` and `unblock` conversions. Sizes can use `k` (multiply by 1024), `b` (multiply by 512), and `x` to multiply factors.
- `skip=n` skips input blocks, `seek=n` starts writing at an output block offset, and `count=n` limits input blocks copied. `iflags=fullblock` accumulates short reads into full input blocks.
- `conv=list` accepts `block`, `unblock`, `lcase`, `ucase`, `swab`, `noerror`, `notrunc`, and `sync`, separated by commas. `block` and `unblock` require `cbs` and cannot be combined; `lcase` and `ucase` also cannot be combined.

### df
`df [-kP] [file ...]` reports filesystem space for each named path, or mounted filesystems if no paths are given. `-k` uses 1024-byte blocks instead of 512-byte blocks. `-P` is accepted; portable output is already the default.

### dirname
`dirname path` prints the directory portion of a pathname. No flags; `--` ends option parsing.

### du
`du [-askxHL] [path ...]` reports allocated space, defaulting to `.`. `-a` includes individual files; `-s` reports only operand totals (do not combine them). `-k` uses 1024-byte blocks instead of 512-byte blocks; `-x` stays on the operand's filesystem. `-H` follows symlinks given as operands; `-L` follows all symlinks. If both are present, the last one wins.

### echo
`echo [argument ...]` prints arguments separated by spaces, followed by a newline. It takes no flags: `-n`, `-e`, and `--` print literally. Recognized escapes are `\a`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, `\\`, and `\0` followed by up to three octal digits. `\c` stops output without printing the newline.

### false
`false [argument ...]` always exits with status `1`. No flags; all arguments are ignored.

### grep
`grep [-EFcilnqsvx] [-e patterns] [-f pattern_file] [pattern] [file ...]` selects matching input lines. With no files, or with `-` as a file, read stdin.

- `-E` uses extended regular expressions and `-F` matches fixed strings; the default is basic regular expressions. `-i` ignores case, `-v` selects nonmatching lines, and `-x` requires a whole-line match.
- `-e` adds newline-separated patterns and `-f` reads patterns from a file. Both can be repeated; without either, the first operand is the pattern.
- `-n` prints line numbers and `-s` suppresses file diagnostics. `-c` counts selected lines, `-l` lists files with selected lines, and `-q` suppresses output and stops at the first selected line. The last of `-c`, `-l`, and `-q` wins.

### ln
`ln [-fsLP] source ... target` creates hard links by default. `-f` replaces an existing destination; `-s` creates symbolic links. For hard links, `-L` follows the source symlink and `-P` links the symlink itself (default); the last one wins. With multiple sources, the target must be an existing directory.

### logname
`logname` prints the session login name, not the value of the `LOGNAME` environment variable. No flags or operands; `--` is accepted.

### ls
`ls [options] [file ...]` lists files or directory contents, defaulting to `.`.

- **Entries:** `-a` includes hidden entries, `-A` includes hidden entries except `.` and `..`, `-d` lists directories themselves, and `-R` recurses. `-H` follows operand symlinks; `-L` follows all symlinks.
- **Layout:** `-1` selects one entry per line in non-long output, `-C` fills columns down, `-x` fills columns across, and `-m` separates names with commas. `-l` selects long format; `-n`, `-g`, and `-o` also select long format, with numeric IDs, no owner, or no group, respectively.
- **Details:** `-F` appends file-type indicators, `-p` appends `/` to directory names, `-q` replaces nonprinting characters with `?`, `-i` shows inodes, `-s` shows allocated blocks, and `-k` uses 1024-byte blocks.
- **Sorting:** `-t` sorts newest first, `-S` sorts largest first, `-r` reverses the sort order, and `-f` disables sorting and includes hidden entries. `-c` selects status-change time and `-u` selects access time for time sorting and long-format timestamps.

### mkdir
`mkdir [-p] [-m mode] directory ...` creates directories. `-p` creates missing parents and accepts existing directories; `-m` sets permissions using an octal or symbolic mode.

### mv
`mv [-fi] source ... target` renames or moves files and directories. With multiple sources, the target must be an existing directory. `-f` disables overwrite prompting; `-i` prompts before replacing the destination. The last one wins.

### nice
`nice [-n increment] utility [argument ...]` runs a utility with an adjusted scheduling priority. `-n` sets a signed niceness increment (default `10`); a signed operand like `+5` or `-5` is also accepted before the utility. `--` ends option parsing.

### paste
`paste [-s] [-d list] file ...` joins corresponding lines of input files. `-s` joins each file's lines separately. `-d` cycles through the specified delimiters instead of using a tab; it recognizes `\n`, `\t`, `\\`, and `\0` (no delimiter). Use `-` for stdin.

### pwd
`pwd [-L] [-P]` prints the working directory. `-L` (default) uses `PWD` if it is a valid logical path to the current directory; `-P` prints the physical path. If both options are present, the last one wins.

### readlink
`readlink [-n] link` prints the stored target of a symbolic link without resolving it. `-n` omits the trailing newline.

### renice
`renice -n increment [-p] [-g] [-u] target ...` adjusts the nice values of running processes. `-n` supplies the signed increment; the legacy form `renice increment target ...` is also accepted. `-p` selects process IDs (default), `-g` process-group IDs, and `-u` usernames or numeric user IDs. Selectors can appear between targets and apply to the targets that follow. `--` ends option parsing.

### rm
`rm [-dfiRrv] file ...` removes files. `-d` allows removing empty directories; `-R` and `-r` remove directories recursively; `-v` prints removed paths. `-f` ignores missing paths, suppresses prompts, and permits no operands; `-i` prompts before removal. The last of `-f` and `-i` wins.

### rmdir
`rmdir [-p] directory ...` removes empty directories. `-p` also attempts to remove empty parent directories, stopping before the root.

### sed
`sed [-En] [-e script] [-f script_file] ... [script] [file ...]` applies an editing script to input. `-E` uses extended regular expressions; `-n` suppresses automatic printing. Repeat `-e` and `-f` to combine script fragments and files. With neither flag, the first operand is the script. With no input files, or with `-` as a file, read stdin. A script beginning with `#n` also suppresses automatic printing.

The `s` command supports `g` (all matches), `p` (print), `i`/`I` (ignore case), a numeric occurrence, and `w file` (write).

### sleep
`sleep [--] seconds` waits for a nonnegative whole number of seconds. No flags or fractional durations are supported.

### true
`true [argument ...]` always exits with status `0`. No flags; all arguments are ignored.

### uname
`uname [-amnrsv]` prints system information. `-s` prints the system name (default); `-n` the node name; `-r` the release; `-v` the version; `-m` the machine type; and `-a` all five fields.
