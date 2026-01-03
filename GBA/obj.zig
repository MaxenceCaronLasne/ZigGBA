//! Module for operations related to Object/Sprite memory
const std = @import("std");
const gba = @import("gba.zig");
const Color = gba.Color;
const Enable = gba.utils.Enable;
const I8_8 = gba.math.I8_8;
const display = gba.display;
const Priority = display.Priority;
const Tile = display.Tile;

/// Tile data for objects
pub const tile_ram: *volatile [2][512]Tile(.bpp_4) = @ptrFromInt(gba.mem.vram + 0x10000);

/// Obj and `Affine` data is interleaved but starts at the same place in memory.
const ObjAffineData = packed union {
    obj: *[128]Obj,
    affine: *[32]Affine,
};

/// The actual location of objects in VRAM
///
/// Should only be updated during VBlank, to avoid graphical glitches.
pub const oam: ObjAffineData = .{ .obj = @ptrFromInt(gba.mem.oam) };

var buffer_inner: [128]Obj align(8) = @splat(.{});

/// A buffer that can be updated at any time, then copied
/// to OAM during VBlank
pub var obj_affine_buffer: ObjAffineData = .{ .obj = &buffer_inner };

var sort_keys: [128]u32 = @splat(0);

// TODO: Could make this ?u7 I think.
var sort_ids: [128]u8 = @splat(0);

// === Managed Allocator Infrastructure ===

/// Metadata for each OAM slot to support managed allocation
const ObjMetadata = struct {
    allocated: bool = false,
    layer: u3 = 0,              // Only valid when allocated
    next: ?u7 = null,           // Free list (when unallocated) OR layer list (when allocated)
};

/// Allocation mode: simple (legacy) or managed (new)
const AllocatorMode = enum { simple, managed };

/// Metadata for all 128 OAM slots (~512 bytes)
var metadata: [128]ObjMetadata = undefined;

/// Head of the free list
var free_list_head: ?u7 = null;

/// Head of each layer's allocated object list
var layer_heads: [5]?u7 = [_]?u7{null} ** 5;

/// Total number of allocated objects
var allocated_count: u8 = 0;

/// Number of objects per layer (for stats/debugging)
var layer_counts: [5]u8 = [_]u8{0} ** 5;

/// Current allocation mode
var current_mode: AllocatorMode = .simple;

// === Helper Functions ===

/// Calculate index from object pointer
fn getIndexFromPointer(obj_ptr: *Obj) u7 {
    const ptr_addr = @intFromPtr(obj_ptr);
    const base_addr = @intFromPtr(&buffer_inner[0]);

    std.debug.assert(ptr_addr >= base_addr);
    std.debug.assert(ptr_addr < base_addr + @sizeOf(Obj) * 128);

    const offset = ptr_addr - base_addr;
    const index = offset / @sizeOf(Obj);

    std.debug.assert(index < 128);
    return @intCast(index);
}

/// Assert that we're in managed mode
fn assertManagedMode() void {
    if (current_mode != .managed) {
        @panic("Must call initManaged() before using managed API");
    }
}

/// Initialize the managed allocation system
pub fn initManaged() void {
    // Initialize all metadata entries
    for (0..128) |i| {
        metadata[i] = .{
            .allocated = false,
            .layer = 0,
            .next = if (i < 127) @as(?u7, @intCast(i + 1)) else null,
        };
    }

    // Initialize free list (all slots available)
    free_list_head = 0;

    // Initialize layer lists (all empty)
    layer_heads = [_]?u7{null} ** 5;

    // Reset counters
    allocated_count = 0;
    layer_counts = [_]u8{0} ** 5;

    // Switch to managed mode
    current_mode = .managed;
}

/// Get the number of allocated objects (total)
pub fn getAllocatedCount() u8 {
    assertManagedMode();
    return allocated_count;
}

/// Get the number of objects in a specific layer
pub fn getLayerCount(layer: u3) u8 {
    assertManagedMode();
    std.debug.assert(layer <= 4);
    return layer_counts[layer];
}

pub fn shellSort(count: u8) void {
    var inc: u8 = 1;
    while (inc <= count) : (inc += 1)
        inc *= 3;
    while (true) {
        inc /= 3;
        for (inc..count) |i| {
            var j = i;
            const key_0 = sort_keys[sort_ids[i]];
            while (j >= inc and sort_keys[sort_ids[j - inc]] > key_0) : (j -= inc) {
                sort_ids[j] = sort_ids[j - inc];
            }
            sort_ids[j] = sort_ids[i];
        }
        if (inc <= 1) break;
    }
}

