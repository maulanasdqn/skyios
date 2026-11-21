// Metal objects on the Adreno 618: buffers in GPU memory from the kernel,
// command buffers built as PM4 streams and run as indirect buffers
// (cpuser.rs), blit encoder fills and copies with the 2D engine (the
// sequence of the kernel's cp.rs solid_fill / blit_pass).

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

#import "SkyMetal.h"
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>

io_connect_t sky_conn;
extern uint32_t sky_draw_id;
void sky_progress(uint32_t *cp, uint32_t *done);

void sky_log(const char *fmt, ...) {
    char text[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);
    if (sky_conn)
        IOConnectCallMethod(sky_conn, SKY_LOG, NULL, 0, text, strlen(text), NULL, NULL, NULL, NULL);
}

// kernel allocations are expensive to make and to free (freeing maps and
// unmaps GPU pages and waits for the GPU to go idle): freed memory goes to a
// small pool and is handed out again, zeroed, for requests that fit
// The pool keeps GPU address space mapped (128 MiB for all of a client's
// buffers and imported surfaces): only small allocations, 8 MiB in total
// (probe94-97: an unbounded pool ran imports out of space, kIOReturnNoSpace,
// and the skipped draws broke the home screen).
// A freed allocation may still be read by submitted work (a blit encoder does
// not retain its buffers, and freeing in the kernel used to wait for the GPU):
// it is reused only once the GPU has completed every submit made before the free
enum { POOL_MAX = 24 };
static const BOOL pool_on = YES;
uint64_t sky_seq_submitted, sky_seq_completed;
static SkyMem pool[POOL_MAX];
static uint64_t pool_seq[POOL_MAX];
static uint64_t pool_bytes;
// small entries only: reusing a framebuffer-fetch scratch (11 MiB) through
// the pool lost the lock screen text again (probe103), as a shared one did
#define POOL_ENTRY_MAX (1ULL << 20)
#define POOL_BYTES_MAX (8ULL << 20)
static int pool_n;
static os_unfair_lock pool_lock = OS_UNFAIR_LOCK_INIT;

static uint64_t pool_size(uint64_t size) {
    if (size > (1ULL << 20))
        return (size + 0x3fff) & ~0x3fffULL; // large: exact size, no rounding up
    uint64_t r = 65536;
    while (r < size)
        r <<= 1;
    return r;
}

BOOL sky_alloc(uint64_t size, SkyMem *m) {
    uint64_t want = pool_size(size);
    os_unfair_lock_lock(&pool_lock);
    uint64_t done = __atomic_load_n(&sky_seq_completed, __ATOMIC_ACQUIRE);
    for (int i = 0; i < pool_n; i++) {
        if (pool[i].size == want && pool_seq[i] <= done) {
            *m = pool[i];
            pool_n--;
            pool_bytes -= want;
            pool[i] = pool[pool_n];
            pool_seq[i] = pool_seq[pool_n];
            os_unfair_lock_unlock(&pool_lock);
            if (size <= (1ULL << 20)) // large reuses are scratch the GPU overwrites
                memset(m->cpu, 0, (size_t)size);
            m->size = size;
            m->pool = want;
            return YES;
        }
    }
    os_unfair_lock_unlock(&pool_lock);
    uint64_t out[3] = {0};
    uint32_t n = 3;
    kern_return_t kr = IOConnectCallScalarMethod(sky_conn, SKY_ALLOC, &want, 1, out, &n);
    if (kr != KERN_SUCCESS) {
        static int nfail;
        if (nfail++ < 3)
            sky_log("sky_alloc %llu FAILED: kr=%#x conn=%#x n=%u", size, kr, sky_conn, n);
        return NO;
    }
    m->handle = out[0];
    m->iova = out[1];
    m->cpu = (void *)(uintptr_t)out[2];
    m->size = size;
    m->pool = want;
    return YES;
}

