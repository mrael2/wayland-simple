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

const Registry = struct {
    registry: u32,
    name: u32,
    interface: []u8,
    non_padded_interface: []u8,
    version: u32,
    current_id: u32,
};

fn registryBindMessageHeader(registry: *const Registry) Header {
    const interface_len: u32 = @intCast(registry.interface.len);
    const rounded: u16 = @intCast(roundup4(interface_len));
    const size: u16 = wayland_header_size
        + @sizeOf(@TypeOf(registry.name))
        + @sizeOf(@TypeOf(interface_len))
        + rounded
        + @sizeOf(@TypeOf(registry.version))
        + @sizeOf(@TypeOf(registry.current_id));
    std.debug.assert(roundup4(size) == size);

    const header = Header {
        .object_id = registry.registry,
        .opcode = 0, // registry bind opcode
        .size = size,
    };
    return header;
}

fn registryBindMessage(allocator: Allocator, registry: *const Registry) ![]u8 {
    const header = registryBindMessageHeader(registry);

    const header_memory = try headerMemory(allocator, &header);
    defer allocator.free(header_memory);

    var name_bytes: [4]u8 = undefined;
    var interface_len_bytes: [4]u8 = undefined;
    var version_bytes: [4]u8 = undefined;
    var current_id_bytes: [4]u8 = undefined;

    const int_len: u32 = @intCast(registry.interface.len);
    std.mem.writeInt(u32, &name_bytes, registry.name, native_endian);
    std.mem.writeInt(u32, &interface_len_bytes, int_len,
        native_endian);
    std.mem.writeInt(u32, &version_bytes, registry.version, native_endian);
    std.mem.writeInt(u32, &current_id_bytes, registry.current_id,
        native_endian);

    const items = [_][]u8{
        header_memory,
        &name_bytes,
        &interface_len_bytes,
        registry.interface,
        &version_bytes,
        &current_id_bytes,
    };
    const result = try std.mem.concat(allocator, u8, &items);
    const len: u32 = @intCast(result.len);
    std.debug.assert(len == roundup4(len));
    return result;
}

fn bindRegistry(allocator: Allocator, registry: *const Registry,
        fd: i32) !void {
    const memory = try registryBindMessage(allocator, registry);
    defer allocator.free(memory);

    const send_size = try std.posix.send(fd, memory, std.os.linux.MSG.DONTWAIT);
    _ = send_size;
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

const page_size = std.heap.page_size_min;
const PoolData = []align(page_size)u8;

fn mapMemory(sh_fd: c_int, size: usize) !PoolData {
    const prot = std.posix.PROT.READ | std.posix.PROT.WRITE;
    const flags: std.posix.MAP = .{.TYPE = std.os.linux.MAP_TYPE.SHARED };
    const result = try std.posix.mmap(null, size, prot, flags, sh_fd, 0);
    return result;
}

const color_channels = 4;

const State = struct {
    wl_registry: u32 = undefined,
    width: u32 = 117,
    height: u32 = 150,
    stride: u32 = undefined,
    shm_pool_data: PoolData = undefined,
    sh_fd: c_int = undefined,
    shm_pool_size: u32 = undefined,
    wl_compositor: u32 = undefined,
    wl_surface: u32 = undefined,
    wl_shm: u32 = undefined,
    xdg_wm_base: u32 = undefined,
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
        state.wl_registry = current_id;

        const size = createRegistry(allocator, current_id, fd)
            catch unreachable;

        const sh_fd = try shmem.createSharedMemoryFile(allocator);
        state.sh_fd = sh_fd;

        try std.posix.ftruncate(sh_fd, size);

        const shm_pool_data = try mapMemory(sh_fd, size);

        state.shm_pool_data = shm_pool_data;

        while (true) {
            var read_array: [4096]u8 = undefined;
            var read_buf: []u8 = &read_array;
            _ = &read_buf;
            const read_bytes = try std.posix.recv(fd, read_buf, 0);
            if (read_bytes == -1) {
                std.posix.exit(1);
            }

            const buffer: []u8 = read_buf[0..read_bytes];

            std.debug.print("{}\n", .{read_bytes});
            //std.debug.print("{s}\n", .{read_buf});
            //std.debug.print("{s}\n", .{buffer});

            while (read_bytes > 0) {

                current_id = current_id + 1;

                try waylandHandleMessage(allocator, fd, &state,
                    buffer, current_id);

                const isBindPhaseComplete = state.wl_compositor != 0
                    and state.wl_shm != 0
                    and state.xdg_wm_base != 0
                    and state.wl_surface != 0;
                if (isBindPhaseComplete) {
                    //std.debug.assert(state.state == STATE_NONE);
                    std.debug.print("bind phase complete\n", .{});
                }
            }
        }
    }
}

