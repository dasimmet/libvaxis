const std = @import("std");
const testing = std.testing;
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const CodePointIterator = @import("ziglyph").CodePointIterator;
const graphemeBreak = @import("ziglyph").graphemeBreak;
const UNICODE_MAX = @import("GraphemeCache.zig").UNICODE_MAX;

const log = std.log.scoped(.parser);

/// The return type of our parse method. Contains an Event and the number of
/// bytes read from the buffer.
pub const Result = struct {
    event: ?Event,
    n: usize,
};

// an intermediate data structure to hold sequence data while we are
// scanning more bytes. This is tailored for input parsing only
const Sequence = struct {
    // private indicators are 0x3C-0x3F
    private_indicator: ?u8 = null,
    // we won't be handling any sequences with more than one intermediate
    intermediate: ?u8 = null,
    // we should absolutely never have more then 16 params
    params: [16]u16 = undefined,
    param_idx: usize = 0,
    param_buf: [8]u8 = undefined,
    param_buf_idx: usize = 0,
    sub_state: std.StaticBitSet(16) = std.StaticBitSet(16).initEmpty(),
    empty_state: std.StaticBitSet(16) = std.StaticBitSet(16).initEmpty(),
};

// the state of the parser
const State = enum {
    ground,
    escape,
    csi,
    osc,
    dcs,
    sos,
    pm,
    apc,
    ss2,
    ss3,
};