pub const palette: *Color.Palette = @ptrFromInt(gba.mem.palette + 0x200);

var current_attr: usize = 0;

// === Managed Allocation API ===

/// Allocate an object in the specified layer (0=front, 4=back)
pub fn allocateManaged(layer: u3) !*Obj {
    assertManagedMode();
    std.debug.assert(layer <= 4);

    // Check if free list has available slots
    const index = free_list_head orelse return error.OutOfMemory;

    // Pop from free list
    free_list_head = metadata[index].next;

    // Mark as allocated
    metadata[index].allocated = true;
    metadata[index].layer = layer;

    // Push to layer's linked list (at head)
    metadata[index].next = layer_heads[layer];
    layer_heads[layer] = index;

    // Update counters
    allocated_count += 1;
    layer_counts[layer] += 1;

    // Return pointer to the object
    return &buffer_inner[index];
}

/// Free an allocated object
pub fn freeManaged(obj_ptr: *Obj) void {
    assertManagedMode();

    const index = getIndexFromPointer(obj_ptr);

    // Prevent double-free
    if (!metadata[index].allocated) {
        @panic("Double-free detected: object is not allocated");
    }

    const layer = metadata[index].layer;

    // Remove from layer's linked list
    // Need to find predecessor to update its next pointer
    if (layer_heads[layer] == index) {
        // Object is at head of layer list
        layer_heads[layer] = metadata[index].next;
    } else {
        // Scan layer list to find predecessor
        var prev_idx = layer_heads[layer];
        while (prev_idx) |prev| {
            if (metadata[prev].next == index) {
                // Found predecessor, update its next pointer
                metadata[prev].next = metadata[index].next;
                break;
            }
            prev_idx = metadata[prev].next;
        }
    }

    // Mark as unallocated
    metadata[index].allocated = false;

    // Push to free list (at head)
    metadata[index].next = free_list_head;
    free_list_head = index;

    // Hide the sprite in the buffer
    buffer_inner[index].affine_mode = .hidden;

    // Update counters
    allocated_count -= 1;
    layer_counts[layer] -= 1;
}

pub const Obj = packed struct {
    pub const GfxMode = enum(u2) {
        normal,
        alpha_blend,
        obj_window,
    };

    pub const Shape = enum(u2) {
        square,
        wide,
        tall,
    };

    /// WIDTHxHEIGHT
    pub const Size = enum(u4) {
        // Square
        @"8x8",
        @"16x16",
        @"32x32",
        @"64x64",
        // Wide
        @"16x8",
        @"32x8",
        @"32x16",
        @"64x32",
        // Tall
        @"8x16",
        @"8x32",
        @"16x32",
        @"32x64",

        const Parts = packed struct(u4) {
            size: u2,
            shape: Shape,
        };

        fn parts(self: Size) Parts {
            return @bitCast(@intFromEnum(self));
        }
    };

    const AffineMode = enum(u2) {
        /// Normal rendering, uses `normal` transform controls
        normal,
        /// Uses `affine` transform controls
        affine,
        /// Disables rendering
        hidden,
        /// Uses `affine` transform controls, and also allows affine
        /// transformations to use twice the sprite's dimensions.
        affine_double,
    };

    /// Used to set transformation effects on an object
    const Transformation = packed union {
        flip: packed struct(u5) {
            _: u3 = 0,
            h: bool = false,
            v: bool = false,
        },
        affine_index: u5,
    };

    /// Many docs treat this as a single 10 bit number, but the most significant bit
    /// corresponds to which of the last two charblocks the index is into.
    ///
    /// It can still be assigned to with a u10 via `@bitCast`
    pub const TileInfo = packed struct(u10) {
        /// The index into tile memory in VRAM. Indexing is always based on 4bpp tiles
        ///
        /// (for 8bpp tiles, only even indices are used, so `logical_index << 1` works)
        index: u9 = 0,
        /// Selects between the low and high block of obj VRAM
        ///
        /// In bitmap modes, this must be 1, since the lower block is occupied by the bitmap.
        block: u1 = 0,
    };

    /// For normal sprites, the top; for affine sprites, the center
    y_pos: u8 = 0,
    affine_mode: AffineMode = .normal,
    mode: GfxMode = .normal,
    /// Enables mosaic effects on this object
    mosaic: Enable = .disable,
    palette_mode: Color.Bpp = .bpp_4,
    /// Used in combination with size, see `setSize`
    shape: Shape = .square,
    /// For normal sprites, the left side; for affine sprites, the center
    x_pos: u9 = 0,
    /// For normal sprites: whether to flip horizontally and/or vertically
    ///
    /// For affine sprites: the 5 bit index into the affine data
    transform: Transformation = .{ .flip = .{} },
    /// Used in combination with shape, see `setSize`
    size: u2 = 0,
    tile: TileInfo = .{},
    priority: Priority = .highest,
    palette: u4 = 0,
    // This field is used to store the Affine data.
    // TODO: should maybe be undefined or left out?
    // _: I8_8 = undefined,

    /// Sets size and shape to the appropriate values for the given object size.
    pub fn setSize(self: *Obj, size: Size) void {
        const parts = size.parts();
        self.size = parts.size;
        self.shape = parts.shape;
    }

    pub fn setPosition(self: *Obj, x: u9, y: u8) void {
        self.x_pos = x;
        self.y_pos = y;
    }

    pub fn getAffine(self: Obj) *Affine {
        return &obj_affine_buffer.affine[self.transform.affine_index];
    }

    pub fn flipH(self: *Obj) void {
        switch (self.affine_mode) {
            .normal => self.transform.flip.h = !self.transform.flip.h,
            // TODO: implement affine flips
            .affine, .affine_double => {},
            else => {},
        }
    }

    pub fn flipV(self: *Obj) void {
        switch (self.affine_mode) {
            .normal => self.transform.flip.v = !self.transform.flip.v,
            // TODO: implement affine flips
            .affine, .affine_double => {},
            else => {},
        }
    }

    pub fn rotate180(self: *Obj) void {
        switch (self.affine_mode) {
            .normal => self.transform.flip = .{
                .h = !self.transform.flip.h,
                .v = !self.transform.flip.v,
            },
            // TODO: implement affine flips
            .affine, .affine_double => {},
            else => {},
        }
    }
};

