const std = @import("std");

const validation = @import("validation.zig");

const initial_validation = validation.initial_validation;

pub fn strip_ansi(
    alloc:std.mem.Allocator,
    in: []const u8
) ![]const u8 {
    var res = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer res.deinit(alloc);
    var ign = false;
    for (in) |b| {
        if (b == '\x1b')
            ign = true
        else if (ign and is_alpha(b))
            ign = false
        else if (!ign)
            try res.append(alloc, b);
    }
    return res.toOwnedSlice(alloc);
}

pub fn is_alpha(b:u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

pub fn indent_line(
    alloc:std.mem.Allocator,
    d:u16,
    str:[]const u8
) ![]const u8 {
    var whitespace = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer whitespace.deinit(alloc);
    for (0..d) |_| try whitespace.appendSlice(alloc, "  ");
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{whitespace.items, str});
}

pub fn trim_space(in:[]const u8) []const u8 {
    var s:usize = 0;
    const e = loop: for (0..in.len) |i| switch (in[i]) {
        ' ', '\t', '\n', '\r' => if (s > 0) break :loop i,
        else => { if (s == 0) s = i; }
    } else in.len;
    return in[s..e];
}

pub fn str_contains(str:[]const u8, n:u8) bool {
    return for (str) |b| {
        if (b == n) break true;
    } else false;
}

pub fn is_whitespace(b:u8) bool {
    return str_contains(" \r\n\t", b);
}

pub const print = struct {
    pub fn out(comptime fmt:[]const u8, args:anytype) !void {
        var buf:[1024]u8 = undefined;
        var wr = std.fs.File.stdout().writer(&buf);
        const stdout = &wr.interface;
        try stdout.print(fmt, args);
        try stdout.flush();
    }
    pub fn err(comptime fmt:[]const u8, args:anytype) !void {
        var buf:[1024]u8 = undefined;
        var wr = std.fs.File.sterr().writer(&buf);
        const stderr = &wr.interface;
        try stderr.print(fmt, args);
        try stderr.flush();
    }
};

pub fn print_lines(lines:[]const []const u8) !void {
    for (lines) |l| try print.out("{s}\n", .{l});
}

pub fn validate_and_print(source:[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var og_lines = try std.ArrayList([]const u8).initCapacity(alloc, 0); 

    var line_start:usize, var line_count:usize = .{ 0, 1 };
    for (source, 0..) |b, i| if (b == '\n') {
        const line = source[line_start..i];
        if (trim_space(line).len == 0) continue;
        try og_lines.append(alloc, line);
        line_count += 1;
        line_start = i+1;
    };

    const re_assembled = try initial_validation(alloc, source);
    switch (re_assembled) {
        .ok => |res| {
            const larger_line_count =
                if (line_count > res.line_count)
                    res.line_count
                else
                    line_count;

            for (0..larger_line_count) |i| {
                const cur = .{
                    .og = og_lines.items[i],
                    .new = res.lines[i],
                };

                const og = if (cur.og[0] == '\n') cur.og[1..] else cur.og;

                std.debug.print(
                    "  \x1b[32mres:\x1b[0m\t{s}\n  \x1b[31mog:\x1b[0m \t{s}\n", .{cur.new, og}
                );
            }
        },
        .err => |err| {
            var tokenizer = err.data.tokenizer;
            const line_no, const column = .{ tokenizer.line-1, tokenizer.column-1 };
            const line = og_lines.items[line_no];
            const tok = tokenizer.token_buffer.items[0..];
            std.debug.print(
                "\x1b[1;31mERR:\x1b[22m {t} "
                    ++ "\x1b[3;35m(line \x1b[4;36m{d}\x1b[24;35m, "
                    ++ "column \x1b[4;36m{d}\x1b[24;35m)\x1b[0m\n",
                .{err.value.?, line_no, column }
            );
            const pre = line[0..line.len-tok.len];
            std.debug.print("\t{s}\x1b[5;1;33m{s}\n", .{ pre, line[pre.len..pre.len+tok.len] });
            std.debug.print("\t\x1b[34m{s}\x1b[0m\n", .{ b: {
                var res = try std.ArrayList(u8).initCapacity(alloc, 0);
                defer res.deinit(alloc);
                var do_underline = false;
                for (0..column-tok.len) |i| {
                    do_underline = if (!do_underline and line[i] == ' ') false else true;
                    try res.append(alloc, if (do_underline) '^' else ' ');
                }
                try res.appendSlice(alloc, "\x1b[1;36m");
                for (0..tok.len) |_| try res.append(alloc, '^');
                break :b try res.toOwnedSlice(alloc);
            }});
        },
    }

    std.debug.print("nodes in main arena: {d}\n", .{arena.state.end_index});
    if (!arena.reset(.free_all)) @panic("failed to reset arena");

    arena.deinit();
}