pub fn parse(input: []const u8) !Result {
    const n = input.len;

    var seq: Sequence = .{};

    var state: State = .ground;

    var i: usize = 0;
    var start: usize = 0;
    // parse the read into events. This parser is bespoke for input parsing
    // and is not suitable for reuse as a generic vt parser
    while (i < n) : (i += 1) {
        const b = input[i];
        switch (state) {
            .ground => {
                // ground state generates keypresses when parsing input. We
                // generally get ascii characters, but anything less than
                // 0x20 is a Ctrl+<c> keypress. We map these to lowercase
                // ascii characters when we can
                const key: Key = switch (b) {
                    0x00 => .{ .codepoint = '@', .mods = .{ .ctrl = true } },
                    0x01...0x1A => .{ .codepoint = b + 0x60, .mods = .{ .ctrl = true } },
                    0x1B => escape: {
                        // NOTE: This could be an errant escape at the end
                        // of a large read. That is _incredibly_ unlikely
                        // given the size of read inputs and our read buffer
                        if (i == (n - 1)) {
                            const event = Key{
                                .codepoint = Key.escape,
                            };
                            break :escape event;
                        }
                        state = .escape;
                        continue;
                    },
                    // 0x20...0x7E => .{ .codepoint = b },
                    0x7F => .{ .codepoint = Key.backspace },
                    else => blk: {
                        var iter: CodePointIterator = .{ .bytes = input[i..] };
                        // return null if we don't have a valid codepoint
                        var cp = iter.next() orelse return .{ .event = null, .n = 0 };

                        var code = cp.code;
                        const g_start = i;
                        i += cp.len - 1; // subtract one for the loop iter
                        var g_state: u3 = 0;
                        while (iter.next()) |next_cp| {
                            if (graphemeBreak(cp.code, next_cp.code, &g_state)) {
                                break;
                            }
                            code = UNICODE_MAX + 1;
                            i += next_cp.len;
                            cp = next_cp;
                        }
                        const text: ?[]const u8 = multi: {
                            if (code > UNICODE_MAX) {
                                break :multi input[g_start .. i + 1];
                            } else {
                                break :multi null;
                            }
                        };

                        break :blk .{ .codepoint = code, .text = text };
                    },
                };
                return .{
                    .event = .{ .key_press = key },
                    .n = i + 1,
                };
            },
            .escape => {
                seq = .{};
                start = i;
                switch (b) {
                    0x4F => state = .ss3,
                    0x50 => state = .dcs,
                    0x58 => state = .sos,
                    0x5B => state = .csi,
                    0x5D => state = .osc,
                    0x5E => state = .pm,
                    0x5F => state = .apc,
                    else => {
                        // Anything else is an "alt + <b>" keypress
                        const key: Key = .{
                            .codepoint = b,
                            .mods = .{ .alt = true },
                        };
                        return .{
                            .event = .{ .key_press = key },
                            .n = i + 1,
                        };
                    },
                }
            },
            .ss3 => {
                const key: Key = switch (b) {
                    'A' => .{ .codepoint = Key.up },
                    'B' => .{ .codepoint = Key.down },
                    'C' => .{ .codepoint = Key.right },
                    'D' => .{ .codepoint = Key.left },
                    'F' => .{ .codepoint = Key.end },
                    'H' => .{ .codepoint = Key.home },
                    'P' => .{ .codepoint = Key.f1 },
                    'Q' => .{ .codepoint = Key.f2 },
                    'R' => .{ .codepoint = Key.f3 },
                    'S' => .{ .codepoint = Key.f4 },
                    else => {
                        log.warn("unhandled ss3: {x}", .{b});
                        return .{
                            .event = null,
                            .n = i + 1,
                        };
                    },
                };
                return .{
                    .event = .{ .key_press = key },
                    .n = i + 1,
                };
            },
            .csi => {
                switch (b) {
                    // c0 controls. we ignore these even though we should
                    // "execute" them. This isn't seen in practice
                    0x00...0x1F => {},
                    // intermediates. we only handle one. technically there
                    // can be more
                    0x20...0x2F => seq.intermediate = b,
                    0x30...0x39 => {
                        seq.param_buf[seq.param_buf_idx] = b;
                        seq.param_buf_idx += 1;
                    },
                    // private indicators. These come before any params ('?')
                    0x3C...0x3F => seq.private_indicator = b,
                    ';' => {
                        if (seq.param_buf_idx == 0) {
                            // empty param. default it to 0 and set the
                            // empty state
                            seq.params[seq.param_idx] = 0;
                            seq.empty_state.set(seq.param_idx);
                            seq.param_idx += 1;
                        } else {
                            const p = try std.fmt.parseUnsigned(u16, seq.param_buf[0..seq.param_buf_idx], 10);
                            seq.param_buf_idx = 0;
                            seq.params[seq.param_idx] = p;
                            seq.param_idx += 1;
                        }
                    },
                    ':' => {
                        if (seq.param_buf_idx == 0) {
                            // empty param. default it to 0 and set the
                            // empty state
                            seq.params[seq.param_idx] = 0;
                            seq.empty_state.set(seq.param_idx);
                            seq.param_idx += 1;
                            // Set the *next* param as a subparam
                            seq.sub_state.set(seq.param_idx);
                        } else {
                            const p = try std.fmt.parseUnsigned(u16, seq.param_buf[0..seq.param_buf_idx], 10);
                            seq.param_buf_idx = 0;
                            seq.params[seq.param_idx] = p;
                            seq.param_idx += 1;
                            // Set the *next* param as a subparam
                            seq.sub_state.set(seq.param_idx);
                        }
                    },
                    0x40...0xFF => {
                        if (seq.param_buf_idx > 0) {
                            const p = try std.fmt.parseUnsigned(u16, seq.param_buf[0..seq.param_buf_idx], 10);
                            seq.param_buf_idx = 0;
                            seq.params[seq.param_idx] = p;
                            seq.param_idx += 1;
                        }
                        // dispatch the sequence
                        state = .ground;
                        const codepoint: u21 = switch (b) {
                            'A' => Key.up,
                            'B' => Key.down,
                            'C' => Key.right,
                            'D' => Key.left,
                            'E' => Key.kp_begin,
                            'F' => Key.end,
                            'H' => Key.home,
                            'P' => Key.f1,
                            'Q' => Key.f2,
                            'R' => Key.f3,
                            'S' => Key.f4,
                            '~' => blk: {
                                // The first param will define this
                                // codepoint
                                if (seq.param_idx < 1) {
                                    log.warn("unhandled csi: CSI {s}", .{input[start + 1 .. i + 1]});
                                    continue;
                                }
                                switch (seq.params[0]) {
                                    2 => break :blk Key.insert,
                                    3 => break :blk Key.delete,
                                    5 => break :blk Key.page_up,
                                    6 => break :blk Key.page_down,
                                    7 => break :blk Key.home,
                                    8 => break :blk Key.end,
                                    11 => break :blk Key.f1,
                                    12 => break :blk Key.f2,
                                    13 => break :blk Key.f3,
                                    14 => break :blk Key.f4,
                                    15 => break :blk Key.f5,
                                    17 => break :blk Key.f6,
                                    18 => break :blk Key.f7,
                                    19 => break :blk Key.f8,
                                    20 => break :blk Key.f9,
                                    21 => break :blk Key.f10,
                                    23 => break :blk Key.f11,
                                    24 => break :blk Key.f12,
                                    200 => {
                                        return .{
                                            .event = .paste_start,
                                            .n = i + 1,
                                        };
                                    },
                                    201 => {
                                        return .{
                                            .event = .paste_end,
                                            .n = i + 1,
                                        };
                                    },
                                    57427 => break :blk Key.kp_begin,
                                    else => {
                                        log.warn("unhandled csi: CSI {s}", .{input[start + 1 .. i + 1]});
                                        continue;
                                    },
                                }
                            },
                            'u' => blk: {
                                if (seq.private_indicator) |_| {
                                    // response to our kitty query
                                    // TODO: kitty query handling
                                    log.warn("unhandled csi: CSI {s}", .{input[start + 1 .. i + 1]});
                                    continue;
                                }
                                if (seq.param_idx == 0) {
                                    log.warn("unhandled csi: CSI {s}", .{input[start + 1 .. i + 1]});
                                    continue;
                                }
                                // In any csi u encoding, the codepoint
                                // directly maps to our keypoint definitions
                                break :blk seq.params[0];
                            },

                            'I' => { // focus in
                                return .{ .event = .focus_in, .n = i + 1 };
                            },
                            'O' => { // focus out
                                return .{ .event = .focus_out, .n = i + 1 };
                            },
                            else => {
                                log.warn("unhandled csi: CSI {s}", .{input[start + 1 .. i + 1]});
                                continue;
                            },
                        };

                        var key: Key = .{ .codepoint = codepoint };

                        var idx: usize = 0;
                        var field: u8 = 0;
                        // parse the parameters
                        while (idx < seq.param_idx) : (idx += 1) {
                            switch (field) {
                                0 => {
                                    defer field += 1;
                                    // field 0 contains our codepoint. Any
                                    // subparameters shifted key code and
                                    // alternate keycode (csi u encoding)

                                    // We already handled our codepoint so
                                    // we just need to check for subs
                                    if (!seq.sub_state.isSet(idx + 1)) {
                                        continue;
                                    }
                                    idx += 1;
                                    // The first one is a shifted code if it
                                    // isn't empty
                                    if (!seq.empty_state.isSet(idx)) {
                                        key.shifted_codepoint = seq.params[idx];
                                    }
                                    // check the next one for base layout
                                    // code
                                    if (!seq.sub_state.isSet(idx + 1)) {
                                        continue;
                                    }
                                    idx += 1;
                                    key.base_layout_codepoint = seq.params[idx];
                                },
                                1 => {
                                    // field 1 is modifiers and optionally
                                    // the event type (csiu)
                                    const mod_mask: u8 = @truncate(seq.params[idx] - 1);
                                    key.mods = @bitCast(mod_mask);
                                },
                                else => {},
                            }
                        }
                        return .{
                            .event = .{ .key_press = key },
                            .n = i + 1,
                        };
                    },
                }
            },
            else => {},
        }
    }
    // If we get here it means we didn't parse an event. The input buffer
    // perhaps didn't include a full event
    return .{
        .event = null,
        .n = 0,
    };
}