void sky_free(SkyMem *m) {
    if (!m->handle)
        return;
    os_unfair_lock_lock(&pool_lock);
    if (pool_on && pool_n < POOL_MAX && m->pool && m->pool <= POOL_ENTRY_MAX &&
        pool_bytes + m->pool <= POOL_BYTES_MAX) {
        pool_bytes += m->pool;
        pool[pool_n] = *m;
        pool[pool_n].size = m->pool;
        pool_seq[pool_n] = __atomic_load_n(&sky_seq_submitted, __ATOMIC_ACQUIRE);
        pool_n++;
        os_unfair_lock_unlock(&pool_lock);
    } else {
        os_unfair_lock_unlock(&pool_lock);
        IOConnectCallScalarMethod(sky_conn, SKY_FREE, &m->handle, 1, NULL, NULL);
    }
    m->handle = 0;
}

static id sky_nil(id self, SEL _cmd) {
    return nil;
}

@implementation SkyObject
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet *seen;
    NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(self), sel_getName(sel)];
    os_unfair_lock_lock(&lock);
    if (!seen)
        seen = [NSMutableSet new];
    BOOL first = ![seen containsObject:key];
    [seen addObject:key];
    os_unfair_lock_unlock(&lock);
    if (first)
        sky_log("missing -[%s %s]", class_getName(self), sel_getName(sel));
    class_addMethod(self, sel, (IMP)sky_nil, "@@:");
    return YES;
}
@end

static CFTimeInterval sky_now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

#pragma mark - buffers

@implementation SkyBuffer {
    id<MTLDevice> _device;
    MTLResourceOptions _options;
    NSString *_label;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device length:(NSUInteger)length options:(MTLResourceOptions)options {
    if (!(self = [super init]))
        return nil;
    if (!sky_alloc(length ? length : 1, &_mem))
        return nil;
    _mem.size = length;
    _device = device;
    _options = options;
    return self;
}

- (void)dealloc {
    // Metal buffers go back to the kernel, not the pool: with them pooled the
    // home screen broke (probe94, probe96 with the completion gate); the free
    // also waits for the GPU, which CA's buffer reuse seems to rely on
    _mem.pool = 0;
    sky_free(&_mem);
}

- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void *)contents { return _mem.cpu; }
- (NSUInteger)length { return _mem.size; }
- (uint64_t)gpuAddress { return _mem.iova; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift; }
- (MTLCPUCacheMode)cpuCacheMode { return _options & MTLResourceCPUCacheModeMask; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (void)didModifyRange:(NSRange)range {}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return MTLPurgeableStateNonVolatile; }
- (NSUInteger)allocatedSize { return (_mem.size + 0x3fff) & ~0x3fffULL; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)o bytesPerRow:(NSUInteger)bpr {
    return [self newTextureWithDescriptor:d offset:o bytesPerRow:bpr bytesPerImage:0];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)o bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    extern id sky_texture_from_buffer(id<MTLDevice>, MTLTextureDescriptor *, id<MTLBuffer> buf, NSUInteger off, NSUInteger bpr);
    return sky_texture_from_buffer(_device, d, self, o, bpr);
}
- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)o bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    return [self newTextureWithDescriptor:d offset:o bytesPerRow:bpr bytesPerImage:bpi];
}
@end

#pragma mark - PM4

