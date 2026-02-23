const std = @import("std");
const kdl = @import("kdl");

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
            for (0..if (line_count > res.line_count) res.line_count else line_count) |i| {

                const og = if (og_lines.items[i][0] == '\n')
                    og_lines.items[i][1..]
                else
                    og_lines.items[i];

                const new = res.lines[i];
                std.debug.print(
                    "  \x1b[32mres:\x1b[0m\t{s}\n  \x1b[31mog:\x1b[0m \t{s}\n", .{new, og}
                );
            }
        },
        .err => @panic("TODO: err"),
    }

    std.debug.print("main memory leakage: {d}\n", .{arena.state.end_index});
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
                const separator = if (!is_class) " " else b: {
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
                        alloc, colors.num ++ "\x1b[38;2;255;165;0m{d}", .{a}
                    ),
                    .float => |a| std.fmt.allocPrint(
                        alloc, colors.num ++ "{d}", .{a.value}
                    ),
                    .boolean => |a| std.fmt.allocPrint(
                        alloc, colors.@"bool" ++ "#{}", .{a}
                    ),
                    .null_value, .nan_value, .positive_inf, .negative_inf => continue :loop,
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
                
                // TODO: make sure this can be removed
                // determine the amount of indentation
                // const space_count = for (pre, 0..) |b, i| (if (b != ' ') break i) else 0;
                
                //add the type string with indentation 
                try chunks.append(alloc, @constCast(try indent_line(
                    // TODO: make sure this can be removed
                    // alloc, @intCast(space_count/2), type_str 
                    alloc, previous_depth, type_str
                )));
                
                //add-back the key chunk (popped value) with indentation removed
                // TODO: make sure next line can be removed
                // try chunks.append(alloc, pre[space_count..pre.len]);s
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
    var ign = false;
    for (in) |b| switch (b) {
        '\x1b' => ign = true,
        else => {
            if (ign and is_alpha(b)) ign = false else {
                try res.append(alloc, b);
            }
        },
    };
    return res.toOwnedSlice(alloc);
}

fn is_alpha(b:u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
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
