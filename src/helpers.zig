const std = @import("std");

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
