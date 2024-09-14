const filter = @import("filter.zig");
const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayToggleSet = @import("array_toggle_set.zig").ArrayToggleSet;
const Candidate = filter.Candidate;
const Config = @import("opts.zig").Config;
const EditBuffer = @import("EditBuffer.zig");
const Key = vaxis.Key;
const Previewer = @import("Previewer.zig");

const sep = std.fs.path.sep;

pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
};

const HighlightSlicer = struct {
    matches: []const usize,
    highlight: bool,
    str: []const u8,
    index: usize = 0,

    const Slice = struct {
        str: []const u8,
        highlight: bool,
    };

    pub fn init(str: []const u8, matches: []const usize) HighlightSlicer {
        const highlight = std.mem.indexOfScalar(usize, matches, 0) != null;
        return .{ .str = str, .matches = matches, .highlight = highlight };
    }

    pub fn next(slicer: *HighlightSlicer) ?Slice {
        if (slicer.index >= slicer.str.len) return null;

        const start_state = slicer.highlight;
        var index: usize = slicer.index;
        while (index < slicer.str.len) : (index += 1) {
            const highlight = std.mem.indexOfScalar(usize, slicer.matches, index) != null;
            if (start_state != highlight) break;
        }

        const slice = Slice{ .str = slicer.str[slicer.index..index], .highlight = slicer.highlight };
        slicer.highlight = !slicer.highlight;
        slicer.index = index;
        return slice;
    }
};

fn calculateHighlights(
    str: []const u8,
    filenameOrNull: ?[]const u8,
    tokens: [][]const u8,
    case_sensitive: bool,
    plain: bool,
    matches: []usize,
) []usize {
    var index: usize = 0;
    for (tokens) |token| {
        const strict_path = !plain and filter.hasSeparator(token);
        const matched = filter.highlightToken(str, filenameOrNull, token, case_sensitive, strict_path, matches[index..]);
        index += matched.len;
    }

    return matches[0..index];
}

fn numDigits(number: usize) u16 {
    if (number == 0) return 1;
    return @intCast(std.math.log10(number) + 1);
}

/// split the query on spaces and return a slice of query tokens
pub fn splitQuery(query_tokens: [][]const u8, query: []const u8) [][]const u8 {
    var index: u8 = 0;
    var it = std.mem.tokenize(u8, query, " ");
    while (it.next()) |token| : (index += 1) {
        if (index == query_tokens.len) break;
        query_tokens[index] = token;
    }

    return query_tokens[0..index];
}

