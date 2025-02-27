const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    var file_buffer: [150 * 1024]u8 = undefined;
    var stdout = std.io.getStdOut().writer();

    while (args.next()) |page_path| {
        const html_path = args.next().?;
        const html = try read_file(std.fs.cwd(), html_path, &file_buffer);

        var clear_h1_link = false;
        var it = Iterator.init(html);
        while (it.next()) |token| {
            try stdout.writeAll(token.prefix);
            try switch (token.typ) {
                .link => rewrite_link(if (clear_h1_link) "" else token.value, page_path, stdout),
                .id => rewrite_id(if (token.is_h1) "" else token.value, page_path, stdout),
            };
            clear_h1_link = token.is_h1;
        }
        try stdout.writeAll(it.remaining);
        try stdout.writeByte('\n');
    }
}

fn rewrite_link(link: []const u8, page_path: []const u8, writer: anytype) !void {
    if (std.mem.startsWith(u8, link, "http") // external link.
    or std.mem.startsWith(u8, link, "mailto:") // email.
    or std.mem.startsWith(u8, link, "#cb") // code block link.
    ) {
        return try writer.writeAll(link);
    }

    var base: []const u8 = link;
    var fragment: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, link, '#')) |index| {
        base = link[0..index];
        fragment = link[index + 1 ..];
    }

    var buffer: [200]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var path = if (base.len > 0 and base[0] == '/')
        base[1..]
    else
        try std.fs.path.resolvePosix(allocator, &.{ page_path, base });
    if (std.mem.eql(u8, path, ".")) path = "";
    path = std.mem.trimRight(u8, path, "/");

    const slug = try path2slug(allocator, path);
    if (fragment) |frag| {
        if (slug.len > 0) {
            try writer.print("#{s}-{s}", .{ slug, frag });
        } else {
            try writer.print("#{s}", .{frag});
        }
    } else {
        try writer.print("#{s}", .{slug});
    }
}

fn rewrite_id(id: []const u8, page_path: []const u8, writer: anytype) !void {
    if (std.mem.startsWith(u8, id, "cb") // code block lines.
    ) {
        return try writer.writeAll(id);
    }

    if (page_path.len > 0) {
        var buffer: [200]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();
        const slug = try path2slug(allocator, page_path);
        if (id.len > 0) {
            try writer.print("{s}-{s}", .{ slug, id });
        } else {
            try writer.writeAll(slug);
        }
    } else {
        try writer.writeAll(id);
    }
}

fn path2slug(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const slug = try allocator.dupe(u8, path);
    std.mem.replaceScalar(u8, slug, '/', '-');
    return slug;
}

const Iterator = struct {
    const Token = struct {
        const Type = enum { link, id };

        typ: Type,
        prefix: []const u8,
        value: []const u8,
        is_h1: bool,
    };

    const link_prefix = "href=\"";
    const id_prefix = "id=\"";

    remaining: []const u8,

    fn init(html: []const u8) Iterator {
        return .{ .remaining = html };
    }

    fn next(self: *Iterator) ?Token {
        var first_index: ?usize = null;
        var typ: Token.Type = undefined;
        var is_h1 = false;

        const whitespace = &.{ " ", "\n" };
        inline for (whitespace) |ws| {
            const tag_link_prefix = "a" ++ ws ++ link_prefix;
            if (std.mem.indexOf(u8, self.remaining, tag_link_prefix)) |link_index| {
                if (first_index) |index| {
                    if (link_index < index) {
                        first_index = link_index + tag_link_prefix.len;
                        typ = .link;
                    }
                } else {
                    first_index = link_index + tag_link_prefix.len;
                    typ = .link;
                }
            }
        }
        const id_tags = &.{ "h1", "h2", "h3", "h4", "h5", "h6", "li" };
        inline for (id_tags) |tag| {
            const tag_id_prefix = tag ++ " " ++ id_prefix;
            if (std.mem.indexOf(u8, self.remaining, tag_id_prefix)) |hid_index| {
                if (first_index) |index| {
                    if (hid_index < index) {
                        first_index = hid_index + tag_id_prefix.len;
                        typ = .id;
                        is_h1 = std.mem.eql(u8, tag, "h1");
                    }
                } else {
                    first_index = hid_index + tag_id_prefix.len;
                    typ = .id;
                    is_h1 = std.mem.eql(u8, tag, "h1");
                }
            }
        }

        const value_start = first_index orelse return null;
        const value_len = std.mem.indexOfScalar(u8, self.remaining[value_start..], '"') orelse
            return null;

        const prefix = self.remaining[0..value_start];
        const value = self.remaining[value_start..][0..value_len];
        self.remaining = self.remaining[value_start + value_len ..];

        return .{ .typ = typ, .prefix = prefix, .value = value, .is_h1 = is_h1 };
    }
};

fn read_file(dir: std.fs.Dir, path: []const u8, page_buffer: []u8) ![]const u8 {
    const result = try dir.readFile(path, page_buffer);
    if (result.len == page_buffer.len) return error.FileToLarge;
    return result;
}
