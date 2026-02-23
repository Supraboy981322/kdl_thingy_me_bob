const std = @import("std");
const kdl = @import("kdl");

// TODO: replace main() with something otherthan testing 
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const source = @embedFile("config.kdl");

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

pub const validation_result = union(enum(i8)) {
    ok: struct {
        lines: []const []const u8 = &.{},
        line_count: usize = 0,
        no_ansi: struct {
            lines:[]const []const u8 = &.{},
            strung:[]const u8 = "",
        } = .{},
        strung: []const u8 = "",
    },
    err: struct {
        value: ?anyerror = null,
        data: kdl.StreamIterator, 
    },
};

const colors = struct {
    pub const symbol:str = "\x1b[1;38;2;115;115;115m";
    pub const typename:str = "\x1b[3;1;36m";
    pub const class:str = "\x1b[0;34m";
    pub const num:str = "\x1b[38;2;255;165;0m";
    pub const string:str = "\x1b[32m";
    pub const @"bool":str = "\x1b[33m";
    pub const other = "\x1b[36m";
    const str = []const u8;
};

fn initial_validation(
    allocator:std.mem.Allocator,
    source:[]const u8
) !validation_result {
    //create an arena (me lazy)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    //leak a tonne of memory then reset arena when fn returns 
    defer {
        std.debug.print("nodes in initial validation arena: {d}\n", .{arena.state.end_index});
        _ = arena.reset(.free_all); arena.deinit();
    }

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
    while (
        //returns alternate struct on error
        itr.next() catch |e| return .{
            .err = .{
                .value = e,
                .data = itr,
            },
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
                const separator = if (!is_class) "" else b: {
                    break :b colors.symbol ++ "{\x1b[0m\n";
                };

                //determine how to style name
                const line_pre = if (is_class)
                    colors.symbol ++ "(" ++ colors.typename ++ "class"
                        ++ colors.symbol ++ ")" ++ colors.class
                else
                    "\x1b[35m";

                //construct the chunk with no indentation 
                const raw_chunk = try std.fmt.allocPrint(
                    alloc, "{s}{s}\x1b[0m {s}",
                    .{ line_pre, name_str, separator }
                );
               
                //add indentation to the chunk 
                const chunk = try indent_line(alloc, itr.depth, raw_chunk);

                //add the chunk
                try chunks.append(alloc, @constCast(chunk));
            },

            //add brace with indentation if the depth changed
            .end_node => if (previous_depth != itr.depth) {
                //add indentation to chunk
                const line_space = try indent_line(alloc, itr.depth, "}");
                //format the chunk
                const chunk = try std.fmt.allocPrint(
                    alloc, colors.symbol ++ "{s}\x1b[0m\n", .{ line_space }
                );
                //add the chunk
                try chunks.append(alloc, @constCast(chunk));
            },

            //the value of a node
            .argument => |arg| {
                const v:kdl.Value = arg.value;
                //switch on the value
                const v_str = try switch (v) {
                    .string => |a| std.fmt.allocPrint(
                        alloc, colors.string ++ "\"{s}\"", .{itr.getString(a)}
                    ),
                    .integer => |a| std.fmt.allocPrint(
                        alloc, colors.num ++ "{d}", .{a}
                    ),
                    .float => |a| std.fmt.allocPrint(
                        alloc, colors.num ++ "{d}", .{a.value}
                    ),
                    .boolean => |a| std.fmt.allocPrint(
                        alloc, colors.@"bool" ++ "#{}", .{a}
                    ),
                    .null_value, .nan_value, .positive_inf, .negative_inf => b: {
                        break :b std.fmt.allocPrint(
                            alloc, colors.other ++ "#{s}", .{ switch (v) {
                                .null_value => "null",
                                .nan_value => "nan",
                                .positive_inf => "inf",
                                .negative_inf => "-inf",
                                else => @panic("WHERE THE HELL DID THIS TOKEN COME FROM?"),
                            }}
                        );
                    }
                };

                //format the chunk
                const chunk = try std.fmt.allocPrint(
                    alloc, "{s}\x1b[0m\n", .{v_str}
                );

                //format the type string 
                const type_str:[]u8 = try std.fmt.allocPrint(
                    alloc, colors.symbol ++ "(" ++ colors.typename ++ "{s}"
                        ++ colors.symbol ++ ")\x1b[0m",
                    .{@tagName(v)}
                );

                //get the key for this value 
                const pre = chunks.pop().?;
    
                //add the type string with indentation 
                try chunks.append(alloc, @constCast(try indent_line(
                    alloc, previous_depth, type_str
                )));
                
                //add-back the key chunk (popped value) with indentation removed
                try chunks.append(alloc, pre[previous_depth*2..pre.len]);

                //add the value chunk
                try chunks.append(alloc, @constCast(chunk));
            },

            // TODO: this
            .property => |prop| {
                _ = prop;
                //const key = itr.getString(prop.name);
                //std.debug.print("Property: {s}\n", .{key});
            },
        }
        //set the next previous depth to the current depth 
        previous_depth = itr.depth;
    }

    //construct []const []const u8 of lines using provided allocator
    const lines, const strung, const stripped_lines = b: {
        //create an array list to string together the chunks 
        var strung = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer strung.deinit(allocator);

        //string a newly allocated string for each chunk together
        for (chunks.items) |chunk| try strung.appendSlice(alloc, try allocator.dupe(u8, chunk));

        //create array list to hold the resulting array of lines
        var res = try std.ArrayList([]u8).initCapacity(alloc, 0);
        defer res.deinit(allocator);
        //an array list with the ansi striped 
        var stripped = try std.ArrayList([]u8).initCapacity(alloc, 0);
        defer stripped.deinit(allocator);

        //keeps track of index of line start 
        var line_start:usize = 0;
        
        //range over strung chunks with index 
        for (strung.items, 0..) |b, i| switch (b) {
            '\n' => {
                const line = strung.items[line_start..i];
                //add allocated line string
                try res.append(allocator, try allocator.dupe(u8, line));
                //add line with stripped ansi
                const no_ansi = try strip_ansi(allocator, line);
                try stripped.append(allocator, try allocator.dupe(u8, no_ansi));
                //move line start to next line 
                line_start = i+1;
            },
            else => {}, //ignore everything else
        };
        
        //return slices reowned slices of results
        break :b .{
            try res.toOwnedSlice(allocator),
            try strung.toOwnedSlice(allocator),
            try stripped.toOwnedSlice(allocator),
        };
    };

    return .{ 
        .ok = .{ 
            .lines = lines,
            .line_count = lines.len,
            .no_ansi = .{
                .lines = stripped_lines,
                .strung = try strip_ansi(allocator, strung),
            },
            .strung = strung,
        },
    };
}

fn strip_ansi(
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

fn is_alpha(b:u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

fn indent_line(
    alloc:std.mem.Allocator,
    d:u16,
    str:[]const u8
) ![]const u8 {
    var whitespace = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer whitespace.deinit(alloc);
    for (0..d) |_| try whitespace.appendSlice(alloc, "  ");
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{whitespace.items, str});
}

fn trim_space(in:[]const u8) []const u8 {
    var s:usize = 0;
    const e = loop: for (0..in.len) |i| switch (in[i]) {
        ' ', '\t', '\n', '\r' => if (s > 0) break :loop i,
        else => { if (s == 0) s = i; }
    } else in.len;
    return in[s..e];
}

fn str_contains(str:[]const u8, n:u8) bool {
    return for (str) |b| {
        if (b == n) break true;
    } else false;
}

fn is_whitespace(b:u8) bool {
    return str_contains(" \r\n\t", b);
}