const Event = enum {
    registry,
};

const Message = struct {
    object_id: u32,
    opcode: u16,
    announced_size: u16,
    event: Event,
};

fn messageResponse(msg: []u8, state: *State) Message {
    const object_id_bytes = msg[0..4];
    const object_id: u32 = std.mem.readInt(u32, object_id_bytes, native_endian);

    const opcode_bytes = msg[4..6];
    const opcode = std.mem.readInt(u16, opcode_bytes, native_endian);

    const announced_size_bytes = msg[6..8];
    const announced_size = std.mem.readInt(u16, announced_size_bytes,
        native_endian);
    std.debug.assert(roundup4(announced_size) <= announced_size);

    const event = eventType(object_id, opcode, state);
    const result = Message {
        .object_id = object_id,
        .opcode = opcode,
        .announced_size = announced_size,
        .event = event,
    };
    return result;
}

fn eventType(object_id: u32, opcode: u16, state: *State) Event {
    const is_registry_event = object_id == state.wl_registry
        and opcode == 0;
    var result: Event = undefined;
    if (is_registry_event) {
        result = Event.registry;
    }
    return result;
}

fn waylandHandleMessage(allocator: Allocator, fd: i32, state: *State,
        msg: []u8, current_id: u32) !void {
    std.debug.assert(msg.len >= 8);
    std.debug.print("msg len = {}\n", .{msg.len});

    const event = messageResponse(msg, state);

    if (event.event == Event.registry) {
        const registry = registryInfo(msg, state, current_id);
        state.wl_compositor = current_id;
        try bindRegistry(allocator, &registry, fd);
        std.debug.print("after bind\n", .{});

        const wl_shm_interface = "wl_shm";
        if (std.mem.eql(u8, wl_shm_interface, registry.non_padded_interface)) {
            state.wl_shm = current_id;
        }

        const xdg_wm_base = "xdg_wm_base";
        if (std.mem.eql(u8, xdg_wm_base, registry.non_padded_interface)) {
            state.xdg_wm_base = current_id;
        }

        const wl_compositor_interface = "wl_compositor";
        if (std.mem.eql(u8, wl_compositor_interface, registry.non_padded_interface)) {
            state.wl_compositor = current_id;
        }
        return;
    }
}

fn registryInfo(msg: []u8, state: *State, current_id: u32) Registry {
    const name_bytes = msg[8..12];
    const name = std.mem.readInt(u32, name_bytes, native_endian);

    const interface_len_bytes: *[4]u8 = msg[12..16];
    const interface_len = std.mem.readInt(u32, interface_len_bytes,
        native_endian);

    const interfaceZ = @as([*:0]u8, msg[16..16+interface_len-1 :0]);
    const interface_slice = std.mem.span(interfaceZ);

    const padded_interface_len = roundup4(interface_len);
    const padded_interface_slice = msg[16..16+padded_interface_len];
    const index: usize = 16+padded_interface_len;
    const version_bytes = msg[index..index+4][0..4];
    const version = std.mem.readInt(u32, version_bytes, native_endian);

    const registry = Registry {
        .registry = state.wl_registry,
        .name = name,
        .interface = padded_interface_slice,
        .non_padded_interface = interface_slice,
        .version = version,
        .current_id = current_id,
    };
    return registry;
}