static uint32_t parity(uint32_t v) {
    return (0x9669 >> (0xf & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1;
}
static uint32_t pkt4(uint32_t reg, uint32_t cnt) {
    return 0x40000000 | (parity(reg) << 27) | (reg << 8) | (parity(cnt) << 7) | cnt;
}
static uint32_t pkt7(uint32_t op, uint32_t cnt) {
    return 0x70000000 | (parity(op) << 23) | (op << 16) | (parity(cnt) << 15) | cnt;
}

#define CP_WAIT_FOR_IDLE 0x26
#define CP_BLIT 0x2c
#define CP_MEM_WRITE 0x3d
#define CP_EVENT_WRITE 0x46
#define CP_MEM_TO_MEM 0x73
#define FMT6_8_8_8_8_UNORM 0x30
#define CCU_CNTL_BYPASS ((0x10000 >> 12) << 23)
#define ROW_PX 1024 // 2D engine view of a buffer: rows of 1024 RGBA8 pixels
#define ROW_BYTES (ROW_PX * 4)

@interface SkyStream : NSObject {
@public
    NSMutableData *data;
}
@end

@implementation SkyStream
- (instancetype)init {
    if ((self = [super init]))
        data = [NSMutableData new];
    return self;
}
- (void)emit:(uint32_t)v {
    [data appendBytes:&v length:4];
}
- (void)reg:(uint32_t)r values:(const uint32_t *)v count:(uint32_t)n {
    [self emit:pkt4(r, n)];
    for (uint32_t i = 0; i < n; i++)
        [self emit:v[i]];
}
- (void)reg:(uint32_t)r value:(uint32_t)v {
    [self reg:r values:&v count:1];
}
- (void)event:(uint32_t)ev {
    [self emit:pkt7(CP_EVENT_WRITE, 1)];
    [self emit:ev];
}
- (void)wfi {
    [self emit:pkt7(CP_WAIT_FOR_IDLE, 0)];
}
- (uint32_t)dwords {
    return (uint32_t)(data.length / 4);
}

// 2D engine set-up shared by fills and copies (cp.rs blit_locked)
- (void)begin2D:(BOOL)solid {
    [self event:0x18]; // PC_CCU_INVALIDATE_DEPTH
    [self event:0x19]; // PC_CCU_INVALIDATE_COLOR
    [self wfi];
    [self reg:0x8e07 value:CCU_CNTL_BYPASS];
    uint32_t fmt = FMT6_8_8_8_8_UNORM;
    uint32_t blt = (solid ? 1 << 7 : 0) | (fmt << 8) | (0xf << 20);
    [self reg:0x8c00 value:blt];                    // RB_A2D_BLT_CNTL
    [self reg:0x8400 value:blt];                    // GRAS_A2D_BLT_CNTL
    [self reg:0xacc0 value:(fmt << 3) | (0xf << 12)]; // SP_A2D_OUTPUT_INFO
    [self reg:0x8c01 value:0];                      // RB_A2D_PIXEL_CNTL
    uint32_t zero[3] = {0, 0, 0};
    [self reg:0x8c20 values:zero count:3];          // RB_A2D_DEST_FLAG_BUFFER_BASE
}

- (void)dest:(uint64_t)dst width:(uint32_t)w rows:(uint32_t)h {
    uint32_t info[4] = {FMT6_8_8_8_8_UNORM, (uint32_t)dst, (uint32_t)(dst >> 32), ROW_BYTES >> 6};
    [self reg:0x8c17 values:info count:4];           // RB_A2D_DEST_BUFFER_INFO..PITCH
    uint32_t tl[2] = {0, (w - 1) | ((h - 1) << 16)};
    [self reg:0x8405 values:tl count:2];             // GRAS_A2D_DEST_TL/BR
}

- (void)blit {
    [self event:0x3f]; // FD_LABEL
    [self wfi];
    [self emit:pkt7(CP_BLIT, 1)];
    [self emit:3]; // BLIT_OP_SCALE
    [self wfi];
}

// whole 1024-pixel rows of [dst, dst + rows * 4096), dst 64-byte aligned
- (void)fillRows:(uint64_t)dst rows:(uint32_t)rows byte:(uint8_t)v {
    [self begin2D:YES];
    uint32_t rgba[4] = {v, v, v, v};
    [self reg:0x8c2c values:rgba count:4]; // RB_A2D_CLEAR_COLOR_DW0..3
    for (uint32_t done = 0; done < rows;) {
        uint32_t n = MIN(rows - done, 0x4000u);
        [self dest:dst + (uint64_t)done * ROW_BYTES width:ROW_PX rows:n];
        [self blit];
        done += n;
    }
}

- (void)copyRows:(uint64_t)src to:(uint64_t)dst rows:(uint32_t)rows {
    [self begin2D:NO];
    for (uint32_t done = 0; done < rows;) {
        uint32_t n = MIN(rows - done, 0x4000u);
        uint64_t s = src + (uint64_t)done * ROW_BYTES;
        // TPL1_A2D_SRC_TEXTURE_INFO: RGBA8 linear WZYX (+unk20/22), size, base, pitch
        uint32_t tex[5] = {FMT6_8_8_8_8_UNORM | (1 << 20) | (1 << 22), ROW_PX | (n << 15), (uint32_t)s,
                           (uint32_t)(s >> 32), (ROW_BYTES >> 6) << 9};
        [self reg:0xb4c0 values:tex count:5];
        uint32_t zero[3] = {0, 0, 0};
        [self reg:0xb4ca values:zero count:3];
        uint32_t sc[4] = {0, (ROW_PX - 1) << 8, 0, (n - 1) << 8};
        [self reg:0x8401 values:sc count:4];         // GRAS_A2D_SRC_XMIN..YMAX
        [self dest:dst + (uint64_t)done * ROW_BYTES width:ROW_PX rows:n];
        [self blit];
        done += n;
    }
}

- (void)writeWord:(uint64_t)dst value:(uint32_t)v {
    [self emit:pkt7(CP_MEM_WRITE, 3)];
    [self emit:(uint32_t)dst];
    [self emit:(uint32_t)(dst >> 32)];
    [self emit:v];
}

- (void)copyWord:(uint64_t)src to:(uint64_t)dst {
    [self emit:pkt7(CP_MEM_TO_MEM, 5)];
    [self emit:0];
    [self emit:(uint32_t)dst];
    [self emit:(uint32_t)(dst >> 32)];
    [self emit:(uint32_t)src];
    [self emit:(uint32_t)(src >> 32)];
}
@end

#pragma mark - blit encoder

@interface SkyBlitEncoder : SkyObject <MTLBlitCommandEncoder>
- (instancetype)initWithStream:(SkyStream *)s buffer:(id<MTLCommandBuffer>)cb;
@end

@implementation SkyBlitEncoder {
    SkyStream *_s;
    __weak id<MTLCommandBuffer> _cb;
    NSString *_label;
    NSMutableArray *_keep;
}

- (instancetype)initWithStream:(SkyStream *)s buffer:(id<MTLCommandBuffer>)cb {
    if ((self = [super init])) {
        _s = s;
        _cb = cb;
        _keep = [NSMutableArray new];
        // buffers of the copies live as long as the command buffer, not the
        // encoder: the GPU runs the copies after commit
        objc_setAssociatedObject(cb, (__bridge const void *)self, _keep, OBJC_ASSOCIATION_RETAIN);
    }
    return self;
}

- (id<MTLDevice>)device { return _cb.device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (void)endEncoding {}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}

// 4-byte aligned head and tail by CP_MEM_WRITE / CP_MEM_TO_MEM, whole
// 4096-byte rows (64-byte aligned start) by the 2D engine
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    SkyBuffer *b = (SkyBuffer *)buffer;
    [_keep addObject:b];
    uint64_t a = b.mem.iova + range.location, end = a + range.length;
    uint8_t *cpu = (uint8_t *)b.mem.cpu;
    if ((a & 3) || (end & 3)) {
        // unaligned: done on the CPU at encode time (ordering not kept)
        memset(cpu + range.location, value, range.length);
        return;
    }
    uint32_t word = value * 0x01010101u;
    while (a < end && ((a & 63) || end - a < ROW_BYTES)) {
        [_s writeWord:a value:word];
        a += 4;
    }
    uint32_t rows = (uint32_t)((end - a) / ROW_BYTES);
    if (rows) {
        [_s fillRows:a rows:rows byte:value];
        a += (uint64_t)rows * ROW_BYTES;
    }
    for (; a < end; a += 4)
        [_s writeWord:a value:word];
}

- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst
     destinationOffset:(NSUInteger)doff size:(NSUInteger)size {
    SkyBuffer *s = (SkyBuffer *)src, *d = (SkyBuffer *)dst;
    [_keep addObject:s];
    [_keep addObject:d];
    uint64_t sa = s.mem.iova + so, da = d.mem.iova + doff;
    if ((sa & 3) || (da & 3) || (size & 3)) {
        memmove((uint8_t *)d.mem.cpu + doff, (uint8_t *)s.mem.cpu + so, size);
        return;
    }
    uint64_t done = 0;
    if (!(sa & 63) && !(da & 63) && size >= ROW_BYTES) {
        uint32_t rows = (uint32_t)(size / ROW_BYTES);
        [_s copyRows:sa to:da rows:rows];
        done = (uint64_t)rows * ROW_BYTES;
    }
    for (; done < size; done += 4)
        [_s copyWord:sa + done to:da + done];
}

// buffer -> texture, level 0 of IOSurface-backed textures (ASTC images
// among them): replaceRegion on the CPU at encode time (ordering not kept,
// like copyFromTexture below)
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)sbpr
    sourceBytesPerImage:(NSUInteger)sbpi sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)o {
    sky_log_once([NSString stringWithFormat:@"blit buffer->texture fmt %lu level %lu", (unsigned long)dst.pixelFormat,
                                            (unsigned long)dl]);
    if (!src || !dst || ds || dl)
        return;
    [dst replaceRegion:MTLRegionMake2D(o.x, o.y, sz.width, sz.height) mipmapLevel:0
             withBytes:(const uint8_t *)src.contents + so bytesPerRow:sbpr];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)sbpr
    sourceBytesPerImage:(NSUInteger)sbpi sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)o
                options:(MTLBlitOption)opt {
    [self copyFromBuffer:src sourceOffset:so sourceBytesPerRow:sbpr sourceBytesPerImage:sbpi sourceSize:sz
               toTexture:dst destinationSlice:ds destinationLevel:dl destinationOrigin:o];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz
              toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
      destinationOrigin:(MTLOrigin)dsto {
    // IOSurface-backed 4-byte textures, level 0: done on the CPU at encode
    // time (ordering not kept), like the unaligned fillBuffer case
    IOSurfaceRef s = [(id)src respondsToSelector:@selector(iosurface)] ? src.iosurface : NULL;
    IOSurfaceRef d = [(id)dst respondsToSelector:@selector(iosurface)] ? dst.iosurface : NULL;
    if (!s || !d || sl || dl || ss || ds || IOSurfaceGetBytesPerElement(s) != 4 || IOSurfaceGetBytesPerElement(d) != 4 ||
        so.x + sz.width > IOSurfaceGetWidth(s) || so.y + sz.height > IOSurfaceGetHeight(s) ||
        dsto.x + sz.width > IOSurfaceGetWidth(d) || dsto.y + sz.height > IOSurfaceGetHeight(d)) {
        sky_log_once(@"blit copyFromTexture: unsupported textures (no-op)");
        return;
    }
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    if (d != s)
        IOSurfaceLock(d, 0, NULL);
    size_t sb = IOSurfaceGetBytesPerRow(s), db = IOSurfaceGetBytesPerRow(d);
    const uint8_t *sp = (const uint8_t *)IOSurfaceGetBaseAddress(s) + so.y * sb + so.x * 4;
    uint8_t *dp = (uint8_t *)IOSurfaceGetBaseAddress(d) + dsto.y * db + dsto.x * 4;
    for (NSUInteger y = 0; y < sz.height; ++y)
        memmove(dp + y * db, sp + y * sb, sz.width * 4);
    if (d != s)
        IOSurfaceUnlock(d, 0, NULL);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)tex {
    sky_log_once(@"blit generateMipmaps stub (no-op)");
}
@end

#pragma mark - command buffers

@interface SkyCommandBuffer : SkyObject <MTLCommandBuffer>
- (instancetype)initWithQueue:(SkyCommandQueue *)q;
@end

@implementation SkyCommandBuffer {
    SkyCommandQueue *_queue;
    SkyStream *_s;
    NSString *_label;
    NSMutableArray *_completed, *_scheduled;
    SkyMem _ib;
    uint64_t _seq;
    MTLCommandBufferStatus _status;
    dispatch_semaphore_t _done;
    NSError *_error;
    CFTimeInterval _t0, _t1;
}

- (instancetype)initWithQueue:(SkyCommandQueue *)q {
    if ((self = [super init])) {
        _queue = q;
        _s = [SkyStream new];
        _completed = [NSMutableArray new];
        _scheduled = [NSMutableArray new];
        _done = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)dealloc {
    sky_free(&_ib);
}

- (id<MTLDevice>)device { return _queue.device; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferStatus)status { return _status; }
- (NSError *)error { return _error; }
- (CFTimeInterval)GPUStartTime { return _t0; }
- (CFTimeInterval)GPUEndTime { return _t1; }
- (CFTimeInterval)kernelStartTime { return _t0; }
- (CFTimeInterval)kernelEndTime { return _t1; }
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)enqueue {
    if (_status < MTLCommandBufferStatusEnqueued)
        _status = MTLCommandBufferStatusEnqueued;
}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block { [_completed addObject:[block copy]]; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)block { [_scheduled addObject:[block copy]]; }

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    id e = sky_draw_encoder(self.device, d, _s->data, self);
    if (e) {
        static int ngpu;
        if (ngpu++ < 5)
            sky_log("GPU encoder %d: %ux%u", ngpu, (unsigned)((id<MTLTexture>)d.colorAttachments[0].texture).width,
                    (unsigned)((id<MTLTexture>)d.colorAttachments[0].texture).height);
    }
    return e ?: sky_render_encoder(self.device, d);
}

- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    return [[SkyBlitEncoder alloc] initWithStream:_s buffer:self];
}

- (void)finish:(MTLCommandBufferStatus)status {
    extern void sky_shadow_writeback(id owner, BOOL completed);
    sky_shadow_writeback(self, status == MTLCommandBufferStatusCompleted);
    _t1 = sky_now();
    _status = status;
    for (MTLCommandBufferHandler h in _completed)
        h(self);
    [_completed removeAllObjects];
    dispatch_semaphore_signal(_done);
}

// perf: every 600 commits, the average CPU cost per commit of draws (SkyRender.m),
// of commit itself, and the time between commits
static void perf_commit(uint64_t commit_ticks, size_t bytes) {
    extern uint64_t sky_perf_draw_ticks, sky_perf_draws, sky_perf_tex_ticks, sky_perf_fb_ticks;
    static uint64_t n, ticks, last, gap, sz;
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    uint64_t now = mach_absolute_time();
    if (last)
        gap += now - last;
    last = now;
    ticks += commit_ticks;
    sz += bytes;
    if (++n == 600) {
        double us = (double)tb.numer / tb.denom / 1000.0;
        sky_log("perf 600 commits: draws %llu (%.0f us each), per commit: draw %.0f us (tex %.0f, fb %.0f), commit %.0f us, gap %.0f us, %llu bytes",
                sky_perf_draws, sky_perf_draws ? sky_perf_draw_ticks * us / sky_perf_draws : 0.0,
                sky_perf_draw_ticks * us / n, sky_perf_tex_ticks * us / n, sky_perf_fb_ticks * us / n, ticks * us / n,
                gap * us / n, sz / n);
        n = ticks = gap = sz = 0;
        sky_perf_draw_ticks = sky_perf_draws = sky_perf_tex_ticks = sky_perf_fb_ticks = 0;
    }
}

