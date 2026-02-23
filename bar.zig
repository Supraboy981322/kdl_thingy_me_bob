const std = @import("std");
const kdl = @import("kdl");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const source = @embedFile("config.kdl");
    var line_count:usize = 1;
    var og_lines = try std.ArrayList([]const u8).initCapacity(alloc, 0); 
    var line_start:usize = 0;
    for (source, 0..) |b, i| if (b == '\n') {
        const line = source[line_start..i];
        if (trim_space(line).len == 0) continue;
        try og_lines.append(alloc, line);
        line_count += 1;
        line_start = i+1;
    };

    const re_assembled = try initial_validation(alloc, source);
    for (0..if (line_count > re_assembled.len) re_assembled.len else line_count) |i| {

        const og = if (og_lines.items[i][0] == '\n')
            og_lines.items[i][1..]
        else
            og_lines.items[i];

        const new = re_assembled[i];
        std.debug.print(
            "  \x1b[32mres:\x1b[0m\t{s}\n  \x1b[31mog:\x1b[0m \t{s}\n", .{new, og}
        );
    }

    std.debug.print("main memory leakage: {d}\n", .{arena.state.end_index});
    if (!arena.reset(.free_all)) @panic("failed to reset arena");

    arena.deinit();
}

pub const validation_result = struct {
    err: ?anyerror = null,
    data: if (Self.err) struct {
        result: []const []const u8 = .{},
        line_count: usize = 0,
        no_ansi: []const []const u8 = .{},
        strung: []const u8 = "",
    } else kdl.StreamIterator = .{},
    const Self = @This();
};

const colors = struct {
    const str = []const u8;
    symbol:str = "\x1b[1;38;2;115;115;115m",
    typename:str = "\x1b[3;1;36m",
    class:str = "\x1b[0;34m",
};

