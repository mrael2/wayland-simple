const std = @import("std");
const shmem = @import("shared_mem.zig");
const socket = @import("socket.zig");
const Allocator = std.mem.Allocator;
const native_endian = @import("builtin").target.cpu.arch.endian();

const wayland_header_size = 8;

const Header = struct {
    object_id: u32,
    opcode: u16,
    size: u16,
};

fn headerMemory(allocator: Allocator, header: *const Header) ![]u8 {
    var item1: [4]u8 = undefined;
    var item2: [2]u8 = undefined;
    var item3: [2]u8 = undefined;

    std.mem.writeInt(u32, &item1, header.object_id, native_endian);
    std.mem.writeInt(u16, &item2, header.opcode, native_endian);
    std.mem.writeInt(u16, &item3, header.size, native_endian);

    const items = [_][]u8{
        @constCast(&item1),
        @constCast(&item2),
        @constCast(&item3),
    };
    const result = try std.mem.concat(allocator, u8, &items);
    return result;
}

fn registryMessage(allocator: Allocator, current_id: u32) ![]u8 {
    const size: u16 = wayland_header_size + @sizeOf(@TypeOf(current_id));
    std.debug.assert(roundup4(size) == size);

    const header = Header {
        .object_id = 1, // Wayland display object ID
        .opcode = 1, // get registry opcode
        .size = size,
    };

    const header_memory = try headerMemory(allocator, &header);
    defer allocator.free(header_memory);

    var id_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_bytes, current_id, native_endian);

    const items = [_][]u8{
        header_memory,
        &id_bytes,
    };
    const result = try std.mem.concat(allocator, u8, &items);
    return result;
}

fn createRegistry(allocator: Allocator, current_id: u32, fd: i32) !usize {
    const memory = try registryMessage(allocator, current_id);
    defer allocator.free(memory);

    const send_size = try std.posix.send(fd, memory, std.os.linux.MSG.DONTWAIT);
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
        state.shm_pool_size = state.height * state.stride; // single buffering
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
            const buffer: []u8 = read_buf[0..read_bytes];

            std.debug.print("{}\n", .{read_bytes});
            //std.debug.print("{s}\n", .{read_buf});
            //std.debug.print("{s}\n", .{buffer});

            waylandHandleMessage(sh_fd, &state, buffer);
        }
    }
}

fn waylandHandleMessage(fd: c_int, state: *State, msg: []u8) void {
    _ = fd;
    std.debug.assert(msg.len >= 8);

    const object_id_bytes = msg[0..4];
    const object_id: u32 = std.mem.readInt(u32, object_id_bytes, native_endian);

    const opcode_bytes = msg[4..6];
    const opcode = std.mem.readInt(u16, opcode_bytes, native_endian);

    const announced_size_bytes = msg[6..8];
    const announced_size = std.mem.readInt(u16, announced_size_bytes,
        native_endian);
    std.debug.assert(roundup4(announced_size) <= announced_size);

    const is_registry_event = object_id == state.wayland_registry_id
        and opcode == 0;

    if (is_registry_event) {
        std.debug.print("got here\n", .{});
        const name_bytes = msg[8..12];
        const name = std.mem.readInt(u32, name_bytes, native_endian);
        std.debug.print("name bytes = {x}\n", .{name_bytes});
        std.debug.print("name = {x}\n", .{name});

        const interface_len_bytes = msg[12..16];
        const interface_len = std.mem.readInt(u32, interface_len_bytes,
            native_endian);
        std.debug.print("interface len bytes = {x}\n", .{interface_len_bytes});
        std.debug.print("interface len = {x}\n", .{interface_len});
        const padded_interface_len = roundup4(interface_len);

        const fixed_interface_size = 512;
        var interface2: [fixed_interface_size]u8 = undefined;
        _ = &interface2;
        std.debug.print("padded len = {}\n", .{padded_interface_len});
        std.debug.print("interface2 len = {}\n", .{interface2.len});
        std.debug.assert(padded_interface_len <= interface2.len);

        const interface = msg[16..16+padded_interface_len];
        std.debug.print("{s}\n", .{interface});
    }
}