pub const Affine = packed struct {
    _0: u48,
    pa: I8_8 = I8_8.fromInt(1),
    _1: u48,
    pb: I8_8 = .{},
    _2: u48,
    pc: I8_8 = .{},
    _3: u48,
    pd: I8_8 = I8_8.fromInt(1),

    pub fn set(self: *Affine, pa: I8_8, pb: I8_8, pc: I8_8, pd: I8_8) void {
        self.pa = pa;
        self.pb = pb;
        self.pc = pc;
        self.pd = pd;
    }

    pub fn setIdentity(self: *Affine) void {
        self.set(I8_8.fromInt(1), .{}, .{}, I8_8.fromInt(1));
    }
};

/// Copy all allocated objects to OAM in layer order (managed mode)
///
/// Walks the per-layer linked lists and copies objects to hardware OAM
/// in order: layer 0 (front) → layer 4 (back).
/// Remaining OAM slots are hidden.
///
/// Should only be called during VBlank.
pub fn updateManaged() void {
    assertManagedMode();

    var oam_idx: u8 = 0;

    // Walk each layer's linked list in order: 0 (front) → 4 (back)
    for (0..5) |layer| {
        var obj_idx: ?u7 = layer_heads[layer];
        while (obj_idx) |idx| {
            oam.obj[oam_idx] = obj_affine_buffer.obj[idx];
            oam_idx += 1;
            obj_idx = metadata[idx].next;
        }
    }

    // Hide remaining OAM slots
    for (oam_idx..128) |i| {
        oam.obj[i].affine_mode = .hidden;
    }
}

// TODO: Better abstraction for this, maybe even using the `std.Allocator` API
pub fn allocate() *Obj {
    const result = &obj_affine_buffer.obj[current_attr];
    current_attr += 1;
    return result;
}

/// Writes the object attribute buffer to OAM data.
///
/// In simple mode: copies `count` objects from buffer to OAM and resets counter.
/// In managed mode: dispatches to `updateManaged()` and ignores `count` parameter.
///
/// Should only be done during VBlank
pub fn update(count: usize) void {
    if (current_mode == .managed) {
        updateManaged();
        return;
    }

    // Simple mode: original behavior
    for (obj_affine_buffer.obj[0..count], oam.obj[0..count]) |buf_entry, *oam_entry| {
        oam_entry.* = buf_entry;
    }
    current_attr = 0;
}
