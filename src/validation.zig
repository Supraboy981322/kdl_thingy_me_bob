const std = @import("std");
const kdl = @import("kdl");
const hlp = @import("hlp");
const globs = @import("globs.zig");

const colors = globs.colors;

fn initial_validation(
    allocator:std.mem.Allocator,
    source:[]const u8
) !globs.validation_result {
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
                const chunk = try hlp.indent_line(alloc, itr.depth, raw_chunk);

                //add the chunk
                try chunks.append(alloc, @constCast(chunk));
            },

            //add brace with indentation if the depth changed
            .end_node => if (previous_depth != itr.depth) {
                //add indentation to chunk
                const line_space = try hlp.indent_line(alloc, itr.depth, "}");
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
                //switch on the type
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
                try chunks.append(alloc, @constCast(try hlp.indent_line(
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
                const no_ansi = try hlp.strip_ansi(allocator, line);
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
                .strung = try hlp.strip_ansi(allocator, strung),
            },
            .strung = strung,
        },
    };
}