- (void)commit {
    uint64_t perf_t0 = mach_absolute_time();
    [self commitImpl];
    perf_commit(mach_absolute_time() - perf_t0, _s->data.length);
}

- (void)commitImpl {
    extern uint64_t sky_commits;
    __atomic_add_fetch(&sky_commits, 1, __ATOMIC_RELAXED);
    [self enqueue];
    _t0 = sky_now();
    _status = MTLCommandBufferStatusCommitted;
    uint32_t dw = [_s dwords];
    static int clog; if (clog++ < 10)
        sky_log("commit: dw=%u bytes=%lu", dw, (unsigned long)_s->data.length);
    if (dw == 0) {
        _status = MTLCommandBufferStatusScheduled;
        for (MTLCommandBufferHandler h in _scheduled)
            h(self);
        [self finish:MTLCommandBufferStatusCompleted];
        return;
    }
    if (!sky_alloc(_s->data.length, &_ib)) {
        _error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorOutOfMemory userInfo:nil];
        [self finish:MTLCommandBufferStatusError];
        return;
    }
    memcpy(_ib.cpu, _s->data.bytes, _s->data.length);
    uint64_t in[3] = {_ib.handle, 0, dw}, seq = 0;
    uint32_t n = 1;
    // selector 7: submit flushing only the surfaces this buffer uses (kernels
    // without it answer kIOReturnBadArgument: flush-everything submit)
    extern NSSet<NSNumber *> *sky_surfaces_of(id owner);
    static BOOL no_list;
    kern_return_t kr = KERN_FAILURE;
    if (!no_list) {
        NSSet<NSNumber *> *used = sky_surfaces_of(self);
        uint64_t handles[256];
        size_t nh = 0;
        for (NSNumber *h in used)
            if (nh < 256)
                handles[nh++] = h.unsignedLongLongValue;
        kr = IOConnectCallMethod(sky_conn, 7, in, 3, handles, nh * 8, &seq, &n, NULL, NULL);
        if (kr != KERN_SUCCESS) {
            no_list = YES;
            sky_log("submit list: %#x, falling back", kr);
        }
    }
    if (kr != KERN_SUCCESS && IOConnectCallScalarMethod(sky_conn, SKY_SUBMIT, in, 3, &seq, &n) != KERN_SUCCESS) {
        _error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal userInfo:nil];
        [self finish:MTLCommandBufferStatusError];
        return;
    }
    _seq = seq;
    for (uint64_t cur = __atomic_load_n(&sky_seq_submitted, __ATOMIC_RELAXED);
         seq > cur && !__atomic_compare_exchange_n(&sky_seq_submitted, &cur, seq, NO, __ATOMIC_RELEASE, __ATOMIC_RELAXED);)
        ;
    _status = MTLCommandBufferStatusScheduled;
    for (MTLCommandBufferHandler h in _scheduled)
        h(self);
    // completion: one waiter per command buffer for now
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        uint64_t w[2] = {self->_seq, 5000}, st = 9;
        uint32_t k = 1;
        kern_return_t kr = IOConnectCallScalarMethod(sky_conn, SKY_WAIT, w, 2, &st, &k);
        if (kr == KERN_SUCCESS && st == 0)
            for (uint64_t cur = __atomic_load_n(&sky_seq_completed, __ATOMIC_RELAXED);
                 self->_seq > cur &&
                 !__atomic_compare_exchange_n(&sky_seq_completed, &cur, self->_seq, NO, __ATOMIC_RELEASE, __ATOMIC_RELAXED);)
                ;
        if (kr != KERN_SUCCESS || st != 0) {
            static int tlog;
            uint32_t cp, done;
            sky_progress(&cp, &done);
            if (tlog++ < 3)
                sky_log("wait seq %llu failed (kr %#x st %llu): cp mark %#x done mark %#x (last id %u)",
                        self->_seq, kr, st, cp, done, sky_draw_id);
        }
        if (kr != KERN_SUCCESS || st != 0)
            self->_error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
        [self finish:self->_error ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted];
    });
}

