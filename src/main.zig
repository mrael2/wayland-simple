const std = @import("std");
const shmem = @import("shared_mem.zig");
const socket = @import("socket.zig");
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").target.cpu.arch.endian();

const wayland_header_size = 8;

fn createRegistry(allocator: Allocator, current_id: u32, fd: i32) !usize {
    const object_id: u32 = 1;
    const opcode: u16 = 1;
    const size: u16 = wayland_header_size + @sizeOf(@TypeOf(current_id));
    std.debug.assert(roundup4(size) == size);

    var item1: [4]u8 = undefined;
    var item2: [2]u8 = undefined;
    var item3: [2]u8 = undefined;
    var item4: [4]u8 = undefined;

    std.mem.writeInt(u32, &item1, object_id, native_endian);
    std.mem.writeInt(u16, &item2, opcode, native_endian);
    std.mem.writeInt(u16, &item3, size, native_endian);
    std.mem.writeInt(u32, &item4, current_id, native_endian);

    const items = [_][]u8{
        @constCast(&item1),
        @constCast(&item2),
        @constCast(&item3),
        @constCast(&item4),
    };
    std.debug.print("create registry {x}\n", .{items});
    const result = try std.mem.concat(allocator, u8, &items);
    defer allocator.free(result);
    std.debug.print("create registry {x}\n", .{result});
    const send_size = try std.posix.send(fd, result, std.os.linux.MSG.DONTWAIT);
    return send_size;
}

fn roundup4(n: u32) u32 {
    return (n + 3) & 0xfffffffc; // two's complement representation of -4
}

test "rounding1" {
    try std.testing.expect(roundup4(7) == 8);
}

test "rounding2" {
    try std.testing.expect(roundup4(11) == 12);
}

const page_size = std.mem.page_size;
const PoolData = []align(page_size)u8;

fn mapMemory(sh_fd: c_int, size: usize) !PoolData {
    const prot = std.posix.PROT.READ | std.posix.PROT.WRITE;
    const flags: std.posix.MAP = .{.TYPE = std.os.linux.MAP_TYPE.SHARED };
    const result = try std.posix.mmap(null, size, prot, flags, sh_fd, 0);
    return result;
}

const color_channels = 4;

const State = struct {
    wayland_registry_id: u32 = undefined,
    width: u32 = 117,
    height: u32 = 150,
    stride: u32 = undefined,
    shm_pool_data: PoolData = undefined,
    sh_fd: c_int = undefined,
    shm_pool_size: u32 = undefined,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    const fdOrNull = try socket.fileDescriptor(allocator);
    if (fdOrNull) |fd| {
        var state = State {};
        state.stride = state.width * color_channels;
        state.shm_pool_size = state.height * state.stride; // singe buffering
	var current_id: u32 = 2;
        state.wayland_registry_id = current_id;

        const size = createRegistry(allocator, current_id, fd)
            catch unreachable;

        current_id = current_id + 1;

        const sh_fd = try shmem.createSharedMemoryFile(allocator);
        state.sh_fd = sh_fd;

        try std.posix.ftruncate(sh_fd, size);

        const shm_pool_data = try mapMemory(sh_fd, size);

        state.shm_pool_data = shm_pool_data;

        //while (true) {
{
            var read_array: [4096]u8 = undefined;
            var read_buf: []u8 = &read_array;
            _ = &read_buf;
            const read_bytes = try std.posix.recv(fd, read_buf, 0);

            std.debug.print("{}\n", .{read_bytes});
            std.debug.print("{s}\n", .{read_buf});
        }
    }
}
