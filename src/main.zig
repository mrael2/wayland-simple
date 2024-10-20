const std = @import("std");
const Allocator = std.mem.Allocator;

fn socketPath(allocator: Allocator) !?[]u8 {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR")
        orelse return null;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY")
        orelse "wayland-0";
    const items = &[_][]const u8 {xdg_runtime_dir, "/", wayland_display};
    const result = try std.mem.concat(allocator, u8, items);

    return result;
}

const SocketAddr = std.posix.system.sockaddr.un;

fn unixSocketAddress(allocator: Allocator) !?SocketAddr {
    const opt_path = try socketPath(allocator); 

    if (opt_path) |path| {
        defer allocator.free(path);
        var sockaddr = SocketAddr {.path = undefined};
        std.mem.copyForwards(u8, @constCast(&sockaddr.path), path);
        return sockaddr;
    }
    else {
        return null;
    }
}

fn fileDescriptor(allocator: Allocator) !?i32 {
    const sockaddr = try unixSocketAddress(allocator);
    if (sockaddr) |sa| {
        const fd = try std.posix.socket(
            std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        try std.posix.connect(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
        return fd;
    }

    return null;
}

const wayland_header_size = 8;

fn message_create_registry(allocator: Allocator, current_id: u32) ![]u8 {
    const object: u32 = 1;
    const opcode: u16 = 1;
    const size: u16 = wayland_header_size + @sizeOf(@TypeOf(current_id));

    const item1: [4]u8 = std.mem.toBytes(object);
    const item2: [2]u8 = std.mem.toBytes(opcode);
    const item3: [2]u8 = std.mem.toBytes(size);
    const item4: [4]u8 = std.mem.toBytes(current_id);

    const items = [_][]u8 {
        @constCast(&item1),
        @constCast(&item2),
        @constCast(&item3),
        @constCast(&item4)};
    const result = try std.mem.concat(allocator, u8, &items);
    return result;
}

fn shared_memory_filename(allocator: Allocator) ![*:0]const u8 {
    const size = 16;
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    var prng = std.Random.DefaultPrng.init(seed);
    var name: [size]u8 = undefined;
    var i: u8 = 0;
    while (i < size) : (i += 1) {
        const value = prng.random().intRangeAtMost(u8, 'a', 'z');
        name[i] = value;
    }
    name[0] = '/';
    const result: [*:0]u8 = try allocator.dupeZ(u8, &name);
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    const fdOrNull = try fileDescriptor(allocator);
    if (fdOrNull) |fd| {
	var current_id: u32 = 1;
	const msg = try message_create_registry(allocator, current_id);
	defer allocator.free(msg);

        current_id += 1;

	std.debug.print("{x}\n", .{msg});

	const size = try std.posix.send(fd, msg, std.os.linux.MSG.DONTWAIT);
        std.debug.print("{}\n", .{size});
        const filename = try shared_memory_filename(allocator);
        defer allocator.free(std.mem.span(filename));
        std.debug.print("{s}\n", .{filename});
        const flag = std.c.O {.CREAT = true, .EXCL = true, .ACCMODE = .RDWR};
        const mode = 0o600;
        const sh_fd = std.c.shm_open(filename, @bitCast(flag), mode);
        std.debug.print("{}\n", .{sh_fd});
    }
}