pub fn hasUpper(query: []const u8) bool {
    for (query) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

pub const State = struct {
    allocator: Allocator,
    config: Config,

    vx: vaxis.Vaxis,
    tty: vaxis.Tty,

    selected: usize = 0,
    selected_rows: ArrayToggleSet(usize),
    offset: usize = 0,
    query: EditBuffer,
    case_sensitive: bool = false,
    selection_changed: bool = false,

    preview: ?Previewer = null,
    preview_width: f64 = 0.6,

    pub fn init(allocator: Allocator, config: Config) !State {
        const vx = try vaxis.init(allocator, .{});

        return .{
            .allocator = allocator,
            .config = config,

            .vx = vx,
            .tty = try vaxis.Tty.init(),

            .selected = 0,
            .selected_rows = ArrayToggleSet(usize).init(allocator),
            .offset = 0,
            .query = EditBuffer.init(allocator),
        };
    }

    fn deinit(state: *State) void {
        // We must clear the window because we aren't using the alternate screen
        state.vx.window().clear();
        state.vx.render(state.tty.anyWriter()) catch {};

        state.vx.deinit(null, state.tty.anyWriter());
        state.tty.deinit();
    }

    pub fn run(
        state: *State,
        candidates: [][]const u8,
    ) !?[]const []const u8 {
        defer state.deinit();

        var filtered = blk: {
            var filtered = try ArrayList(Candidate).initCapacity(state.allocator, candidates.len);
            for (candidates) |candidate| {
                filtered.appendAssumeCapacity(.{ .str = candidate });
            }
            break :blk try filtered.toOwnedSlice();
        };
        const filtered_buf = try state.allocator.alloc(Candidate, candidates.len);

        const tokens_buf = try state.allocator.alloc([]const u8, 16);
        var tokens = splitQuery(tokens_buf, state.query.slice());

        var loop: vaxis.Loop(Event) = .{
            .tty = &state.tty,
            .vaxis = &state.vx,
        };
        try loop.init();

        try loop.start();
        defer loop.stop();

        {
            // Get initial window size
            const ws = try vaxis.Tty.getWinsize(state.tty.fd);
            try state.vx.resize(state.allocator, state.tty.anyWriter(), ws);
        }

        while (true) {
            if (state.query.dirty) {
                state.query.dirty = false;

                tokens = splitQuery(tokens_buf, state.query.slice());
                state.case_sensitive = hasUpper(state.query.slice());

                filtered = filter.rankCandidates(filtered_buf, candidates, tokens, state.config.keep_order, state.config.plain, state.case_sensitive);
                state.selected = 0;
                state.offset = 0;
                state.selected_rows.clear();
            }

            // The selection changed and the child process should be respawned
            // if (state.selection_changed) if (state.preview) |*preview| {
            //     state.selection_changed = false;
            //     if (filtered.len > 0) {
            //         try preview.spawn(filtered[state.selected + state.offset].str);
            //     } else try preview.reset();
            // };

            try state.draw(tokens, filtered, candidates.len);
            try state.vx.render(state.tty.anyWriter());

            const possibleResult = try state.handleInput(&loop, filtered.len);
            if (possibleResult) |result| {
                switch (result) {
                    .cancel => return null,
                    .none => return &.{},
                    .one => {
                        var selected_buf = try state.allocator.alloc([]const u8, 1);
                        selected_buf[0] = filtered[state.selected + state.offset].str;
                        return selected_buf;
                    },
                    .many => {
                        var selected_buf = try state.allocator.alloc([]const u8, state.selected_rows.slice().len);
                        for (state.selected_rows.slice(), 0..) |index, i| {
                            selected_buf[i] = filtered[index].str;
                        }
                        return selected_buf;
                    },
                }
            }
        }
    }

    const Result = enum { cancel, none, one, many };

    const Event = union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    };

    fn handleInput(state: *State, loop: *vaxis.Loop(Event), num_filtered: usize) !?Result {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                const visible_rows = @min(@min(state.config.height, state.vx.screen.height) - 1, num_filtered);

                if (key.matches('c', .{ .ctrl = true })) {
                    return .cancel;
                } else if (key.matches('w', .{ .ctrl = true })) {
                    if (state.query.len() > 0) deleteWord(&state.query);
                } else if (key.matches('u', .{ .ctrl = true })) {
                    state.query.deleteTo(0);
                } else if (key.matches(Key.backspace, .{})) {
                    state.query.delete(1, .left);
                } else if (key.matches('a', .{ .ctrl = true })) {
                    state.query.setCursor(0);
                } else if (key.matches('e', .{ .ctrl = true })) {
                    state.query.setCursor(state.query.len());
                } else if (key.matches('d', .{ .ctrl = true })) {
                    state.query.delete(1, .right);
                } else if (key.matches('f', .{ .ctrl = true }) or key.matches(Key.right, .{})) {
                    state.query.moveCursor(1, .right);
                } else if (key.matches('b', .{ .ctrl = true }) or key.matches(Key.left, .{})) {
                    state.query.moveCursor(1, .left);
                } else if (key.matches(Key.down, .{}) or key.matches('p', .{ .ctrl = true }) or key.matches('n', .{ .ctrl = true })) {
                    lineDown(state, visible_rows, num_filtered - visible_rows);
                } else if (key.matches(Key.up, .{})) {
                    lineUp(state);
                } else if (key.matches('k', .{ .ctrl = true })) {
                    if (state.config.vi_mode) lineUp(state) else state.query.deleteTo(state.query.len());
                } else if (key.matches(Key.tab, .{ .shift = true })) {
                    try state.selected_rows.toggle(state.selected + state.offset);
                    lineUp(state);
                } else if (key.matches(Key.tab, .{})) {
                    try state.selected_rows.toggle(state.selected + state.offset);
                    lineDown(state, visible_rows, num_filtered - visible_rows);
                } else if (key.matches(Key.enter, .{})) {
                    if (num_filtered == 0) return .none;
                    if (state.selected_rows.slice().len > 0) {
                        return .many;
                    }
                    return .one;
                } else if (key.matches(Key.escape, .{})) {
                    return .none;
                } else if (key.text) |text| {
                    try state.query.insert(text);
                }
            },
            .winsize => |ws| try state.vx.resize(state.allocator, state.tty.anyWriter(), ws),
        }

        return null;
    }

    fn draw(
        state: *State,
        tokens: [][]const u8,
        candidates: []Candidate,
        total_candidates: usize,
    ) !void {
        const win = state.vx.window();
        win.clear();

        const child = win.child(.{ .height = .{ .limit = state.config.height } });

        const width = state.vx.screen.width;
        const preview_width: usize = if (state.preview) |_|
            @intFromFloat(@as(f64, @floatFromInt(width)) * state.preview_width)
        else
            0;
        const items_width = width - preview_width - @as(usize, if (state.preview) |_| 2 else 0);
        _ = items_width;

        const height = @min(state.vx.screen.height, state.config.height);

        // draw the candidates
        var line: usize = 0;
        while (line < height - 1) : (line += 1) {
            if (line < candidates.len) state.drawCandidate(
                child,
                line + 1,
                candidates[line + state.offset],
                tokens,
                state.selected_rows.contains(line + state.offset),
                line == state.selected,
            );
        }

        // draw the stats
        const num_selected = state.selected_rows.slice().len;
        {
            var buf: [32]u8 = undefined;
            if (num_selected > 0) {
                const stats = try std.fmt.bufPrint(&buf, "{}/{} [{}]", .{ candidates.len, total_candidates, num_selected });
                const stats_width = numDigits(candidates.len) + numDigits(total_candidates) + numDigits(num_selected) + 4;
                _ = try child.printSegment(.{ .text = stats }, .{ .col_offset = width - stats_width, .row_offset = 0 });
            } else {
                const stats = try std.fmt.bufPrint(&buf, "{}/{}", .{ candidates.len, total_candidates });
                const stats_width = numDigits(candidates.len) + numDigits(total_candidates) + 1;
                _ = try child.printSegment(.{ .text = stats }, .{ .col_offset = width - stats_width, .row_offset = 0 });
            }
        }

        // draw the prompt
        // TODO: handle display of queries longer than the screen width
        // const query_width = state.query.slice().len;
        _ = try child.print(&.{
            .{ .text = state.config.prompt },
            .{ .text = state.query.slice() },
        }, .{ .col_offset = 0, .row_offset = 0 });

        // // draw a preview window if requested
        // if (state.preview) |*preview| {
        //     var lines = preview.lines();

        //     for (0..height) |_| {
        //         terminal.cursorCol(items_width + 2);
        //         terminal.write("│ ");

        //         if (lines.next()) |preview_line| {
        //             terminal.write(preview_line[0..@min(preview_line.len, preview_width - 1)]);
        //         }

        //         terminal.cursorDown(1);
        //     }
        //     terminal.sgr(.reset);
        // } else terminal.cursorDown(height);

        child.showCursor(state.config.prompt.len + state.query.cursor, 0);
    }

    fn drawCandidate(
        state: *State,
        win: vaxis.Window,
        line: usize,
        candidate: Candidate,
        tokens: [][]const u8,
        selected: bool,
        highlight: bool,
    ) void {
        var matches_buf: [2048]usize = undefined;
        const filename = if (state.config.plain) null else std.fs.path.basename(candidate.str);
        const matches = calculateHighlights(candidate.str, filename, tokens, state.case_sensitive, state.config.plain, &matches_buf);

        // no highlights, just output the string
        if (matches.len == 0) {
            _ = try win.print(&.{
                .{ .text = if (selected) "* " else "  " },
                .{
                    .text = candidate.str,
                    .style = .{ .reverse = highlight },
                },
            }, .{
                .row_offset = line,
                .col_offset = 0,
                .wrap = .none,
            });
        } else {
            var slicer = HighlightSlicer.init(candidate.str, matches);

            var res = try win.printSegment(.{
                .text = if (selected) "* " else "  ",
                .style = .{ .reverse = highlight },
            }, .{
                .row_offset = line,
                .col_offset = 0,
                .wrap = .none,
            });

            while (slicer.next()) |slice| {
                const highlight_style: vaxis.Style = .{
                    .reverse = highlight,
                    .fg = if (slice.highlight and state.config.highlight != null) .{
                        .index = @intFromEnum(state.config.highlight.?),
                    } else .default,
                };

                res = try win.printSegment(.{
                    .text = slice.str,
                    .style = highlight_style,
                }, .{
                    .row_offset = line,
                    .col_offset = res.col,
                    .wrap = .none,
                });
            }
        }
    }
};

/// Deletes a word to the left of the cursor. Words are separated by space or slash characters
fn deleteWord(query: *EditBuffer) void {
    var slice = query.slice()[0..query.cursor];
    var end = slice.len - 1;

    // ignore trailing spaces or slashes
    const trailing = slice[end];
    if (trailing == ' ' or trailing == sep) {
        while (end > 1 and slice[end] == trailing) {
            end -= 1;
        }
        slice = slice[0..end];
    }

    // find last most space or slash
    var last_index: ?usize = null;
    for (slice, 0..) |byte, i| {
        if (byte == ' ' or byte == sep) last_index = i;
    }

    if (last_index) |index| {
        query.deleteTo(index + 1);
    } else query.deleteTo(0);
}

fn lineUp(state: *State) void {
    if (state.selected > 0) {
        state.selected -= 1;
    } else if (state.offset > 0) {
        state.offset -= 1;
    }
}

fn lineDown(state: *State, visible_rows: usize, num_truncated: usize) void {
    if (state.selected + 1 < visible_rows) {
        state.selected += 1;
    } else if (state.offset < num_truncated) {
        state.offset += 1;
    }
}
