const std = @import("std");
const shmem = @import("shared_mem.zig");
const socket = @import("socket.zig");
const Allocator = std.mem.Allocator;

const wayland_header_size = 8;

fn messageCreateRegistry(allocator: Allocator, current_id: u32) ![]u8 {
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

fn createRegistry(allocator: Allocator, current_id: u32, fd: i32) !usize {
    const msg = try messageCreateRegistry(allocator, current_id);
    defer allocator.free(msg);

    const size = try std.posix.send(fd, msg, std.os.linux.MSG.DONTWAIT);
    return size;
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
	var current_id: u32 = 1;
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