- (void)commitAndWaitUntilSubmitted {
    [self commit];
}

- (NSUInteger)protectionOptions { return 0; }
- (void)setProtectionOptions:(NSUInteger)o {}

- (void)waitUntilScheduled {}

- (void)waitUntilCompleted {
    if (_status < MTLCommandBufferStatusCommitted)
        return;
    dispatch_semaphore_wait(_done, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(_done);
}
@end

@implementation SkyCommandQueue {
    __weak id<MTLDevice> _device;
    NSString *_label;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init]))
        _device = device;
    return self;
}

- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (id<MTLCommandBuffer>)commandBuffer { return [[SkyCommandBuffer alloc] initWithQueue:self]; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
- (void)setGPUPriority:(NSUInteger)p {}
- (void)setBackgroundGPUPriority:(NSUInteger)p {}
- (void)setSubmissionQueue:(dispatch_queue_t)q {}
- (void)setCompletionQueue:(dispatch_queue_t)q {}
@end

#pragma mark - device

@implementation SkyDeviceMethods
- (id<MTLCommandQueue>)newCommandQueue {
    return [[SkyCommandQueue alloc] initWithDevice:(id<MTLDevice>)self];
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n {
    return [self newCommandQueue];
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return [[SkyBuffer alloc] initWithDevice:(id<MTLDevice>)self length:length options:options];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)p length:(NSUInteger)length options:(MTLResourceOptions)options {
    SkyBuffer *b = [[SkyBuffer alloc] initWithDevice:(id<MTLDevice>)self length:length options:options];
    if (b)
        memcpy(b.contents, p, length);
    return b;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)p length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void *, NSUInteger))dealloc {
    // CA uses this for vertex data mapped from IOSurfaces. Ideally we'd import
    // the pages into the GPU, but for now copy into a GPU-backed buffer.
    SkyBuffer *b = [[SkyBuffer alloc] initWithDevice:(id<MTLDevice>)self length:length options:options];
    if (b)
        memcpy(b.contents, p, length);
    // Don't call the deallocator — the caller owns the memory, our buffer is a copy
    return b;
}
- (NSString *)name {
    return @"Adreno 618 (SkyIOS)";
}
@end