fn initial_validation(
    allocator:std.mem.Allocator,
    source:[]const u8
) !validation_result {
    //create an arena (me lazy)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    //leak a tonne of memory then reset arena when fn returns 
    defer { _ = arena.reset(.free_all); arena.deinit(); }

    //initialize a stream iterator for the KDL source 
    var reader = std.Io.Reader.fixed(source);
    var itr = try kdl.StreamIterator.init(alloc, &reader,);
    defer itr.deinit();

    //create somewhere to store the chunks
    var chunks = try std.ArrayList([]u8).initCapacity(alloc, 0);
    defer chunks.deinit(alloc);

    //holds the depth of previous token
    //  (determines if a closing brace should be inserted)
    var previous_depth:u16 = 0;

    //iterate over source 
    loop: while (
        //returns alternate struct on error
        itr.next() catch |e| {
            return .{ .err = e, .data = itr };
        }
    ) |event| {
        //switch on "event" token
        switch (event) {

            //start of a node
            .start_node => |n| {
                //get some information about the "event" 
                const name = n.name;
                const name_str = itr.getString(name);
                const cur_tok = itr.current_token orelse @panic("null token"); // TODO: handle
                const is_class = cur_tok.type == .open_brace;

                //determine which separator is used
                const separator = if (!is_class) " " else b: {
                    break :b colors.symbol ++ "{\x1b[0m\n";
                };

                //determine how to style name
                const line_pre = if (is_class)
                    colors.symbol ++ "(" ++ colors.typename ++ "class"
                        ++ colors.symbol ++ ")" ++ colors.class
                else
                    "\x1b[35m";

                //construct the line with no indentation 
                const raw_chunk = try std.fmt.allocPrint(
                    alloc, "{s}{s}\x1b[0m {s}",
                    .{ line_pre, name_str, separator }
                );
               
                //add indentation to the line
                const chunk = try indent_line(alloc, itr.depth, raw_chunk);

                //add the chunk
                try chunks.append(alloc, @constCast(chunk));
            },

            //add brace with indentation if the depth changed
            .end_node => if (previous_depth != itr.depth) {
                //add indentations to line
                const line_space = try indent_line(alloc, itr.depth, "}");
                const line = try std.fmt.allocPrint(
                    alloc, "\x1b[1;38;2;115;115;115m{s}\x1b[0m\n", .{ line_space }
                );
                try chunks.append(alloc, @constCast(line));
            },
            .argument => |arg| {
                const v:kdl.Value = arg.value;
                const v_str = try switch (v) {
                    .string => |a| std.fmt.allocPrint(
                        alloc, "\x1b[32m\"{s}\"", .{itr.getString(a)}
                    ),
                    .integer => |a| std.fmt.allocPrint(
                        alloc, "\x1b[38;2;255;165;0m{d}", .{a}
                    ),
                    .float => |a| std.fmt.allocPrint(
                        alloc, "\x1b[38;2;255;165;0m{d}", .{a.value}
                    ),
                    .boolean => |a| std.fmt.allocPrint(
                        alloc, "\x1b[38;2;255;165;0m#{}", .{a}
                    ),
                    .null_value, .nan_value, .positive_inf, .negative_inf => continue :loop,
                };
                const chunk = try std.fmt.allocPrint(alloc, "{s}\x1b[0m\n", .{v_str});
                const type_str:[]u8 = try std.fmt.allocPrint(
                    alloc, "\x1b[1;38;2;115;115;115m(\x1b[3;1;36m{s}\x1b[0;38;2;115;115;115m)\x1b[0m", .{@tagName(v)}
                );
                const pre = chunks.pop().?;
                const space_count = for (pre, 0..) |b, i| (if (b != ' ') break i) else 0;
                try chunks.append(alloc, @constCast(try line_with_space(
                    alloc, @intCast(space_count/2), type_str
                )));
                try chunks.append(alloc, pre[space_count..pre.len]);
                try chunks.append(alloc, @constCast(chunk));
            },
            .property => |prop| {
                _ = prop;
                //const key = itr.getString(prop.name);
                //std.debug.print("Property: {s}\n", .{key});
            },
        }
        previous_depth = itr.depth;
    }

    //construct []const []const u8 of lines using provided allocator
    const lines = b: {
        var strung = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer strung.deinit(allocator);
        for (chunks.items) |chunk| try strung.appendSlice(alloc, chunk);
        var r = try std.ArrayList([]u8).initCapacity(alloc, 0);
        defer r.deinit(allocator);
        var line_start:usize = 0;
        for (strung.items, 0..) |b, i| switch (b) {
            '\n' => {
                try r.append(alloc, try allocator.dupe(u8, strung.items[line_start..i]));
                line_start = i+1;
            },
            else => {},
        };
        break :b try r.toOwnedSlice(allocator);
    };
    return try allocator.dupe([]const u8, lines);
}

fn err_out(
    itr:kdl.StreamIterator,
    e: anyerror,
    source:[]const u8
) void {
    const tokenizer = itr.tokenizer;
    const tok = itr.current_token orelse {
        std.debug.print(
            "error: ({t}) line {d} column {d}\n",
            .{e, tokenizer.line, tokenizer.column}
        );
        std.process.exit(1);
    };
    std.debug.print(
        "error: ({t}) {s}\n",
        .{e, source[tokenizer.pos-tok.text_len..tokenizer.pos]}
    );
    std.process.exit(1);

}

fn line_with_space(
    alloc:std.mem.Allocator,
    d:u16,
    str:[]const u8
) ![]const u8 {
    var whitespace = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer whitespace.deinit(alloc);
    for (0..d) |_| try whitespace.appendSlice(alloc, "  ");
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{whitespace.items, str});
}

fn idx_no_whitespace(str:[]const u8, i:usize) usize {
    return switch(str[i]) {
        ' ', '\t', '\n', '\r' => idx_no_whitespace(str, i+1),
        else => i,
    };
}

fn trim_space(in:[]const u8) []const u8 {
    var s:usize = 0;
    const e = loop: for (0..in.len) |i| switch (in[i]) {
        ' ', '\t', '\n', '\r' => if (s > 0) break :loop i,
        else => { if (s == 0) s = i; }
    } else in.len;
    return in[s..e];
}
