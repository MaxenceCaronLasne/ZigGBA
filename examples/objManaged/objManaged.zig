const gba = @import("gba");
const input = gba.input;
const display = gba.display;
const obj = gba.obj;

export var header linksection(".gbaheader") = gba.initHeader("OBJMNGD", "AOME", "00", 0);

// Simple colored square tiles (8x8 pixels, 4bpp)
// Each tile is 8 rows of 8 pixels, 4 bits per pixel = 32 bytes = 8 u32s
// In 4bpp, each u32 holds 8 pixels (2 pixels per byte)
const colored_tiles = [5][16]u16{
    // Red (palette index 1) - all pixels set to 1
    [16]u16{ 0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111,
             0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111, 0x1111 },
    // Green (palette index 2)
    [16]u16{ 0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222,
             0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222, 0x2222 },
    // Blue (palette index 3)
    [16]u16{ 0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333,
             0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333, 0x3333 },
    // Yellow (palette index 4)
    [16]u16{ 0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444,
             0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444, 0x4444 },
    // Magenta (palette index 5)
    [16]u16{ 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555,
             0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555, 0x5555 },
};

const palette = [16]gba.Color{
    gba.Color.rgb(0, 0, 0),       // 0: Transparent
    gba.Color.rgb(31, 0, 0),      // 1: Red (layer 0)
    gba.Color.rgb(0, 31, 0),      // 2: Green (layer 1)
    gba.Color.rgb(0, 0, 31),      // 3: Blue (layer 2)
    gba.Color.rgb(31, 31, 0),     // 4: Yellow (layer 3)
    gba.Color.rgb(31, 0, 31),     // 5: Magenta (layer 4)
    gba.Color.rgb(0, 0, 0),       // 6-15: Unused
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
    gba.Color.rgb(0, 0, 0),
};

fn loadSpriteData() void {
    // Load colored square tiles
    // Each 8x8 tile in 4bpp is 32 bytes = 16 u16s
    for (0..5) |i| {
        const tile_ptr: [*]volatile u16 = @ptrCast(@volatileCast(&obj.tile_ram[0][i * 2]));
        for (0..16) |j| {
            tile_ptr[j] = colored_tiles[i][j];
        }
    }

    // Load palette
    gba.mem.memcpy32(obj.palette, &palette, palette.len * 4);
}

// Track allocated sprites for each layer
var layer_sprites: [5]?*obj.Obj = [_]?*obj.Obj{null} ** 5;

pub export fn main() void {
    display.ctrl.* = .{
        .obj_mapping = .one_dimension,
        .obj = .enable,
    };

    loadSpriteData();

    // Initialize managed allocator
    obj.initManaged();

    // Allocate initial sprites, one per layer
    // Position them overlapping to demonstrate layer ordering
    // Layer 0 (red) should be on top, layer 4 (magenta) at the back
    for (0..5) |layer| {
        const sprite = obj.allocateManaged(@intCast(layer)) catch unreachable;
        sprite.* = .{
            // Offset each layer slightly to create a "staircase" effect
            // This makes all layers visible while showing z-ordering
            .x_pos = @intCast(100 + layer * 4),
            .y_pos = @intCast(70 + layer * 4),
            .palette_mode = .bpp_4,
        };
        sprite.setSize(.@"8x8");
        sprite.tile.index = @intCast(layer * 2);

        layer_sprites[layer] = sprite;
    }

    var frame: u32 = 0;

    while (true) {
        display.naiveVSync();
        _ = input.poll();

        frame += 1;

        // A button: Free layer 2 sprite (blue)
        if (input.isKeyJustPressed(.A)) {
            if (layer_sprites[2]) |sprite| {
                obj.freeManaged(sprite);
                layer_sprites[2] = null;
            }
        }

        // B button: Reallocate layer 2 sprite
        if (input.isKeyJustPressed(.B)) {
            if (layer_sprites[2] == null) {
                const sprite = obj.allocateManaged(2) catch {
                    // Out of memory - shouldn't happen in this example
                    continue;
                };
                sprite.* = .{
                    .x_pos = 100 + 2 * 4,
                    .y_pos = 70 + 2 * 4,
                    .palette_mode = .bpp_4,
                };
                sprite.setSize(.@"8x8");
                sprite.tile.index = 2 * 2;
                layer_sprites[2] = sprite;
            }
        }

        // L button: Free all odd layers (1, 3)
        if (input.isKeyJustPressed(.L)) {
            for ([_]usize{ 1, 3 }) |layer| {
                if (layer_sprites[layer]) |sprite| {
                    obj.freeManaged(sprite);
                    layer_sprites[layer] = null;
                }
            }
        }

        // R button: Reallocate all odd layers
        if (input.isKeyJustPressed(.R)) {
            for ([_]usize{ 1, 3 }) |layer| {
                if (layer_sprites[layer] == null) {
                    const sprite = obj.allocateManaged(@intCast(layer)) catch continue;
                    sprite.* = .{
                        .x_pos = @intCast(100 + layer * 4),
                        .y_pos = @intCast(70 + layer * 4),
                        .palette_mode = .bpp_4,
                    };
                    sprite.setSize(.@"8x8");
                    sprite.tile.index = @intCast(layer * 2);
                    layer_sprites[layer] = sprite;
                }
            }
        }

        // Animate sprites - make them move in a circle to test overlap
        // This creates dynamic overlapping to verify layer ordering
        for (0..5) |layer| {
            if (layer_sprites[layer]) |sprite| {
                // Slow down animation: update every 2 frames, smaller angle increments
                const angle: i32 = @intCast(@rem(frame / 2 + layer * 72, 360)); // Each layer offset by 72 degrees
                const radius: i32 = 25;

                // Simple integer approximation of circular motion
                // Using lookup would be better but this is simpler
                const x_center: i32 = 120;
                const y_center: i32 = 80;

                // Approximate sin/cos with a simple pattern
                const angle_mod: i32 = @rem(angle, 90);
                const quadrant: i32 = @divTrunc(angle, 90);

                var dx: i32 = if (angle_mod < 45) angle_mod else 90 - angle_mod;
                var dy: i32 = if (angle_mod < 45) 45 - angle_mod else angle_mod - 45;

                // Adjust sign based on quadrant
                if (quadrant == 1 or quadrant == 2) dx = -dx;
                if (quadrant == 2 or quadrant == 3) dy = -dy;

                sprite.x_pos = @intCast(x_center + @divTrunc(dx * radius, 45));
                sprite.y_pos = @intCast(y_center + @divTrunc(dy * radius, 45));
            }
        }

        // Update OAM with managed allocator
        // This will copy sprites in layer order: 0 (red) -> 4 (magenta)
        obj.updateManaged();
    }
}