test "parse: single xterm keypress" {
    const input = "a";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = 'a' };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single xterm keypress with more buffer" {
    const input = "ab";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = 'a' };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm escape keypress" {
    const input = "\x1b";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = Key.escape };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm ctrl+a" {
    const input = "\x01";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(1, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm alt+a" {
    const input = "\x1ba";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = 'a', .mods = .{ .alt = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(2, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm invalid ss3" {
    const input = "\x1bOZ";
    const result = try parse(input);

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(null, result.event);
}

test "parse: xterm key up" {
    {
        // normal version
        const input = "\x1bOA";
        const result = try parse(input);
        const expected_key: Key = .{ .codepoint = Key.up };
        const expected_event: Event = .{ .key_press = expected_key };

        try testing.expectEqual(3, result.n);
        try testing.expectEqual(expected_event, result.event);
    }

    {
        // application keys version
        const input = "\x1b[2~";
        const result = try parse(input);
        const expected_key: Key = .{ .codepoint = Key.insert };
        const expected_event: Event = .{ .key_press = expected_key };

        try testing.expectEqual(4, result.n);
        try testing.expectEqual(expected_event, result.event);
    }
}

test "parse: xterm shift+up" {
    const input = "\x1b[1;2A";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = Key.up, .mods = .{ .shift = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: xterm insert" {
    const input = "\x1b[1;2A";
    const result = try parse(input);
    const expected_key: Key = .{ .codepoint = Key.up, .mods = .{ .shift = true } };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: paste_start" {
    const input = "\x1b[200~";
    const result = try parse(input);
    const expected_event: Event = .paste_start;

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: paste_end" {
    const input = "\x1b[201~";
    const result = try parse(input);
    const expected_event: Event = .paste_end;

    try testing.expectEqual(6, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: focus_in" {
    const input = "\x1b[I";
    const result = try parse(input);
    const expected_event: Event = .focus_in;

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: focus_out" {
    const input = "\x1b[O";
    const result = try parse(input);
    const expected_event: Event = .focus_out;

    try testing.expectEqual(3, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: shift+a without text reporting" {
    const input = "\x1b[97:65;2u";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(10, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: alt+shift+a without text reporting" {
    const input = "\x1b[97:65;4u";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true, .alt = true },
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(10, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: kitty: a without text reporting" {
    const input = "\x1b[97u";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = 'a',
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(5, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single codepoint" {
    const input = "🙂";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = 0x1F642,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(4, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: single codepoint with more in buffer" {
    const input = "🙂a";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = 0x1F642,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(4, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: multiple codepoint grapheme" {
    // TODO: this test is passing but throws a warning. Not sure how we'll
    // handle graphemes yet
    const input = "👩‍🚀";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = UNICODE_MAX + 1,
        .text = input,
    };
    const expected_event: Event = .{ .key_press = expected_key };

    try testing.expectEqual(input.len, result.n);
    try testing.expectEqual(expected_event, result.event);
}

test "parse: multiple codepoint grapheme with more after" {
    // TODO: this test is passing but throws a warning. Not sure how we'll
    // handle graphemes yet
    const input = "👩‍🚀abc";
    const result = try parse(input);
    const expected_key: Key = .{
        .codepoint = UNICODE_MAX + 1,
        .text = "👩‍🚀",
    };

    try testing.expectEqual(expected_key.text.?.len, result.n);
    const actual = result.event.?.key_press;
    try testing.expectEqualStrings(expected_key.text.?, actual.text.?);
    try testing.expectEqual(expected_key.codepoint, actual.codepoint);
}