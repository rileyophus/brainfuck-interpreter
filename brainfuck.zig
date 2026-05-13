//! A Brainfuck interpreter
//! Usage:  $ brainfuck <file>

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Dir = std.Io.Dir;
const File = std.Io.File;
const debug = std.debug;

const file_buf_len = 4096;
const stdin_buf_len = 128;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const filename = (try init.minimal.args.toSlice(arena))[1];

    const file = try Dir.cwd().openFile(io, filename, .{});
    defer file.close(io);

    var file_buf: [file_buf_len]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const reader = &file_reader.interface;

    var stdin_buf: [stdin_buf_len]u8 = undefined;
    var stdin_reader = File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_writer = File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    //------------------------------------------------------------------------//

    var tape: [1 << 16]u8 = @splat(0);
    var pointer: u16 = 0;
    var jump_table: AutoHashMap(usize, usize) = .init(arena);

    while (reader.takeByte()) |char| switch (char) {
        '+' => tape[pointer] +%= 1,
        '-' => tape[pointer] -%= 1,
        '>' => pointer +%= 1,
        '<' => pointer -%= 1,
        '.' => try stdout.writeByte(tape[pointer]),
        ',' => tape[pointer] = try stdin.takeByte(),
        '[' => {
            const left_bracket_pos = file_reader.logicalPos();

            const right_bracket_pos = jump_table.get(left_bracket_pos) orelse block: {
                try matchBrackets(arena, &file_reader, &jump_table, left_bracket_pos);
                break :block jump_table.get(left_bracket_pos).?;
            };
            try file_reader.seekTo(
                if (tape[pointer] == 0) right_bracket_pos else left_bracket_pos
            );
        },
        ']' => {
            const right_bracket_pos = file_reader.logicalPos();
            const left_bracket_pos = jump_table.get(right_bracket_pos) orelse {
                debug.print(
                    "Unmatched right bracket at position {} in file\n",
                    .{right_bracket_pos}
                );
                return error.UnmatchedBracket;
            };
            if (tape[pointer] != 0) try file_reader.seekTo(left_bracket_pos);
        },
        ' ', '\t', '\r', '\n' => {},

        else => {
            debug.print("Invalid character at position {} in file\n", .{file_reader.logicalPos()});
            return error.InvalidCharacter;
        },
    } else |err| switch (err) {
        error.ReadFailed => return err,
        error.EndOfStream => {},
    }
}

/// Upon encountering a left bracket, find its right bracket, also recording all
/// the matching bracket pairs found along the way.
fn matchBrackets(
    allocator: Allocator,
    file_reader: *File.Reader,
    jump_table: *AutoHashMap(usize, usize),
    outer_left_bracket_pos: usize
) !void {
    const reader = &file_reader.interface;
    var bracket_stack: ArrayList(usize) = .empty;

    try bracket_stack.append(allocator, outer_left_bracket_pos);
    while (bracket_stack.items.len > 0) {
        const char = reader.takeByte() catch {
            debug.print(
                "Unmatched left bracket at position {} in file\n",
                .{bracket_stack.pop().?}
            );
            return error.UnmatchedBracket;
        };
        const file_pos = file_reader.logicalPos();

        if (char == '[') {
            try bracket_stack.append(allocator, file_pos);
        } else if (char == ']') {
            const matching_left_bracket = bracket_stack.pop().?;
            _ = try jump_table.getOrPutValue(matching_left_bracket, file_pos);
            _ = try jump_table.getOrPutValue(file_pos, matching_left_bracket);
        }
    }
}
