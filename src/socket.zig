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

pub fn fileDescriptor(allocator: Allocator) !?i32 {
    const sockaddr = try unixSocketAddress(allocator);
    if (sockaddr) |sa| {
        const fd = try std.posix.socket(
            std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        try std.posix.connect(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
        return fd;
    }

    return null;
}
