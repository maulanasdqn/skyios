// SkyAdrenoMetal internals shared by the device and the object classes.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>

// user client of SkyAdrenoAccel / SkyAdrenoMetalAccel (xnu 0109)
enum { SKY_INFO, SKY_ALLOC, SKY_FREE, SKY_SUBMIT, SKY_WAIT, SKY_LOG, SKY_IMPORT };

extern io_connect_t sky_conn;
void sky_log(const char *fmt, ...) __printflike(1, 2);

// one GPU allocation: kernel handle, GPU address, CPU mapping
typedef struct {
    uint64_t handle, iova, size;
    void *cpu;
    uint64_t pool; // size class of the kernel allocation (SkyObjects.m pool)
} SkyMem;

BOOL sky_alloc(uint64_t size, SkyMem *m);
void sky_free(SkyMem *m);

// Base of every object class: selectors nobody wrote yet are logged once
// and answer 0/nil instead of raising.
@interface SkyObject : NSObject
@end

@interface SkyBuffer : SkyObject <MTLBuffer>
- (instancetype)initWithDevice:(id<MTLDevice>)device length:(NSUInteger)length options:(MTLResourceOptions)options;
@property (readonly) SkyMem mem;
@end

@interface SkyCommandQueue : SkyObject <MTLCommandQueue>
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@end

void sky_record_init(void);
void sky_log_once(NSString *line);
id sky_render_encoder(id<MTLDevice> dev, MTLRenderPassDescriptor *d);
// Metal colour attachment blend state -> RB_MRT[0].CONTROL / BLEND_CONTROL
void sky_blend_state(MTLRenderPipelineColorAttachmentDescriptor *c, uint32_t *control, uint32_t *blend);
// a drawing encoder (SkyRender.m) appending to `stream`, or nil when the pass
// is outside what it supports
id sky_draw_encoder(id<MTLDevice> dev, MTLRenderPassDescriptor *d, NSMutableData *stream, id owner);

// vertex descriptor of a render pipeline (MTLVertexFormat, byte offset and
// buffer index per attribute; stride per buffer, 0: unused)
typedef struct {
    uint32_t fmt[8], off[8], buf[8];
    uint32_t stride[31];
} SkyVertexDesc;

// MTLSamplerDescriptor -> A6XX_TEX_SAMP_0 (filters, wraps)
uint32_t sky_sampler_word(id<MTLSamplerState> s);
// the sampler takes pixel coordinates (A6XX_TEX_SAMP_1 UNNORM_COORDS)
BOOL sky_sampler_unnorm(id<MTLSamplerState> s);
// bytes per pixel of the texture formats the Adreno path samples (0: none)
NSUInteger sky_tex_bpe(MTLPixelFormat f);
// one row of a w x h level: bytes in it and rows in the level (pixels, or
// 4x4 blocks of 16 bytes for ASTC 4x4); NO for formats not served
// CoreAnimation's private pixel format 550 (IOSurface 'b3a8', 4 bytes per
// pixel): the targets of its blur passes. Handled as BGRA8Unorm (probe121-126:
// rejected, so blurs and materials were never drawn).
#define SkyPixelFormatB3A8 ((MTLPixelFormat)550)
// BGR10_XR ('w30r', 554/555): CA's backdrop captures. Stored as A6XX
// 10_10_10_2 UNORM: the extended range is clamped, written and read alike.
static inline BOOL sky_is_xr10(MTLPixelFormat f) {
    return f == MTLPixelFormatBGR10_XR || f == MTLPixelFormatBGR10_XR_sRGB;
}
static inline BOOL sky_is_bgra8(MTLPixelFormat f) {
    return f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB || f == SkyPixelFormatB3A8;
}

BOOL sky_tex_layout(MTLPixelFormat f, NSUInteger w, NSUInteger h, NSUInteger *rowBytes, NSUInteger *rows);

// methods copied into the runtime-made _MTLDevice subclass
@interface SkyDeviceMethods : NSObject
@end
