// Render command encoder that draws on the Adreno 618, for the subset that
// has GPU code: render target = one IOSurface texture in a 32-bit RGBA/BGRA
// format (imported with user client selector 6), load action clear by the 2D
// engine, triangle lists/strips with float4 positions from setVertexBytes /
// setVertexBuffer (float4 position, + float2 uv for textured programs),
// fragment texture 0 = a BGRA8 IOSurface, pipelines whose functions are built into this bundle
// (hand-assembled ir3 below). Register state = the kernel's cp3d.rs tables
// (../test/cp3d-tables.h). Anything else falls back to the recording
// encoder (SkyRecord.m) and draws nothing.

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

#import "SkyMetal.h"
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <mach/mach_time.h>
#include "../test/cp3d-tables.h"
#include "SkyPrograms.h"

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
static void emit(NSMutableData *s, uint32_t v) {
    [s appendBytes:&v length:4];
}
static void reg(NSMutableData *s, uint32_t r, const uint32_t *v, uint32_t n) {
    emit(s, pkt4(r, n));
    for (uint32_t i = 0; i < n; i++)
        emit(s, v[i]);
}
static void reg1(NSMutableData *s, uint32_t r, uint32_t v) {
    reg(s, r, &v, 1);
}
static void reg64(NSMutableData *s, uint32_t r, uint64_t a) {
    uint32_t v[2] = {(uint32_t)a, (uint32_t)(a >> 32)};
    reg(s, r, v, 2);
}
static void event(NSMutableData *s, uint32_t ev) {
    emit(s, pkt7(0x46, 1));
    emit(s, ev);
}
static void event_ts(NSMutableData *s, uint32_t ev, uint64_t a, uint32_t v) {
    emit(s, pkt7(0x46, 4));
    emit(s, ev);
    emit(s, (uint32_t)a);
    emit(s, (uint32_t)(a >> 32));
    emit(s, v);
}
static void wfi(NSMutableData *s) {
    emit(s, pkt7(0x26, 0));
}
// PC_CCU_FLUSH_COLOR_TS and a CP_WAIT_REG_MEM until its timestamp lands: the
// event is asynchronous and a WFI does not wait for it (turnip and HakiOS's
// sysmem framebuffer-fetch barrier wait the same way). A fresh value each time
// so that an earlier flush's word does not satisfy the wait.
static void ccu_flush_wait(NSMutableData *s, uint64_t ts) {
    static _Atomic uint32_t seq;
    uint32_t v = ++seq;
    event_ts(s, 0x1d, ts, v);
    emit(s, pkt7(0x3c, 6));     // CP_WAIT_REG_MEM
    emit(s, 0x3 | (1 << 4));    // WRITE_EQ, POLL_MEMORY
    emit(s, (uint32_t)ts);
    emit(s, (uint32_t)(ts >> 32));
    emit(s, v);
    emit(s, ~0u);
    emit(s, 16);                // delay loop cycles
}
static uint32_t fbits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

#define FMT6_8_8_8_8_UNORM 0x30
#define CCU_CNTL_BYPASS ((0x10000 >> 12) << 23)

#pragma mark - built-in programs

// GPU memory shared by all encoders of the process: shader code (128-byte
// aligned), zeroed border colours, a CCU timestamp word
enum { CODE_VS = 0x000, CODE_FS_RED = 0x080, CODE_FS_TEX = 0x100, CODE_FS_BLEND = 0x180,
       CODE_VS_MVP = 0x280, CODE_FS_WHITE = 0x3C0, CODE_BORDER = 0x400, CODE_TS = 0x500, CODE_PROG = 0x600, CODE_DONE = 0x608, CODE_SIZE = 0x4000 };

static SkyMem sky_code;

// debug: per-draw progress. CODE_PROG is written by the CP when it parses
// the marker, CODE_DONE by a CCU flush timestamp once the draw has finished,
// so after a hang the two tell which draw stopped (logged on a wait timeout)
uint32_t sky_draw_id;
static void mark(NSMutableData *s, uint32_t v) {
    uint64_t p = sky_code.iova + CODE_PROG;
    emit(s, pkt7(0x3d, 3)); // CP_MEM_WRITE
    emit(s, (uint32_t)p);
    emit(s, (uint32_t)(p >> 32));
    emit(s, v);
}
static void mark_done(NSMutableData *s, uint32_t v) {
    event_ts(s, 0x1d, sky_code.iova + CODE_DONE, v);
}
void sky_progress(uint32_t *cp, uint32_t *done) {
    const volatile uint32_t *w = sky_code.cpu;
    *cp = w ? w[CODE_PROG / 4] : 0;
    *done = w ? w[CODE_DONE / 4] : 0;
}

static BOOL code_ready(void) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static BOOL logged_ok;
    os_unfair_lock_lock(&lock);
    if (!sky_code.handle && sky_alloc(CODE_SIZE, &sky_code)) {
        sky_log("code_ready: shader code allocated at gpu %#llx", (unsigned long long)sky_code.iova);
        logged_ok = YES;
        uint32_t *w = sky_code.cpu;
        memset(w, 0, CODE_SIZE);
        // VS: end (VFD writes the float4 position straight into r0)
        w[CODE_VS / 4 + 1] = 0x03000000;
        // FS: mov.f32f32 r0.x..w = 1, 0, 0, 1; end
        const uint32_t red[10] = {0x3f800000, 0x20444000, 0, 0x20444001, 0, 0x20444002, 0x3f800000, 0x20444003, 0, 0x03000000};
        memcpy(&w[CODE_FS_RED / 4], red, sizeof(red));
        // FS: texture prefetch (SP_PS_INITIAL_TEX_LOAD, uv varying -> r1);
        // bary.f (ei)r63.x, 0, r0.x; (sy)end
        const uint32_t tex[4] = {0x00002000, 0x473080fc, 0, 0x13000000};
        memcpy(&w[CODE_FS_TEX / 4], tex, sizeof(tex));

        // FS: premultiplied source-over with framebuffer fetch.
        // Two texture prefetches (SP_PS_INITIAL_TEX_LOAD=2):
        //   prefetch 0: layer texture at uv varying -> r1
        //   prefetch 1: fb (self-sample at frag coord) -> r2
        // out = src + fb * (1 - src.a)   (premultiplied alpha)
        //
        // cat2 encoding: w[0] = src1 | src2<<16; w[1] = 2<<29 | flags
        // cat2_gpr(opc, dst, s1, s2, sy): add.f/mul.f with two GPR sources
        // cat2_neg(opc, dst, imm_flut, s2_neg, sy): src1=flut imm, src2=GPR|NEG
        //
        // GPR reg encoding: reg*4 + comp (full precision)
        // r1.w = 1*4+3 = 7, r2.x = 2*4+0 = 8, r3.x = 3*4+0 = 12
        // flut: 0=0.0, 1=0.5, 2=1.0
#define GPR(r,c) ((r)*4+(c))
#define CAT2_GPR(opc, dst, s1, s2, sy) \
    (s1) | ((uint32_t)(s2) << 16), (2u<<29)|((uint32_t)(sy)<<28)|((opc)<<21)|(1u<<20)|(dst)
#define CAT2_NEG(opc, dst, flut, s2, sy) \
    ((flut)|(5u<<11)) | (((s2)|(1u<<15)) << 16), (2u<<29)|((uint32_t)(sy)<<28)|((opc)<<21)|(1u<<20)|(dst)
#define NOP 0, 0
        const uint32_t blend[] = {
            // bary.f (ei)r63.x, 0, r0.x
            0x00002000, 0x473080fc,
            // (sy)add.f r3.x, 1.0, -r1.w    (1 - src.a)
            CAT2_NEG(0, GPR(3,0), 2, GPR(1,3), 1),
            NOP, NOP, NOP,
            // mul.f r2.x..w, r2.x..w, r3.x  (fb * (1-a))
            CAT2_GPR(3, GPR(2,0), GPR(2,0), GPR(3,0), 0),
            CAT2_GPR(3, GPR(2,1), GPR(2,1), GPR(3,0), 0),
            CAT2_GPR(3, GPR(2,2), GPR(2,2), GPR(3,0), 0),
            CAT2_GPR(3, GPR(2,3), GPR(2,3), GPR(3,0), 0),
            NOP, NOP, NOP,
            // add.f r0.x..w, r2.x..w, r1.x..w  (fb*(1-a) + src)
            CAT2_GPR(0, GPR(0,0), GPR(2,0), GPR(1,0), 0),
            CAT2_GPR(0, GPR(0,1), GPR(2,1), GPR(1,1), 0),
            CAT2_GPR(0, GPR(0,2), GPR(2,2), GPR(1,2), 0),
            CAT2_GPR(0, GPR(0,3), GPR(2,3), GPR(1,3), 0),
            NOP, NOP, NOP,
            // end
            0, 0x03000000,
        };
#undef GPR
#undef CAT2_GPR
#undef CAT2_NEG
#undef NOP
        memcpy(&w[CODE_FS_BLEND / 4], blend, sizeof(blend));

        // VS: matrix multiply — transforms position by 4×4 matrix in constants c0-c3.
        // Input:  r0.xyzw = position (VFD), r1.xy = texcoord (VFD)
        // Output: r0.xyzw = matrix * position, r1.xy = texcoord (passthrough)
        // Uses r2-r5 as temporaries.
#define C(r,c) ((r)*4+(c) | (1u << 11))
#define CAT2_CG(opc, dst, s1c, s2g, sy) \
    (s1c) | ((uint32_t)(s2g) << 16), (2u<<29)|((uint32_t)(sy)<<28)|((opc)<<21)|(1u<<20)|(dst)
#define CAT2_GG(opc, dst, s1, s2, sy) \
    (s1) | ((uint32_t)(s2) << 16), (2u<<29)|((uint32_t)(sy)<<28)|((opc)<<21)|(1u<<20)|(dst)
#define CAT2_FG(opc, dst, flut, s2, sy) \
    ((flut)|(5u<<11)) | ((uint32_t)(s2) << 16), (2u<<29)|((uint32_t)(sy)<<28)|((opc)<<21)|(1u<<20)|(dst)
#define G(r,c) ((r)*4+(c))
#define VNOP 0, 0
        const uint32_t vs_mvp[] = {
            // Row 0: clip.x = c0 · pos
            CAT2_CG(3, G(2,0), C(0,0), G(0,0), 0), // mul.f r2.x, c0.x, r0.x
            CAT2_CG(3, G(2,1), C(0,1), G(0,1), 0), // mul.f r2.y, c0.y, r0.y
            CAT2_CG(3, G(2,2), C(0,2), G(0,2), 0), // mul.f r2.z, c0.z, r0.z
            CAT2_CG(3, G(2,3), C(0,3), G(0,3), 0), // mul.f r2.w, c0.w, r0.w
            // Row 1: interleave while row 0 muls complete
            CAT2_CG(3, G(3,0), C(1,0), G(0,0), 0), // mul.f r3.x, c1.x, r0.x
            CAT2_CG(3, G(3,1), C(1,1), G(0,1), 0), // mul.f r3.y, c1.y, r0.y
            CAT2_GG(0, G(2,0), G(2,0), G(2,1), 0),  // add.f r2.x, r2.x, r2.y
            CAT2_CG(3, G(3,2), C(1,2), G(0,2), 0), // mul.f r3.z, c1.z, r0.z
            CAT2_GG(0, G(2,2), G(2,2), G(2,3), 0),  // add.f r2.z, r2.z, r2.w
            CAT2_CG(3, G(3,3), C(1,3), G(0,3), 0), // mul.f r3.w, c1.w, r0.w
            // Row 2:
            CAT2_CG(3, G(4,0), C(2,0), G(0,0), 0), // mul.f r4.x, c2.x, r0.x
            CAT2_CG(3, G(4,1), C(2,1), G(0,1), 0), // mul.f r4.y, c2.y, r0.y
            CAT2_GG(0, G(2,0), G(2,0), G(2,2), 0),  // add.f r2.x, r2.x, r2.z → clip.x DONE
            CAT2_GG(0, G(3,0), G(3,0), G(3,1), 0),  // add.f r3.x, r3.x, r3.y
            CAT2_CG(3, G(4,2), C(2,2), G(0,2), 0), // mul.f r4.z, c2.z, r0.z
            CAT2_GG(0, G(3,2), G(3,2), G(3,3), 0),  // add.f r3.z, r3.z, r3.w
            CAT2_CG(3, G(4,3), C(2,3), G(0,3), 0), // mul.f r4.w, c2.w, r0.w
            // Row 3:
            CAT2_CG(3, G(5,0), C(3,0), G(0,0), 0), // mul.f r5.x, c3.x, r0.x
            CAT2_CG(3, G(5,1), C(3,1), G(0,1), 0), // mul.f r5.y, c3.y, r0.y
            CAT2_GG(0, G(3,0), G(3,0), G(3,2), 0),  // add.f r3.x, r3.x, r3.z → clip.y DONE
            CAT2_GG(0, G(4,0), G(4,0), G(4,1), 0),  // add.f r4.x, r4.x, r4.y
            CAT2_CG(3, G(5,2), C(3,2), G(0,2), 0), // mul.f r5.z, c3.z, r0.z
            CAT2_GG(0, G(4,2), G(4,2), G(4,3), 0),  // add.f r4.z, r4.z, r4.w
            CAT2_CG(3, G(5,3), C(3,3), G(0,3), 0), // mul.f r5.w, c3.w, r0.w
            CAT2_GG(0, G(5,0), G(5,0), G(5,1), 0),  // add.f r5.x, r5.x, r5.y
            VNOP,
            CAT2_GG(0, G(4,0), G(4,0), G(4,2), 0),  // add.f r4.x, r4.x, r4.z → clip.z DONE
            CAT2_GG(0, G(5,2), G(5,2), G(5,3), 0),  // add.f r5.z, r5.z, r5.w
            VNOP, VNOP,
            CAT2_GG(0, G(5,0), G(5,0), G(5,2), 0),  // add.f r5.x, r5.x, r5.z → clip.w DONE
            VNOP, VNOP, VNOP,
            // Move results to r0 output: add.f r0.c, 0.0, rN.x
            CAT2_FG(0, G(0,0), 0, G(2,0), 0),  // r0.x = clip.x
            CAT2_FG(0, G(0,1), 0, G(3,0), 0),  // r0.y = clip.y
            CAT2_FG(0, G(0,2), 0, G(4,0), 0),  // r0.z = clip.z
            CAT2_FG(0, G(0,3), 0, G(5,0), 0),  // r0.w = clip.w
            // r1.xy already has texcoord from VFD (passthrough)
            VNOP,
            0, 0x03000000, // end
        };
#undef C
#undef CAT2_CG
#undef CAT2_GG
#undef CAT2_FG
#undef G
#undef VNOP
        memcpy(&w[CODE_VS_MVP / 4], vs_mvp, sizeof(vs_mvp));
        // FS: white — mov.f32f32 r0.xyzw = 1,1,1,1; end
        const uint32_t white[10] = {0x3f800000, 0x20444000, 0x3f800000, 0x20444001, 0x3f800000, 0x20444002, 0x3f800000, 0x20444003, 0, 0x03000000};
        memcpy(&w[CODE_FS_WHITE / 4], white, sizeof(white));
    }
    os_unfair_lock_unlock(&lock);
    return sky_code.handle != 0;
}

// built-in programs: vertex function, fragment function, fragment code,
// textured: samples fragment texture 0 (vertex = float4 pos + float2 uv, TEXQ state)
// fbfetch: also self-samples the render target as a second texture (prefetch 1)
static const struct {
    NSString *vertex, *fragment;
    uint32_t code;
    BOOL textured;
    BOOL fbfetch;
    BOOL mvp;
} sky_programs[] = {
    {@"sky_position_vertex", @"sky_red_fragment", CODE_FS_RED, NO, NO, NO},
    {@"sky_position_uv_vertex", @"sky_texture_fragment", CODE_FS_TEX, YES, NO, NO},
    {@"sky_position_uv_vertex", @"sky_fb_blend_fragment", CODE_FS_BLEND, YES, YES, NO},
    {@"ca_fixed_vert", @"ca_fixed_frag_blend", CODE_FS_BLEND, YES, YES, YES},
    {@"ca_fixed_vert", @"ca_fixed_frag_solid", CODE_FS_WHITE, NO, NO, YES},
    // CA's framebuffer-fetch blend as fixed-function source-over (ONE,
    // ONE_MINUS_SRC_ALPHA): sampling the render target while drawing into it
    // hung the GPU (64x64 offscreen target, probe84/85)
    {@"ca_fixed_vert", @"ca_fixed_frag_tex_over", CODE_FS_TEX, YES, NO, YES},
};
enum { PROG_TEX_OVER = 5 };

#pragma mark - render targets

// IOSurface ID -> GPU mapping, imported once per process
typedef struct {
    uint64_t handle, iova, bpr, offset;
} SkyImport;

// command buffers committed so far (SkyObjects.m): an import last used two
// or more commits ago is no longer referenced by unsubmitted commands
uint64_t sky_commits;

static BOOL import_surface(IOSurfaceRef s, SkyImport *out) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSNumber *, NSData *> *cache;
    static NSMutableDictionary<NSNumber *, NSNumber *> *used; // surface -> commit count at last use
    enum { MAX_IMPORTS = 200 }; // kernel: 320 buffer slots per client
    uint32_t sid = IOSurfaceGetID(s);
    os_unfair_lock_lock(&lock);
    if (!cache) {
        cache = [NSMutableDictionary new];
        used = [NSMutableDictionary new];
    }
    NSData *d = cache[@(sid)];
    if (!d) {
        uint64_t in = sid, o[4];
        uint32_t n = 4;
        kern_return_t kr = KERN_RESOURCE_SHORTAGE;
        for (int tries = 0; tries < 8; tries++) {
            if (cache.count < MAX_IMPORTS) {
                kr = IOConnectCallScalarMethod(sky_conn, SKY_IMPORT, &in, 1, o, &n);
                // out of slots or of GPU address space: evict and retry
                if (kr != kIOReturnNoResources && kr != kIOReturnNoSpace)
                    break;
            }
            // release the least recently used import nobody can still reference
            NSNumber *victim = nil;
            uint64_t oldest = UINT64_MAX;
            for (NSNumber *k in used) {
                uint64_t u = used[k].unsignedLongLongValue;
                if (u + 2 <= sky_commits && u < oldest) {
                    oldest = u;
                    victim = k;
                }
            }
            if (!victim)
                break;
            SkyImport old;
            memcpy(&old, cache[victim].bytes, sizeof(old));
            IOConnectCallScalarMethod(sky_conn, SKY_FREE, &old.handle, 1, NULL, NULL);
            [cache removeObjectForKey:victim];
            [used removeObjectForKey:victim];
            kr = kIOReturnNoResources;
        }
        if (kr == KERN_SUCCESS) {
            SkyImport im = {o[0], o[1], o[2], o[3]};
            d = [NSData dataWithBytes:&im length:sizeof(im)];
            cache[@(sid)] = d;
        } else {
            static int nfail;
            if (nfail++ < 20)
                sky_log("import surface %u %zux%zu bpr %zu failed: %#x (%lu imported)", sid, IOSurfaceGetWidth(s),
                        IOSurfaceGetHeight(s), IOSurfaceGetBytesPerRow(s), kr, (unsigned long)cache.count);
        }
    }
    if (d)
        used[@(sid)] = @(sky_commits);
    os_unfair_lock_unlock(&lock);
    if (!d)
        return NO;
    memcpy(out, d.bytes, sizeof(*out));
    return YES;
}

// imported surfaces a command buffer uses: the kernel flushes only these
// from the CPU caches on submit (selector 7, SkyObjects.m)
static const char sky_surface_key;
static void note_surface(id owner, const SkyImport *im) {
    NSMutableSet<NSNumber *> *set = objc_getAssociatedObject(owner, &sky_surface_key);
    if (!set) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(owner, &sky_surface_key, set, OBJC_ASSOCIATION_RETAIN);
    }
    [set addObject:@(im->handle)];
}
NSSet<NSNumber *> *sky_surfaces_of(id owner) {
    return objc_getAssociatedObject(owner, &sky_surface_key);
}

// per-command-buffer upload memory for setVertexBytes, freed with it
@interface SkyUpload : NSObject {
@public
    SkyMem mem;
    size_t used;
}
@end
@implementation SkyUpload
- (void)dealloc {
    sky_free(&mem);
}
@end

#pragma mark - encoder

static const uint8_t *sky_last_upload_cpu;

// SkyRenderPipeline (SkyRecord.m) properties; called directly, not through
// KVC: valueForKey: tries -getVname first, which SkyObject's missing-selector
// resolver answers with nil (0112j)
@protocol SkyPipelineNames
- (NSString *)vname;
- (NSString *)fname;
- (NSString *)fkey;
- (uint32_t)mrtControl;
- (uint32_t)mrtBlend;
- (NSString *)vkey;
- (SkyVertexDesc)vdesc;
@end

#pragma mark - compiled programs

// pipeline function keys -> SkyPrograms.h entry
static const SkyProgEntry *prog_lookup(NSString *vkey, NSString *fkey) {
    static NSDictionary<NSString *, NSValue *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof(sky_prog_table) / sizeof(sky_prog_table[0]); i++) {
            const SkyProgEntry *e = &sky_prog_table[i];
            t[[NSString stringWithFormat:@"%s + %s", e->vkey, e->fkey]] = [NSValue valueWithPointer:e];
        }
        table = t;
    });
    if (!vkey || !fkey)
        return NULL;
    NSString *k = [NSString stringWithFormat:@"%@ + %@", vkey, fkey];
    const SkyProgEntry *e = table[k].pointerValue;
    if (!e)
        sky_log_once([@"noprog " stringByAppendingString:k]);
    return e;
}

// program code in GPU memory, uploaded once per program
static uint64_t prog_code(const SkyProg *p, BOOL fs) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSValue *, NSData *> *code;
    os_unfair_lock_lock(&lock);
    if (!code)
        code = [NSMutableDictionary dictionary];
    // every program in one allocation: the kernel has 64 buffer slots per
    // client, shared with imports and Metal buffers
    if (!code.count) {
        size_t total = 0, n = sizeof(sky_prog_table) / sizeof(sky_prog_table[0]);
        for (size_t i = 0; i < n; i++)
            total += (((size_t)sky_prog_table[i].prog->vs_dwords * 4 + 127) & ~(size_t)127) +
                     (((size_t)sky_prog_table[i].prog->fs_dwords * 4 + 127) & ~(size_t)127);
        SkyMem m;
        if (total && sky_alloc((total + 4095) & ~(size_t)4095, &m)) {
            size_t at = 0;
            for (size_t i = 0; i < n; i++) {
                const SkyProg *q = sky_prog_table[i].prog;
                NSValue *qk = [NSValue valueWithPointer:q];
                if (code[qk])
                    continue;
                size_t vs = ((size_t)q->vs_dwords * 4 + 127) & ~(size_t)127;
                size_t fsz = ((size_t)q->fs_dwords * 4 + 127) & ~(size_t)127;
                memcpy((uint8_t *)m.cpu + at, q->vs, q->vs_dwords * 4);
                memcpy((uint8_t *)m.cpu + at + vs, q->fs, q->fs_dwords * 4);
                uint64_t a[2] = {m.iova + at, m.iova + at + vs};
                code[qk] = [NSData dataWithBytes:a length:sizeof(a)];
                at += vs + fsz;
            }
        }
    }
    NSData *d = code[[NSValue valueWithPointer:p]];
    os_unfair_lock_unlock(&lock);
    return d ? ((const uint64_t *)d.bytes)[fs ? 1 : 0] : 0;
}

// MTLVertexFormat -> a6xx_format (0: unsupported)
static uint32_t vfd_format(uint32_t f) {
    switch (f) {
    case MTLVertexFormatFloat: return 0x4a;
    case MTLVertexFormatFloat2: return 0x67;
    case MTLVertexFormatFloat3: return 0x74;
    case MTLVertexFormatFloat4: return 0x82;
    case MTLVertexFormatHalf2: return 0x45;
    case MTLVertexFormatHalf4: return 0x62;
    case MTLVertexFormatUChar4Normalized: return 0x30;
    default: return 0;
    }
}

// texture format: a6xx_format, swap, swizzle (A6XX_TEX_CONST_0 bits 4-15)
static BOOL tex_format(MTLPixelFormat f, uint32_t *fmt, uint32_t *swap, uint32_t *swiz, BOOL *srgb) {
    enum { X = 0, Y = 1, Z = 2, W = 3, ZERO = 4, ONE = 5 };
#define SWZ(a, b, c, d) ((a) | (b) << 3 | (c) << 6 | (d) << 9)
    *swap = 0;
    *srgb = NO;
    *swiz = SWZ(X, Y, Z, W);
    switch (f) {
    case MTLPixelFormatBGRA8Unorm_sRGB: *srgb = YES; /* fallthrough */
    case MTLPixelFormatBGRA8Unorm: *fmt = 0x30; *swap = 1; return YES;
    case MTLPixelFormatRGBA8Unorm_sRGB: *srgb = YES; /* fallthrough */
    case MTLPixelFormatRGBA8Unorm: *fmt = 0x30; return YES;
    case MTLPixelFormatA8Unorm: *fmt = 0x03; *swiz = SWZ(ZERO, ZERO, ZERO, X); return YES;
    case MTLPixelFormatR8Unorm: *fmt = 0x03; *swiz = SWZ(X, ZERO, ZERO, ONE); return YES;
    case MTLPixelFormatRG8Unorm: *fmt = 0x0f; *swiz = SWZ(X, Y, ZERO, ONE); return YES;
    case MTLPixelFormatR16Float: *fmt = 0x17; *swiz = SWZ(X, ZERO, ZERO, ONE); return YES;
    case MTLPixelFormatRG16Float: *fmt = 0x45; *swiz = SWZ(X, Y, ZERO, ONE); return YES;
    case MTLPixelFormatR32Float: *fmt = 0x4a; *swiz = SWZ(X, ZERO, ZERO, ONE); return YES;
    case MTLPixelFormatRGBA16Float: *fmt = 0x62; return YES;
    case MTLPixelFormatASTC_4x4_sRGB: *srgb = YES; /* fallthrough */
    case MTLPixelFormatASTC_4x4_LDR: *fmt = 0xc1; return YES; // FMT6_ASTC_4x4
    default: return NO;
    }
#undef SWZ
}

// Metal's constexpr sampler state (AIR): s/t/r address bits 0-8 (0 zero,
// 1 edge, 2 repeat, 3 mirrored repeat, 4 border), mag bit 9, min bit 11,
// mip bits 13-14, bit 15 coord::pixel (A6XX_TEX_SAMP_1 UNNORM_COORDS)
static uint32_t const_sampler_word(uint64_t bits) {
    static const uint8_t wrap[] = {3, 1, 0, 2, 3, 1, 1, 1};
    return (uint32_t)((bits >> 9) & 1) << 1 | (uint32_t)((bits >> 11) & 1) << 3 | (uint32_t)wrap[bits & 7] << 5 |
           (uint32_t)wrap[(bits >> 3) & 7] << 8 | (uint32_t)wrap[(bits >> 6) & 7] << 11;
}

// MTLBlendFactor -> adreno_rb_blend_factor; MTLBlendOperation values equal
// a3xx_rb_blend_opcode (add, src - dst, dst - src, min, max)
static uint32_t blend_factor(MTLBlendFactor f) {
    static const uint8_t map[] = {0, 1, 4, 5, 6, 7, 8, 9, 10, 11, 16, 12, 13, 14, 15, 20, 21, 22, 23};
    return f < sizeof(map) ? map[f] : 1;
}

void sky_blend_state(MTLRenderPipelineColorAttachmentDescriptor *c, uint32_t *control, uint32_t *blend) {
    MTLColorWriteMask m = c.writeMask;
    // COMPONENT_ENABLE: bit 0 = R .. bit 3 = A; Metal: R = 8, G = 4, B = 2, A = 1
    uint32_t comp = (m & MTLColorWriteMaskRed ? 1 : 0) | (m & MTLColorWriteMaskGreen ? 2 : 0) |
                    (m & MTLColorWriteMaskBlue ? 4 : 0) | (m & MTLColorWriteMaskAlpha ? 8 : 0);
    // ROP_CODE COPY (0xc) as in cp3d.rs STATE; COLOR_BLEND_EN | ALPHA_BLEND_EN
    *control = (comp << 7) | (0xc << 3) | (c.blendingEnabled ? 3 : 0);
    *blend = blend_factor(c.sourceRGBBlendFactor) | ((uint32_t)c.rgbBlendOperation << 5) |
             (blend_factor(c.destinationRGBBlendFactor) << 8) | (blend_factor(c.sourceAlphaBlendFactor) << 16) |
             ((uint32_t)c.alphaBlendOperation << 21) | (blend_factor(c.destinationAlphaBlendFactor) << 24);
}

@interface SkyDrawEncoder : SkyObject <MTLRenderCommandEncoder>
@property (weak) id<MTLDevice> device;
@property (copy) NSString *label;
@end

@implementation SkyDrawEncoder {
    NSMutableData *_s;
    id _owner;
    SkyImport _rt;
    IOSurfaceRef _rtSurf;
    uint32_t _w, _h, _info;
    NSString *_vname, *_fname, *_fkey;
    uint32_t _mrtControl, _mrtBlend;
    uint64_t _vb, _vb_base;
    id<MTLTexture> _tex;
    NSUInteger _draws, _skipped;
    uint64_t _vtx_gpu[32];
    uint64_t _vtx_base[32];
    NSUInteger _vtx_len[32];
    const uint8_t *_vtx_cpu[32];
    const uint8_t *_frag_cpu[8];
    id<MTLTexture> _texs[16];
    uint64_t _frag_gpu[8];
    uint64_t _frag_base[8];
    NSUInteger _frag_len[8];
    MTLViewport _vp;
    BOOL _hasVP;
    int _progcount[6];
    NSString *_vkey;
    SkyVertexDesc _vdesc;
    const SkyProgEntry *_prog;
    id<MTLSamplerState> _samps[16];
    NSUInteger _vtx_avail[32], _frag_avail[8];
    MTLScissorRect _scissor;
    BOOL _hasScissor;
    NSUInteger _progDraws, _noProg;
}

- (instancetype)initWithStream:(NSMutableData *)s owner:(id)owner target:(SkyImport)rt surface:(IOSurfaceRef)surf width:(uint32_t)w height:(uint32_t)h info:(uint32_t)info {
    if ((self = [super init])) {
        _info = info;
        _s = s;
        _owner = owner;
        _rt = rt;
        _rtSurf = (IOSurfaceRef)CFRetain(surf);
        _w = w;
        _h = h;
    }
    return self;
}
- (void)dealloc {
    if (_rtSurf) CFRelease(_rtSurf);
}

// Metal keeps every resource a command buffer uses alive until it completes;
// CA releases buffers right after encoding, and freeing one unmaps it while
// the GPU has yet to run the draw (SMMU fault on a just-freed IOVA)
- (void)keep:(id)o {
    if (!o)
        return;
    static const char key;
    NSMutableSet *all = objc_getAssociatedObject(_owner, &key);
    if (!all) {
        all = [NSMutableSet set];
        objc_setAssociatedObject(_owner, &key, all, OBJC_ASSOCIATION_RETAIN);
    }
    [all addObject:o];
}

- (uint64_t)upload:(const void *)p length:(NSUInteger)len {
    static const char key;
    NSMutableArray<SkyUpload *> *all = objc_getAssociatedObject(_owner, &key);
    if (!all) {
        all = [NSMutableArray array];
        objc_setAssociatedObject(_owner, &key, all, OBJC_ASSOCIATION_RETAIN);
    }
    SkyUpload *u = all.lastObject;
    if (!u || u->used + len > u->mem.size) {
        u = [SkyUpload new];
        // big chunks: every chunk is one of the kernel's 320 buffers per client
        size_t size = MAX(len, 1 << 20);
        if (!sky_alloc(size, &u->mem))
            return 0;
        u->mem.size = size;
        [all addObject:u];
    }
    uint64_t a = u->mem.iova + u->used;
    sky_last_upload_cpu = (uint8_t *)u->mem.cpu + u->used;
    memcpy((uint8_t *)u->mem.cpu + u->used, p, len);
    u->used = (u->used + len + 63) & ~(size_t)63;
    return a;
}

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p {
    _vname = [(id<SkyPipelineNames>)p vname];
    _fname = [(id<SkyPipelineNames>)p fname];
    _fkey = [(id<SkyPipelineNames>)p fkey];
    _mrtControl = [(id<SkyPipelineNames>)p mrtControl];
    _mrtBlend = [(id<SkyPipelineNames>)p mrtBlend];
    _vkey = [(id<SkyPipelineNames>)p vkey];
    _vdesc = [(id<SkyPipelineNames>)p vdesc];
    static const char key;
    NSValue *cached = objc_getAssociatedObject(p, &key);
    if (!cached) {
        cached = [NSValue valueWithPointer:prog_lookup(_vkey, _fkey)];
        objc_setAssociatedObject(p, &key, cached, OBJC_ASSOCIATION_RETAIN);
    }
    _prog = cached.pointerValue;
}

- (void)setVertexBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i {
    uint64_t a = [self upload:p length:l];
    if (i < 32) {
        _vtx_cpu[i] = sky_last_upload_cpu;
        _vtx_avail[i] = l;
        _vtx_gpu[i] = a;
        _vtx_len[i] = l;
    }
    if (!_vb)
        _vb = a;
    static int nlog;
    if (nlog++ < 20)
        sky_log("setVertexBytes idx=%lu len=%lu -> gpu %#llx", (unsigned long)i, (unsigned long)l, a);
}

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    [self keep:b];
    uint64_t base = b.gpuAddress;
    if (i < 32) {
        _vtx_cpu[i] = (const uint8_t *)b.contents + o;
        _vtx_avail[i] = b.length > o ? b.length - o : 0;
        _vtx_base[i] = base;
        _vtx_gpu[i] = base + o;
        _vtx_len[i] = b.length;
    }
    if (!_vb) {
        _vb_base = base;
        _vb = base + o;
    }
    static int nlog;
    if (nlog++ < 20)
        sky_log("setVertexBuffer idx=%lu len=%lu off=%lu gpu=%#llx", (unsigned long)i, (unsigned long)b.length, (unsigned long)o, base + o);
}

- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (i < 32) {
        if (_vtx_cpu[i]) {
            int64_t d = (int64_t)(_vtx_base[i] + o) - (int64_t)_vtx_gpu[i];
            _vtx_cpu[i] += d;
            _vtx_avail[i] = (NSUInteger)MAX((int64_t)_vtx_avail[i] - d, 0);
        }
        _vtx_gpu[i] = _vtx_base[i] + o;
    }
}

static NSString *hexs(const uint8_t *p, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; p && i < n; i += 4)
        [s appendFormat:@"%08x ", *(const uint32_t *)(p + i)];
    return s;
}

// debug: bindings and data of the first draw of each fragment variant
- (void)dumpDraw:(NSUInteger)n {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet *seen;
    NSString *k = _fkey ?: _fname ?: @"?";
    os_unfair_lock_lock(&lock);
    if (!seen)
        seen = [NSMutableSet set];
    BOOL first = seen.count < 48 && ![seen containsObject:k];
    if (first)
        [seen addObject:k];
    os_unfair_lock_unlock(&lock);
    if (!first)
        return;
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"draw %@ + %@ n=%lu rt %ux%u", _vname, k, (unsigned long)n, _w, _h]];
    for (int i = 0; i < 16; i++)
        if (_texs[i])
            [lines addObject:[NSString stringWithFormat:@" t%d fmt %lu %lux%lu ios %d", i, (unsigned long)_texs[i].pixelFormat,
                                                        (unsigned long)_texs[i].width, (unsigned long)_texs[i].height, _texs[i].iosurface != NULL]];
    for (int i = 0; i < 32; i++)
        if (_vtx_gpu[i])
            [lines addObject:[NSString stringWithFormat:@" v%d len %lu: %@", i, (unsigned long)_vtx_len[i],
                                                        hexs(_vtx_cpu[i], MIN((NSUInteger)192, _vtx_len[i]))]];
    for (int i = 0; i < 8; i++)
        if (_frag_gpu[i])
            [lines addObject:[NSString stringWithFormat:@" f%d len %lu: %@", i, (unsigned long)_frag_len[i],
                                                        hexs(_frag_cpu[i], MIN((NSUInteger)176, _frag_len[i]))]];
    for (NSString *l in lines)
        for (NSUInteger off = 0; off < l.length; off += 140)
            sky_log("%s%s", off ? "  ..." : "dd ", [l substringWithRange:NSMakeRange(off, MIN(140, l.length - off))].UTF8String);
}

// Map CA's pipeline function names to built-in programs. CA uses
// fixed_vert_lph_spc[texcoord_count0=1] + fixed_frag_lph_cph[...] with
// function constants appended in brackets; match by prefix.
- (int)resolveProgram {
    // exact match first (test programs)
    for (int i = 0; i < (int)(sizeof(sky_programs) / sizeof(sky_programs[0])); i++)
        if ([_vname isEqualToString:sky_programs[i].vertex] && [_fname isEqualToString:sky_programs[i].fragment])
            return i;
    // CA's compositing pipelines: fixed_vert + fixed_frag → program 3 (MVP + blend)
    // Function constants (image_count, framebuffer_fetch) are in the fkey, not the name.
    if ([_vname hasPrefix:@"fixed_vert"] && [_fname hasPrefix:@"fixed_frag"]) {
        NSString *fk = _fkey ?: _fname;
        BOOL has_texture = [fk containsString:@"image_count="];
        BOOL has_fbfetch = [fk containsString:@"framebuffer_fetch=1"];
        if (has_texture && has_fbfetch)
            return PROG_TEX_OVER; // ca_fixed: MVP vertex shader + texture, RB blending
        if (has_fbfetch)
            return 4; // ca_fixed: MVP vertex shader + solid color (no texture)
        if (has_texture)
            return 1;
        return 0;
    }
    // CA post-processing: std_vert + luma_boost/etc → solid fill placeholder
    if ([_vname hasPrefix:@"std_vert"])
        return 0;
    return -1;
}

// CP3D_STATE and a program's registers as ready-made packets, built once
static NSData *packed_regs(const uint32_t (*r)[2], size_t n) {
    NSMutableData *d = [NSMutableData dataWithCapacity:n * 8];
    for (size_t i = 0; i < n; i++)
        reg1(d, r[i][0], r[i][1]);
    return d;
}
static NSData *base_state(void) {
    static NSData *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = packed_regs(CP3D_STATE, sizeof(CP3D_STATE) / sizeof(CP3D_STATE[0]));
    });
    return d;
}
static NSData *prog_state(const SkyProg *p) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSValue *, NSData *> *cache;
    os_unfair_lock_lock(&lock);
    if (!cache)
        cache = [NSMutableDictionary dictionary];
    NSValue *k = [NSValue valueWithPointer:p];
    NSData *d = cache[k];
    if (!d)
        cache[k] = d = packed_regs(p->regs, p->nregs);
    os_unfair_lock_unlock(&lock);
    return d;
}

// CP_LOAD_STATE6 with the data in the packet: `n` vec4s to const `dst` (vec4)
static void load_consts(NSMutableData *s, uint32_t op, uint32_t sb, uint32_t dst, const uint32_t *w, uint32_t n) {
    if (!n)
        return;
    emit(s, pkt7(op, 3 + n * 4));
    emit(s, dst | (1 << 14) | (0 << 16) | (sb << 18) | (n << 22)); // ST6_CONSTANTS, SS6_DIRECT
    emit(s, 0);
    emit(s, 0);
    [s appendBytes:w length:n * 16];
}

// pushed constant-buffer ranges of one stage, copied from the CPU view of
// the bound buffers (zero past their end)
static void load_ubos(NSMutableData *s, uint32_t op, uint32_t sb, const SkyProgUBO *u, uint32_t nu, const uint8_t *const *cpu,
                      const NSUInteger *avail, uint32_t nbuf) {
    for (uint32_t i = 0; i < nu; i++) {
        uint32_t words[1024] = {0};
        uint32_t size = MIN(u[i].size, (uint32_t)sizeof(words));
        if (u[i].buffer < nbuf && cpu[u[i].buffer] && avail[u[i].buffer] > u[i].start)
            memcpy(words, cpu[u[i].buffer] + u[i].start, MIN(size, avail[u[i].buffer] - u[i].start));
        load_consts(s, op, sb, u[i].offset / 16, words, size / 16);
    }
}

// A6XX texture descriptor (16 dwords) for a Metal texture: linear, one level
- (BOOL)texDesc:(uint32_t *)d texture:(id<MTLTexture>)t {
    uint32_t fmt, swap, swiz;
    BOOL srgb;
    if (!t || !tex_format(t.pixelFormat, &fmt, &swap, &swiz, &srgb))
        return NO;
    NSUInteger w = t.width, h = t.height, rowBytes, rows;
    if (!sky_tex_layout(t.pixelFormat, w, h, &rowBytes, &rows))
        return NO;
    uint64_t base = 0;
    NSUInteger bpr = 0;
    const uint8_t *cpu = NULL;
    IOSurfaceRef surf = t.iosurface;
    if (surf) {
        SkyImport im;
        if (!import_surface(surf, &im))
            return NO;
        note_surface(_owner, &im);
        base = im.iova + im.offset;
        bpr = im.bpr;
        if (bpr & 63) {
            IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
            cpu = IOSurfaceGetBaseAddress(surf);
        }
    } else if ([t respondsToSelector:@selector(skyBufGpu)]) {
        uint64_t bg = ((uint64_t (*)(id, SEL))objc_msgSend)(t, @selector(skyBufGpu));
        if (!bg)
            return NO;
        NSUInteger off = ((NSUInteger (*)(id, SEL))objc_msgSend)(t, @selector(skyBufOff));
        bpr = ((NSUInteger (*)(id, SEL))objc_msgSend)(t, @selector(skyBufBpr));
        base = bg + off;
        id<MTLBuffer> b = t.buffer;
        cpu = (bpr & 63) ? (const uint8_t *)b.contents + off : NULL;
    } else {
        return NO;
    }
    if (bpr & 63) {
        // A6XX linear pitch is 64-byte aligned: repack into upload memory
        NSUInteger pitch = (rowBytes + 63) & ~(NSUInteger)63;
        NSMutableData *tmp = [NSMutableData dataWithLength:pitch * rows];
        for (NSUInteger y = 0; cpu && y < rows; y++)
            memcpy((uint8_t *)tmp.mutableBytes + y * pitch, cpu + y * bpr, rowBytes);
        if (surf)
            IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
        base = [self upload:tmp.bytes length:tmp.length];
        bpr = pitch;
        if (!base)
            return NO;
    }
    memset(d, 0, 64);
    d[0] = (srgb ? 4 : 0) | (swiz << 4) | (fmt << 22) | (swap << 30);
    d[1] = (uint32_t)w | ((uint32_t)h << 15);
    d[2] = ((uint32_t)bpr << 7) | (1u << 29); // PITCH, TYPE 2D
    d[4] = (uint32_t)base;
    d[5] = (uint32_t)(base >> 32) | (1u << 17); // DEPTH 1
    return YES;
}

// framebuffer fetch: the colour attachment as it is now, copied by the 2D
// engine into memory freed with the command buffer (sampling the attachment
// while drawing into it hung the GPU, probe84/85)
- (uint64_t)fbCopy {
    // one scratch per size shared by all frames (the GPU runs submissions in
    // order). A fresh 11 MB allocation per command buffer (probe104) cost
    // ~5.3 ms per commit, the gap to 60 fps. Reused memory used to lose the
    // lock screen's clock text (probe100/103/107, unexplained); zero-filling
    // it with the 2D engine before the copy kept the text (probe105), and the
    // texture caches were never invalidated before the copy reads the target.
    static NSMutableDictionary<NSNumber *, SkyUpload *> *scratch;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    size_t size = ((size_t)_rt.bpr * _h + 4095) & ~(size_t)4095;
    os_unfair_lock_lock(&lock);
    if (!scratch)
        scratch = [NSMutableDictionary dictionary];
    SkyUpload *up = scratch[@(size)];
    if (!up) {
        up = [SkyUpload new];
        if (!sky_alloc(size, &up->mem)) {
            os_unfair_lock_unlock(&lock);
            return 0;
        }
        scratch[@(size)] = up;
    }
    os_unfair_lock_unlock(&lock);
    const SkyMem *u = &up->mem;
    NSMutableData *s = _s;
    uint64_t ts = sky_code.iova + CODE_TS;
    wfi(s);
    ccu_flush_wait(s, ts); // draws so far reach memory
    event(s, 0x19);        // PC_CCU_INVALIDATE_COLOR
    event(s, 0x31);        // CACHE_INVALIDATE: the copy reads the target through the TP
    wfi(s);
    {
        // zero the scratch first (2D solid fill)
        uint32_t fill = (1 << 7) | (FMT6_8_8_8_8_UNORM << 8) | (0xf << 20);
        reg1(s, 0x8c00, fill);
        reg1(s, 0x8400, fill);
        reg1(s, 0xacc0, (FMT6_8_8_8_8_UNORM << 3) | (0xf << 12));
        reg1(s, 0x8c01, 0);
        uint64_t d = u->iova;
        uint32_t info[4] = {FMT6_8_8_8_8_UNORM, (uint32_t)d, (uint32_t)(d >> 32), (uint32_t)(_rt.bpr >> 6)};
        reg(s, 0x8c17, info, 4);
        uint32_t z3[3] = {0, 0, 0}, z4[4] = {0, 0, 0, 0};
        reg(s, 0x8c20, z3, 3);
        reg(s, 0x8c2c, z4, 4);
        uint32_t tl[2] = {0, (_w - 1) | ((_h - 1) << 16)};
        reg(s, 0x8405, tl, 2);
        event(s, 0x3f);
        wfi(s);
        emit(s, pkt7(0x2c, 1));
        emit(s, 3);
        wfi(s);
        ccu_flush_wait(s, ts);
        event(s, 0x19);
        wfi(s);
    }
    uint32_t fmt = FMT6_8_8_8_8_UNORM, blt = (fmt << 8) | (0xf << 20);
    reg1(s, 0x8c00, blt);                       // RB_A2D_BLT_CNTL
    reg1(s, 0x8400, blt);                       // GRAS_A2D_BLT_CNTL
    reg1(s, 0xacc0, (fmt << 3) | (0xf << 12));  // SP_A2D_OUTPUT_INFO
    reg1(s, 0x8c01, 0);                         // RB_A2D_PIXEL_CNTL
    uint32_t zero3[3] = {0, 0, 0};
    reg(s, 0x8c20, zero3, 3);
    uint64_t src = _rt.iova + _rt.offset, dst = u->iova;
    // TPL1_A2D_SRC_TEXTURE_INFO..: RGBA8 linear, size, base, pitch (as copyRows)
    uint32_t tex[5] = {fmt | (1 << 20) | (1 << 22), _w | (_h << 15), (uint32_t)src, (uint32_t)(src >> 32),
                       (uint32_t)(_rt.bpr >> 6) << 9};
    reg(s, 0xb4c0, tex, 5);
    reg(s, 0xb4ca, zero3, 3);
    uint32_t sc[4] = {0, (_w - 1) << 8, 0, (_h - 1) << 8};
    reg(s, 0x8401, sc, 4); // GRAS_A2D_SRC_XMIN..YMAX
    uint32_t info[4] = {fmt, (uint32_t)dst, (uint32_t)(dst >> 32), (uint32_t)(_rt.bpr >> 6)};
    reg(s, 0x8c17, info, 4); // RB_A2D_DEST_BUFFER_*
    uint32_t tl[2] = {0, (_w - 1) | ((_h - 1) << 16)};
    reg(s, 0x8405, tl, 2); // GRAS_A2D_DEST_TL/BR
    event(s, 0x3f);
    wfi(s);
    emit(s, pkt7(0x2c, 1)); // CP_BLIT
    emit(s, 3);
    wfi(s);
    ccu_flush_wait(s, ts); // the copy reaches memory
    event(s, 0x19);
    event(s, 0x31); // CACHE_INVALIDATE: the texture cache sees the copy
    wfi(s);
    return dst;
}

// a draw with a compiled CoreAnimation program (SkyPrograms.h)
// perf: mach time spent in drawProg and draws, read by the commit log (SkyObjects.m)
uint64_t sky_perf_draw_ticks, sky_perf_draws, sky_perf_tex_ticks, sky_perf_fb_ticks;

- (void)drawProg:(uint32_t)initiator count:(NSUInteger)n start:(NSUInteger)first index:(uint64_t)ibuf indexSize:(uint32_t)isz {
    uint64_t t0 = mach_absolute_time();
    [self drawProgImpl:initiator count:n start:first index:ibuf indexSize:isz];
    sky_perf_draw_ticks += mach_absolute_time() - t0;
    sky_perf_draws++;
}

- (void)drawProgImpl:(uint32_t)initiator count:(NSUInteger)n start:(NSUInteger)first index:(uint64_t)ibuf indexSize:(uint32_t)isz {
    const SkyProgEntry *e = _prog;
    if (!e) {
        if (_noProg++ < 3)
            sky_log("no program: %s + %s", _vkey.UTF8String ?: "nil", _fkey.UTF8String ?: "nil");
        _skipped++;
        return;
    }
    const SkyProg *p = e->prog;
    uint64_t vs = prog_code(p, NO), fs = prog_code(p, YES);
    if (!vs || !code_ready()) {
        _skipped++;
        return;
    }
    // vertex fetch: every attribute the program reads must have a format
    uint32_t fetch[32][2], nfetch = p->nattrs, bufs = 0;
    for (uint32_t i = 0; i < nfetch; i++) {
        uint32_t a = p->attrs[i];
        if (a == 255)
            a = p->attrs[0] == 255 ? 0 : p->attrs[0];
        uint32_t f = a < 8 ? vfd_format(_vdesc.fmt[a]) : 0;
        uint32_t b = a < 8 ? _vdesc.buf[a] : 0;
        if (!f || b >= 31 || !_vtx_gpu[b]) {
            if (_noProg++ < 6)
                sky_log("draw skipped: attr %u fmt %u buf %u gpu %#llx (%s)", a, a < 8 ? _vdesc.fmt[a] : 0, b,
                        b < 32 ? _vtx_gpu[b] : 0, p->name);
            _skipped++;
            return;
        }
        fetch[i][0] = b | (_vdesc.off[a] << 5) | (f << 20) | 0xc0000000u; // IDX, OFFSET, FORMAT, FLOAT
        fetch[i][1] = 0;
        bufs |= 1u << b;
    }
    // textures and samplers
    uint32_t tex[16][16], samp[16][4];
    uint64_t fb = 0;
    for (uint32_t i = 0; i < e->ntex; i++) {
        uint32_t m = e->tex[i];
        if (m == SKY_TEX_FB) {
            uint64_t tf = mach_absolute_time();
            if (!fb)
                fb = [self fbCopy];
            sky_perf_fb_ticks += mach_absolute_time() - tf;
            if (!fb) {
                _skipped++;
                return;
            }
            memset(tex[i], 0, 64);
            tex[i][0] = (0 | 1 << 3 | 2 << 6 | 3 << 9) << 4 | (FMT6_8_8_8_8_UNORM << 22) | ((_info >> 13 & 3) << 30);
            tex[i][1] = _w | (_h << 15);
            tex[i][2] = ((uint32_t)_rt.bpr << 7) | (1u << 29);
            tex[i][4] = (uint32_t)fb;
            tex[i][5] = (uint32_t)(fb >> 32) | (1u << 17);
            continue;
        }
        uint64_t tt = mach_absolute_time();
        BOOL ok = m < 16 && [self texDesc:tex[i] texture:_texs[m]];
        sky_perf_tex_ticks += mach_absolute_time() - tt;
        if (!ok) {
            if (_noProg++ < 6)
                sky_log("draw skipped: texture slot %u (metal %u) fmt %lu (%s)", i, m,
                        m < 16 ? (unsigned long)_texs[m].pixelFormat : 0, p->name);
            _skipped++;
            return;
        }
    }
    // SP_PS_CONFIG has NSAMP = NTEX: pad the samplers with the first one
    uint32_t nsamp = MAX(MAX(e->nsamp, e->ntex), 1u);
    for (uint32_t i = 0; i < nsamp; i++) {
        const SkyProgSampler *sm = &e->samp[i < e->nsamp ? i : 0];
        memset(samp[i], 0, 16);
        samp[i][0] = sm->metal == 0xff ? const_sampler_word(sm->bits) : sky_sampler_word(sm->metal < 16 ? _samps[sm->metal] : nil);
        // pixel coordinates sampled as normalised ones read far outside the
        // texture: blocky, "pixelated" blurs
        BOOL unnorm = sm->metal == 0xff ? (sm->bits >> 15) & 1 : sky_sampler_unnorm(sm->metal < 16 ? _samps[sm->metal] : nil);
        samp[i][1] = unnorm ? 1u << 5 : 0;
    }

    // texture and sampler tables: upload memory can run out (the kernel's
    // 320 buffers per client, probe116/119), and a table at gpu 0 is an SMMU
    // fault that stops the GPU for good
    uint64_t ta = 0, sa = 0;
    if (e->ntex) {
        ta = [self upload:tex length:e->ntex * 64];
        sa = [self upload:samp length:nsamp * 16];
        if (!ta || !sa) {
            static int nlog;
            if (nlog++ < 6)
                sky_log("draw skipped: no upload memory for texture tables (%s)", p->name);
            _skipped++;
            return;
        }
    }

    NSMutableData *s = _s;
    if (_draws)
        wfi(s);
    ++sky_draw_id;
    reg1(s, 0xbb08, 0x19f); // SP_UPDATE_CNTL
    [s appendData:base_state()];
    [s appendData:prog_state(p)];
    // blend state of the pipeline
    uint32_t mctl = _mrtControl ? _mrtControl : 0x7e0;
    BOOL blend = (mctl & 3) != 0;
    reg1(s, 0x8820, mctl);                            // RB_MRT[0].CONTROL
    reg1(s, 0x8821, _mrtBlend);                       // RB_MRT[0].BLEND_CONTROL
    reg1(s, 0xa989, blend ? 0x101 : 0x100);           // SP_BLEND_CNTL
    reg1(s, 0x8865, blend ? 0xffff0101 : 0xffff0100); // RB_BLEND_CNTL
    // scissor and viewport; Metal's NDC y points up, the rasteriser's down
    uint32_t br = (_w - 1) | ((_h - 1) << 16), tl = 0;
    if (_hasScissor && _scissor.width && _scissor.height) {
        uint32_t x1 = (uint32_t)MIN(_scissor.x + _scissor.width, _w), y1 = (uint32_t)MIN(_scissor.y + _scissor.height, _h);
        tl = (uint32_t)MIN(_scissor.x, _w - 1) | ((uint32_t)MIN(_scissor.y, _h - 1) << 16);
        br = (MAX(x1, 1) - 1) | ((MAX(y1, 1) - 1) << 16);
    }
    uint32_t full = (_w - 1) | ((_h - 1) << 16);
    reg1(s, 0x80f1, full); // GRAS_SC_WINDOW_SCISSOR_BR
    reg1(s, 0x840b, full); // GRAS_A2D_SCISSOR_BR
    reg1(s, 0x80d1, full); // GRAS_SC_VIEWPORT_SCISSOR[0].BR
    reg1(s, 0x80b0, tl);   // GRAS_SC_SCREEN_SCISSOR[0].TL
    reg1(s, 0x80b1, br);   // .BR
    MTLViewport vp = _hasVP ? _vp : (MTLViewport){0, 0, _w, _h, 0, 1};
    uint32_t vpr[6] = {fbits((float)(vp.originX + vp.width / 2)), fbits((float)(vp.width / 2)),
                       fbits((float)(vp.originY + vp.height / 2)), fbits((float)(-vp.height / 2)),
                       fbits((float)vp.znear), fbits((float)(vp.zfar - vp.znear))};
    reg(s, 0x8010, vpr, 6); // GRAS_CL_VIEWPORT[0]: X/Y offset+scale, Z offset+scale
    // colour target
    uint32_t mrt[6] = {_info, (uint32_t)(_rt.bpr >> 6), 0, (uint32_t)(_rt.iova + _rt.offset),
                       (uint32_t)((_rt.iova + _rt.offset) >> 32), 0};
    reg(s, 0x8822, mrt, 6);
    reg1(s, 0xa996, FMT6_8_8_8_8_UNORM);
    uint32_t zero6[6] = {0};
    for (uint32_t i = 1; i < 8; i++) {
        reg(s, 0x8822 + 8 * i, zero6, 6);
        reg1(s, 0xa996 + i, 0);
    }
    // vertex fetch
    for (uint32_t i = 0; i < nfetch; i++)
        reg(s, 0xa090 + 2 * i, fetch[i], 2); // VFD_FETCH_INSTR[i]
    for (uint32_t b = 0; b < 31; b++) {
        if (!(bufs & (1u << b)))
            continue;
        reg64(s, 0xa010 + 4 * b, _vtx_gpu[b]);                      // VFD_VERTEX_BUFFER[b].BASE
        reg1(s, 0xa012 + 4 * b, (uint32_t)MIN(_vtx_avail[b], 0xffffffffu)); // .SIZE
        reg1(s, 0xa013 + 4 * b, _vdesc.stride[b]);                  // .STRIDE
    }
    reg1(s, 0xa00e, ibuf ? 0 : (uint32_t)first); // VFD_INDEX_OFFSET
    reg1(s, 0xa00f, 0);                          // VFD_INSTANCE_START_OFFSET
    // shaders
    reg64(s, 0xa81c, vs); // SP_VS_BASE
    reg64(s, 0xa983, fs); // SP_PS_BASE
    emit(s, pkt7(0x65, 1)); emit(s, 1);
    emit(s, pkt7(0x1d, 1)); emit(s, 0);
    emit(s, pkt7(0x64, 1)); emit(s, 1);
    emit(s, pkt7(0x63, 1)); emit(s, 0);
    emit(s, pkt7(0x32, 3)); // CP_LOAD_STATE6_GEOM: VS instructions
    emit(s, (2 << 16) | (8 << 18) | (p->vs_preload << 22));
    emit(s, (uint32_t)vs);
    emit(s, (uint32_t)(vs >> 32));
    emit(s, pkt7(0x34, 3)); // CP_LOAD_STATE6_FRAG: FS instructions
    emit(s, (2 << 16) | (0xc << 18) | (p->fs_preload << 22));
    emit(s, (uint32_t)fs);
    emit(s, (uint32_t)(fs >> 32));
    // constants: pushed buffer ranges, then immediates
    load_ubos(s, 0x32, 8, p->vs_ubo, p->vs_nubo, _vtx_cpu, _vtx_avail, 32);
    load_ubos(s, 0x34, 0xc, p->fs_ubo, p->fs_nubo, _frag_cpu, _frag_avail, 8);
    load_consts(s, 0x32, 8, p->vs_imm_base / 4, p->vs_imm, p->vs_imm_dwords / 4);
    load_consts(s, 0x34, 0xc, p->fs_imm_base / 4, p->fs_imm, p->fs_imm_dwords / 4);
    // textures and samplers
    if (e->ntex) {
        emit(s, pkt7(0x34, 3)); // samplers: ST6_SHADER, SB6_FS_TEX
        emit(s, (2 << 16) | (4 << 18) | (nsamp << 22));
        emit(s, (uint32_t)sa);
        emit(s, (uint32_t)(sa >> 32));
        reg64(s, 0xa9e0, sa); // SP_PS_SAMPLER_BASE
        emit(s, pkt7(0x34, 3)); // textures: ST6_CONSTANTS, SB6_FS_TEX
        emit(s, (1 << 14) | (2 << 16) | (4 << 18) | (e->ntex << 22));
        emit(s, (uint32_t)ta);
        emit(s, (uint32_t)(ta >> 32));
        reg64(s, 0xa9e4, ta); // SP_PS_TEXMEMOBJ_BASE
    }
    reg1(s, 0xa9a7, e->ntex); // SP_PS_TSIZE
    if (ibuf) {
        initiator |= 1 << 8; // VIS_CULL USE_VISIBILITY, SOURCE_SELECT DMA (0)
        emit(s, pkt7(0x38, 7)); // CP_DRAW_INDX_OFFSET
        emit(s, initiator);
        emit(s, 1);
        emit(s, (uint32_t)n);
        emit(s, 0);
        emit(s, (uint32_t)ibuf);
        emit(s, (uint32_t)(ibuf >> 32));
        emit(s, (uint32_t)n); // MAX_INDICES
    } else {
        emit(s, pkt7(0x38, 3)); // CP_DRAW_INDX_OFFSET: auto index
        emit(s, initiator);
        emit(s, 1);
        emit(s, (uint32_t)n);
    }
    _draws++;
    _progDraws++;
}

// cp3d.rs emit_state + emit_draw, viewport/scissors for the whole target
- (void)draw:(uint32_t)initiator count:(NSUInteger)n start:(NSUInteger)first {
    if (_prog || [_vname hasPrefix:@"fixed_vert"] || [_vname hasPrefix:@"std_vert"]) {
        [self drawProg:initiator count:n start:first index:0 indexSize:0];
        return;
    }
    int prog = [self resolveProgram];
    if (prog >= 0 && prog < 6) _progcount[prog]++;
    BOOL textured = prog >= 0 && sky_programs[prog].textured;
    BOOL fbfetch_prog = prog >= 0 && sky_programs[prog].fbfetch;
    uint64_t desc = textured ? (fbfetch_prog ? [self fbFetchDescriptor] : [self textureDescriptor]) : 0;
    BOOL mvp_early = prog >= 0 && sky_programs[prog].mvp;
    uint64_t vb_check = _vb;
    if (mvp_early) {
        for (int vi = 0; vi < 32 && !vb_check; vi++)
            vb_check = _vtx_gpu[vi];
    }
    if (prog < 0 || !vb_check || (textured && !desc)) {
        if (_skipped++ < 5)
            sky_log("draw skipped: prog=%d vb=%llx tex=%d desc=%llx first=%lu n=%lu %s + %s",
                    prog, vb_check, textured, desc, (unsigned long)first, (unsigned long)n,
                    _vname.UTF8String ?: "nil", _fname.UTF8String ?: "nil");
        return;
    }
    uint64_t fs = sky_programs[prog].code;
    NSMutableData *s = _s;
    // a previous draw of this pass may still run: the full state below
    // (SP/HLSQ config, shader and const loads) must not change under it
    if (_draws)
        wfi(s);
    uint32_t id = ++sky_draw_id;
    mark(s, id << 4 | 1);
    reg1(s, 0xbb08, 0x19f); // SP_UPDATE_CNTL
    for (size_t i = 0; i < sizeof(CP3D_STATE) / sizeof(CP3D_STATE[0]); i++)
        reg1(s, CP3D_STATE[i][0], CP3D_STATE[i][1]);
    if (textured)
        for (size_t i = 0; i < sizeof(CP3D_TEXQ) / sizeof(CP3D_TEXQ[0]); i++)
            reg1(s, CP3D_TEXQ[i][0], CP3D_TEXQ[i][1]);
    // blend state of the pipeline (STATE has blending off, all components)
    uint32_t mctl = _mrtControl ? _mrtControl : 0x7e0, mbl = _mrtBlend;
    if (prog == PROG_TEX_OVER) {
        mctl = (mctl & 0x780) | (0xc << 3) | 3; // ROP COPY, colour + alpha blend
        mbl = 0x07010701;                       // ONE, ADD, ONE_MINUS_SRC_ALPHA (rgb and alpha)
    }
    BOOL blend = (mctl & 3) != 0;
    reg1(s, 0x8820, mctl); // RB_MRT[0].CONTROL
    reg1(s, 0x8821, mbl);  // RB_MRT[0].BLEND_CONTROL
    reg1(s, 0xa989, blend ? 0x101 : 0x100);              // SP_BLEND_CNTL: ENABLE_BLEND mrt0
    reg1(s, 0x8865, blend ? 0xffff0101 : 0xffff0100);    // RB_BLEND_CNTL: BLEND_READS_DEST mrt0
    uint32_t br = (_w - 1) | ((_h - 1) << 16);
    reg1(s, 0x80f1, br); // GRAS_SC_WINDOW_SCISSOR_BR
    reg1(s, 0x840b, br); // GRAS_A2D_SCISSOR_BR
    reg1(s, 0x80d1, br); // GRAS_SC_VIEWPORT_SCISSOR[0].BR
    reg1(s, 0x80b1, br); // GRAS_SC_SCREEN_SCISSOR[0].BR
    // GRAS_CL_VIEWPORT[0]: x offset, scale, y offset, scale
    if (_hasVP) {
        float xo = (float)(_vp.originX + _vp.width / 2.0);
        float xs = (float)(_vp.width / 2.0);
        float yo = (float)(_vp.originY + _vp.height / 2.0);
        float ys = (float)(_vp.height / 2.0);
        uint32_t vp[4] = {fbits(xo), fbits(xs), fbits(yo), fbits(ys)};
        reg(s, 0x8010, vp, 4);
    } else {
        uint32_t vp[4] = {fbits(_w / 2.0f), fbits(_w / 2.0f), fbits(_h / 2.0f), fbits(_h / 2.0f)};
        reg(s, 0x8010, vp, 4);
    }
    reg1(s, 0xa012, (uint32_t)((textured ? 24 : 16) * n)); // VFD_VERTEX_BUFFER[0].SIZE
    uint32_t mrt[6] = {_info, (uint32_t)(_rt.bpr >> 6), 0, (uint32_t)(_rt.iova + _rt.offset),
                       (uint32_t)((_rt.iova + _rt.offset) >> 32), 0};
    reg(s, 0x8822, mrt, 6);
    reg1(s, 0xa996, FMT6_8_8_8_8_UNORM);
    uint32_t zero6[6] = {0};
    for (uint32_t i = 1; i < 8; i++) {
        reg(s, 0x8822 + 8 * i, zero6, 6);
        reg1(s, 0xa996 + i, 0);
    }
    BOOL mvp = prog >= 0 && sky_programs[prog].mvp;
    uint64_t vb_draw = _vb;
    if (mvp) {
        // CA puts vertex data at idx 2, matrix at idx 1; use idx 2 for VFD if available
        if (_vtx_gpu[2]) vb_draw = _vtx_gpu[2];
        else if (_vtx_gpu[30]) vb_draw = _vtx_gpu[30];
    }
    uint64_t vs = sky_code.iova + (mvp ? CODE_VS_MVP : CODE_VS);
    uint64_t fsa = sky_code.iova + (uint64_t)fs;
    if (mvp) {
        reg1(s, 0xa800, 0x00100180); // SP_VS_CNTL_0: MERGEDREGS, FULLREGFOOTPRINT=6
        reg1(s, 0xa824, 3);          // SP_VS_INSTR_SIZE: 3 (48 instructions)
    }
    reg64(s, 0xa81c, vs);
    reg64(s, 0xa983, fsa);
    reg64(s, 0xa010, vb_draw);
    emit(s, pkt7(0x65, 1)); emit(s, 1);
    emit(s, pkt7(0x1d, 1)); emit(s, 0);
    emit(s, pkt7(0x64, 1)); emit(s, 1);
    emit(s, pkt7(0x63, 1)); emit(s, 0);
    emit(s, pkt7(0x32, 3)); // CP_LOAD_STATE6_GEOM: VS icache
    emit(s, (2 << 16) | (8 << 18) | ((mvp ? 3u : 1u) << 22));
    emit(s, (uint32_t)vs);
    emit(s, (uint32_t)(vs >> 32));
    // VS constants: try idx 1 (CA's matrix buffer), then idx 0 (Apple convention)
    uint64_t vs_const = _vtx_gpu[1] ? _vtx_gpu[1] : _vtx_gpu[0];
    NSUInteger vs_const_len = _vtx_gpu[1] ? _vtx_len[1] : _vtx_len[0];
    if (mvp && vs_const && vs_const_len >= 64) {
        emit(s, pkt7(0x32, 3)); // CP_LOAD_STATE6_GEOM: VS constants c0-c3
        emit(s, (1 << 14) | (2 << 16) | (8 << 18) | (4u << 22));
        emit(s, (uint32_t)vs_const);
        emit(s, (uint32_t)(vs_const >> 32));
    }
    emit(s, pkt7(0x34, 3)); // CP_LOAD_STATE6_FRAG: FS icache
    emit(s, (2 << 16) | (0xc << 18) | (1 << 22));
    emit(s, (uint32_t)fsa);
    emit(s, (uint32_t)(fsa >> 32));
    // no FS constants: the built-in fragment programs read none (the bound
    // buffer's whole length, 256 KiB, overflowed CONSTLEN and NUM_UNIT)
    if (textured) {
        uint32_t tex_count = fbfetch_prog ? 2 : 1;
        uint64_t samp = desc + (fbfetch_prog ? 128 : 64);
        emit(s, pkt7(0x34, 3)); // samplers
        emit(s, (2 << 16) | (4 << 18) | (tex_count << 22)); // ST6_SHADER, SB6_FS_TEX, NUM_UNIT
        emit(s, (uint32_t)samp);
        emit(s, (uint32_t)(samp >> 32));
        reg64(s, 0xa9e0, samp);  // SP_PS_SAMPLER_BASE
        emit(s, pkt7(0x34, 3)); // textures: ST6_CONSTANTS, SB6_FS_TEX
        emit(s, (1 << 14) | (2 << 16) | (4 << 18) | (tex_count << 22)); // ST6_CONSTANTS, SB6_FS_TEX, NUM_UNIT
        emit(s, (uint32_t)desc);
        emit(s, (uint32_t)(desc >> 32));
        reg64(s, 0xa9e4, desc);  // SP_PS_TEXMEMOBJ_BASE
        reg1(s, 0xa9a7, tex_count); // SP_PS_TSIZE
        if (fbfetch_prog) {
            // override TEXQ's prefetch count: 2 prefetches + second index
            reg1(s, 0xa99e, 0x12);    // SP_PS_INITIAL_TEX_LOAD_CNTL: 2 tex, ENDOFQUAD
            reg1(s, 0xa9a4, 1);       // SP_PS_INITIAL_TEX_INDEX[1]: texture slot 1
        }
    }
    emit(s, pkt7(0x38, 3)); // CP_DRAW_INDX_OFFSET: auto index, use visibility
    emit(s, initiator);
    emit(s, 1);
    emit(s, (uint32_t)n);
    mark(s, id << 4 | 2);
    mark_done(s, id << 4 | 3);
    _draws++;
}

- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)st vertexCount:(NSUInteger)n {
    if (t == MTLPrimitiveTypeTriangle)
        [self draw:0x184 count:n start:st];
    else if (t == MTLPrimitiveTypeTriangleStrip)
        [self draw:0x186 count:n start:st];
}

- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)st vertexCount:(NSUInteger)n instanceCount:(NSUInteger)ic {
    if (ic == 1)
        [self drawPrimitives:t vertexStart:st vertexCount:n];
}

// indexed draw: CP_DRAW_INDX_OFFSET with 7 dwords (SOURCE_SELECT=DMA)
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset {
    [self drawIndexedPrimitives:t indexCount:indexCount indexType:indexType indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset instanceCount:1];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount {
    if (instanceCount != 1)
        return;
    [self keep:indexBuffer];
    uint32_t prim = (t == MTLPrimitiveTypeTriangleStrip) ? 6 : 4;
    // INDEX_SIZE (a4xx_index_size): 0 = 8 bit, 1 = 16 bit, 2 = 32 bit
    uint32_t idxSize = (indexType == MTLIndexTypeUInt32) ? 2 : 1;
    // SOURCE_SELECT=0 (DMA/indexed), VIS_CULL=1 (USE_VISIBILITY), INDEX_SIZE
    uint32_t initiator = prim | (0 << 6) | (1 << 8) | (idxSize << 10);

    if (!indexBuffer.gpuAddress) {
        _skipped++;
        return;
    }
    if (_prog || [_vname hasPrefix:@"fixed_vert"] || [_vname hasPrefix:@"std_vert"]) {
        [self drawProg:initiator count:indexCount start:0 index:indexBuffer.gpuAddress + indexBufferOffset
             indexSize:indexType == MTLIndexTypeUInt32 ? 4 : 2];
        return;
    }
    int prog = [self resolveProgram];
    if (prog >= 0 && prog < 6) _progcount[prog]++;
    static int idxlog;
    if (idxlog++ < 5)
        sky_log("indexed draw: prog=%d %s + %s n=%lu", prog,
                _vname.UTF8String ?: "nil", _fname.UTF8String ?: "nil", (unsigned long)indexCount);
    BOOL textured = prog >= 0 && sky_programs[prog].textured;
    BOOL fbfetch_prog = prog >= 0 && sky_programs[prog].fbfetch;
    uint64_t desc = textured ? (fbfetch_prog ? [self fbFetchDescriptor] : [self textureDescriptor]) : 0;
    BOOL mvp_early = prog >= 0 && sky_programs[prog].mvp;
    uint64_t vb_check = _vb;
    if (mvp_early) {
        for (int vi = 0; vi < 32 && !vb_check; vi++)
            vb_check = _vtx_gpu[vi];
    }
    if (prog < 0 || !vb_check || (textured && !desc)) {
        if (_skipped++ < 5)
            sky_log("indexed draw skipped: prog=%d vb=%llx tex=%d desc=%llx idxBuf=%p n=%lu %s + %s",
                    prog, vb_check, textured, desc, indexBuffer, (unsigned long)indexCount,
                    _vname.UTF8String ?: "nil", _fname.UTF8String ?: "nil");
        return;
    }

    uint64_t fs = sky_programs[prog].code;
    NSMutableData *s = _s;
    if (_draws)
        wfi(s); // see draw:count:start:
    uint32_t id = ++sky_draw_id;
    mark(s, id << 4 | 1);
    reg1(s, 0xbb08, 0x19f);
    for (size_t i = 0; i < sizeof(CP3D_STATE) / sizeof(CP3D_STATE[0]); i++)
        reg1(s, CP3D_STATE[i][0], CP3D_STATE[i][1]);
    if (textured)
        for (size_t i = 0; i < sizeof(CP3D_TEXQ) / sizeof(CP3D_TEXQ[0]); i++)
            reg1(s, CP3D_TEXQ[i][0], CP3D_TEXQ[i][1]);
    uint32_t mctl = _mrtControl ? _mrtControl : 0x7e0, mbl = _mrtBlend;
    if (prog == PROG_TEX_OVER) {
        mctl = (mctl & 0x780) | (0xc << 3) | 3; // ROP COPY, colour + alpha blend
        mbl = 0x07010701;                       // ONE, ADD, ONE_MINUS_SRC_ALPHA (rgb and alpha)
    }
    BOOL blend = (mctl & 3) != 0;
    reg1(s, 0x8820, mctl); // RB_MRT[0].CONTROL
    reg1(s, 0x8821, mbl);  // RB_MRT[0].BLEND_CONTROL
    reg1(s, 0xa989, blend ? 0x101 : 0x100);
    reg1(s, 0x8865, blend ? 0xffff0101 : 0xffff0100);
    uint32_t br = (_w - 1) | ((_h - 1) << 16);
    reg1(s, 0x80f1, br);
    reg1(s, 0x840b, br);
    reg1(s, 0x80d1, br);
    reg1(s, 0x80b1, br);
    if (_hasVP) {
        float xo = (float)(_vp.originX + _vp.width / 2.0);
        float xs = (float)(_vp.width / 2.0);
        float yo = (float)(_vp.originY + _vp.height / 2.0);
        float ys = (float)(_vp.height / 2.0);
        uint32_t vpv[4] = {fbits(xo), fbits(xs), fbits(yo), fbits(ys)};
        reg(s, 0x8010, vpv, 4);
    } else {
        uint32_t vpv[4] = {fbits(_w / 2.0f), fbits(_w / 2.0f), fbits(_h / 2.0f), fbits(_h / 2.0f)};
        reg(s, 0x8010, vpv, 4);
    }
    uint32_t stride = textured ? 24 : 16;
    reg1(s, 0xa012, (uint32_t)(stride * indexCount)); // VFD_VERTEX_BUFFER[0].SIZE (upper bound)
    uint32_t mrt[6] = {_info, (uint32_t)(_rt.bpr >> 6), 0, (uint32_t)(_rt.iova + _rt.offset),
                       (uint32_t)((_rt.iova + _rt.offset) >> 32), 0};
    reg(s, 0x8822, mrt, 6);
    reg1(s, 0xa996, FMT6_8_8_8_8_UNORM);
    uint32_t zero6[6] = {0};
    for (uint32_t i = 1; i < 8; i++) {
        reg(s, 0x8822 + 8 * i, zero6, 6);
        reg1(s, 0xa996 + i, 0);
    }
    BOOL mvp = prog >= 0 && sky_programs[prog].mvp;
    uint64_t vb_draw = _vb;
    if (mvp) {
        if (_vtx_gpu[2]) vb_draw = _vtx_gpu[2];
        else if (_vtx_gpu[30]) vb_draw = _vtx_gpu[30];
    }
    uint64_t vs = sky_code.iova + (mvp ? CODE_VS_MVP : CODE_VS);
    uint64_t fsa = sky_code.iova + (uint64_t)fs;
    if (mvp) {
        reg1(s, 0xa800, 0x00100180); // SP_VS_CNTL_0: MERGEDREGS, FULLREGFOOTPRINT=6
        reg1(s, 0xa824, 3);          // SP_VS_INSTR_SIZE: 3 (48 instructions)
    }
    reg64(s, 0xa81c, vs);
    reg64(s, 0xa983, fsa);
    reg64(s, 0xa010, vb_draw);
    emit(s, pkt7(0x65, 1)); emit(s, 1);
    emit(s, pkt7(0x1d, 1)); emit(s, 0);
    emit(s, pkt7(0x64, 1)); emit(s, 1);
    emit(s, pkt7(0x63, 1)); emit(s, 0);
    emit(s, pkt7(0x32, 3)); // CP_LOAD_STATE6_GEOM: VS icache
    emit(s, (2 << 16) | (8 << 18) | ((mvp ? 3u : 1u) << 22));
    emit(s, (uint32_t)vs); emit(s, (uint32_t)(vs >> 32));
    uint64_t vs_const = _vtx_gpu[1] ? _vtx_gpu[1] : _vtx_gpu[0];
    NSUInteger vs_const_len = _vtx_gpu[1] ? _vtx_len[1] : _vtx_len[0];
    if (mvp && vs_const && vs_const_len >= 64) {
        emit(s, pkt7(0x32, 3)); // CP_LOAD_STATE6_GEOM: VS constants c0-c3
        emit(s, (1 << 14) | (2 << 16) | (8 << 18) | (4u << 22));
        emit(s, (uint32_t)vs_const);
        emit(s, (uint32_t)(vs_const >> 32));
    }
    static int mvplog;
    if (mvp && mvplog++ < 5)
        sky_log("mvp draw: vb=%llx vb0=%llx vb1=%llx vb2=%llx vb30=%llx vs_const=%llx len=%lu stride=%u",
                vb_draw, _vtx_gpu[0], _vtx_gpu[1], _vtx_gpu[2], _vtx_gpu[30],
                vs_const, (unsigned long)vs_const_len, stride);
    emit(s, pkt7(0x34, 3)); // CP_LOAD_STATE6_FRAG: FS icache
    emit(s, (2 << 16) | (0xc << 18) | (1 << 22));
    emit(s, (uint32_t)fsa); emit(s, (uint32_t)(fsa >> 32));
    // no FS constants: the built-in fragment programs read none (the bound
    // buffer's whole length, 256 KiB, overflowed CONSTLEN and NUM_UNIT)
    if (textured) {
        uint32_t tex_count = fbfetch_prog ? 2 : 1;
        uint64_t samp = desc + (fbfetch_prog ? 128 : 64);
        emit(s, pkt7(0x34, 3)); // samplers
        emit(s, (2 << 16) | (4 << 18) | (tex_count << 22)); // ST6_SHADER, SB6_FS_TEX, NUM_UNIT
        emit(s, (uint32_t)samp); emit(s, (uint32_t)(samp >> 32));
        reg64(s, 0xa9e0, samp);
        emit(s, pkt7(0x34, 3)); // textures
        emit(s, (1 << 14) | (2 << 16) | (4 << 18) | (tex_count << 22)); // ST6_CONSTANTS, SB6_FS_TEX, NUM_UNIT
        emit(s, (uint32_t)desc); emit(s, (uint32_t)(desc >> 32));
        reg64(s, 0xa9e4, desc);
        reg1(s, 0xa9a7, tex_count);
        if (fbfetch_prog) {
            reg1(s, 0xa99e, 0x12);
            reg1(s, 0xa9a4, 1);
        }
    }
    // indexed draw: CP_DRAW_INDX_OFFSET with 7 dwords
    uint64_t idxGpu = indexBuffer.gpuAddress + indexBufferOffset;
    uint32_t idxBytes = (uint32_t)(indexCount * (indexType == MTLIndexTypeUInt32 ? 4 : 2));
    emit(s, pkt7(0x38, 7)); // CP_DRAW_INDX_OFFSET
    emit(s, initiator);
    emit(s, 1);                        // NUM_INSTANCES
    emit(s, (uint32_t)indexCount);     // NUM_INDICES
    emit(s, 0);                        // FIRST_INDX
    emit(s, (uint32_t)idxGpu);        // INDX_BASE lo
    emit(s, (uint32_t)(idxGpu >> 32)); // INDX_BASE hi
    emit(s, (uint32_t)(indexCount));   // MAX_INDICES
    mark(s, id << 4 | 2);
    mark_done(s, id << 4 | 3);
    _draws++;
}

// colour to memory, caches dropped (later passes may sample this target)
- (void)endEncoding {
    static int nlog;
    if (nlog++ < 10)
        sky_log("GPU endEncoding: %lu draws (%lu compiled), %lu skipped | p0=%d p1=%d p2=%d p3=%d p4=%d p5=%d",
                (unsigned long)_draws, (unsigned long)_progDraws, (unsigned long)_skipped,
                _progcount[0], _progcount[1], _progcount[2], _progcount[3], _progcount[4], _progcount[5]);
    uint64_t ts = sky_code.iova + CODE_TS;
    event_ts(_s, 0x1d, ts, 0x40); // PC_CCU_FLUSH_COLOR_TS
    event(_s, 0x19);              // PC_CCU_INVALIDATE_COLOR
    wfi(_s);
    event(_s, 0x31);              // CACHE_INVALIDATE
    wfi(_s);
    if (nlog > 5 && nlog <= 8 && _rtSurf) {
        IOSurfaceRef s = (IOSurfaceRef)CFRetain(_rtSurf);
        uint32_t w = _w;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            uint8_t *base = IOSurfaceGetBaseAddress(s);
            size_t bpr = IOSurfaceGetBytesPerRow(s);
            size_t h = IOSurfaceGetHeight(s);
            if (base && bpr > 0 && h > 0) {
                uint32_t px0 = *(uint32_t *)base;
                uint32_t pxm = *(uint32_t *)(base + (h/2) * bpr + (w/2) * 4);
                uint32_t nonzero = 0;
                for (size_t y = 0; y < h; y += h/8)
                    for (size_t x = 0; x < w; x += w/8)
                        if (*(uint32_t *)(base + y * bpr + x * 4))
                            nonzero++;
                sky_log("PROBE rt %zux%zu: px(0,0)=%#x px(mid)=%#x nonzero=%u/81",
                        (size_t)w, h, px0, pxm, nonzero);
            }
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            CFRelease(s);
        });
    }
}

- (void)setViewport:(MTLViewport)v { _vp = v; _hasVP = YES; }
- (void)setScissorRect:(MTLScissorRect)r {
    _scissor = r;
    _hasScissor = YES;
}
- (void)setCullMode:(MTLCullMode)m {}
- (void)setFrontFacingWinding:(MTLWinding)w {}
- (void)setTriangleFillMode:(MTLTriangleFillMode)m {}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s {}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {
    [self keep:b];
    if (i < 8) {
        _frag_cpu[i] = (const uint8_t *)b.contents + o;
        _frag_avail[i] = b.length > o ? b.length - o : 0;
        _frag_base[i] = b.gpuAddress;
        _frag_gpu[i] = b.gpuAddress + o;
        _frag_len[i] = b.length;
    }
    static int nlog;
    if (nlog++ < 10)
        sky_log("setFragmentBuffer idx=%lu len=%lu off=%lu", (unsigned long)i, (unsigned long)b.length, (unsigned long)o);
}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i {
    if (i < 8) {
        _frag_gpu[i] = [self upload:p length:l];
        _frag_cpu[i] = sky_last_upload_cpu;
        _frag_avail[i] = l;
        _frag_len[i] = l;
    }
    static int nlog;
    if (nlog++ < 10)
        sky_log("setFragmentBytes idx=%lu len=%lu", (unsigned long)i, (unsigned long)l);
}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {
    if (i < 8) {
        if (_frag_cpu[i]) {
            int64_t d = (int64_t)(_frag_base[i] + o) - (int64_t)_frag_gpu[i];
            _frag_cpu[i] += d;
            _frag_avail[i] = (NSUInteger)MAX((int64_t)_frag_avail[i] - d, 0);
        }
        _frag_gpu[i] = _frag_base[i] + o;
    }
}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {
    static int tlog; if (tlog++ < 8) sky_log("setFragmentTexture idx=%lu tex=%p fmt=%lu", (unsigned long)i, t, t ? (unsigned long)t.pixelFormat : 0);
    [self keep:t];
    if (i < 16)
        _texs[i] = t;
    if (t) _tex = t;
}

// A6XX_TEX_MEMOBJ + sampler (cp3d.rs tex_desc) for fragment texture 0, an
// IOSurface in BGRA8: FMT6_8_8_8_8_UNORM, swap WXYZ, linear; bilinear, clamp
- (BOOL)resolveTexGpu:(uint64_t *)outBase bpr:(uint32_t *)outBpr {
    IOSurfaceRef surf = _tex.iosurface;
    if (surf) {
        SkyImport im;
        MTLPixelFormat f = _tex.pixelFormat;
        if ((f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB && f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB) || !import_surface(surf, &im) || (im.bpr & 63))
            return NO;
        *outBase = im.iova + im.offset;
        *outBpr = (uint32_t)im.bpr;
        return YES;
    }
    if ([_tex respondsToSelector:@selector(skyBufGpu)]) {
        uint64_t bg = ((uint64_t (*)(id, SEL))objc_msgSend)(_tex, @selector(skyBufGpu));
        MTLPixelFormat bf = _tex.pixelFormat;
        // the descriptor is RGBA8 only: an A8/RG8 buffer read as RGBA8 runs
        // past the rows (and the buffer)
        if (bg && bf != MTLPixelFormatBGRA8Unorm && bf != MTLPixelFormatBGRA8Unorm_sRGB &&
            bf != MTLPixelFormatRGBA8Unorm && bf != MTLPixelFormatRGBA8Unorm_sRGB) {
            static int nlf; if (nlf++ < 3) sky_log("texGpu: buf fmt %lu not RGBA8, skipped", (unsigned long)bf);
            return NO;
        }
        if (bg) {
            NSUInteger off = ((NSUInteger (*)(id, SEL))objc_msgSend)(_tex, @selector(skyBufOff));
            NSUInteger bpr = ((NSUInteger (*)(id, SEL))objc_msgSend)(_tex, @selector(skyBufBpr));
            if (bpr & 63) {
                static int nl; if (nl++ < 3) sky_log("texGpu: buf bpr %lu not aligned", (unsigned long)bpr);
                return NO;
            }
            *outBase = bg + off;
            *outBpr = (uint32_t)bpr;
            static int nl2; if (nl2++ < 3) sky_log("texGpu: buf %#llx off %lu bpr %lu fmt %lu",
                bg, (unsigned long)off, (unsigned long)bpr, (unsigned long)_tex.pixelFormat);
            return YES;
        }
        static int nl3; if (nl3++ < 3) sky_log("texGpu: buf gpu=0, tex %p fmt %lu", _tex, (unsigned long)_tex.pixelFormat);
    } else {
        static int nl4; if (nl4++ < 3) sky_log("texGpu: no iosurface, no skyBufGpu, tex %p fmt %lu class %s",
            _tex, (unsigned long)_tex.pixelFormat, NSStringFromClass([_tex class]).UTF8String);
    }
    return NO;
}
- (uint64_t)textureDescriptor {
    uint64_t base; uint32_t bpr;
    if (![self resolveTexGpu:&base bpr:&bpr]) return 0;
    uint32_t d[20] = {0x4c006880, (uint32_t)_tex.width | ((uint32_t)_tex.height << 15), 2 | (bpr << 7) | (1u << 29), 0,
                      (uint32_t)base, (uint32_t)(base >> 32) | (1u << 17)};
    d[16] = 0x92a;
    d[17] = 0x40;
    return [self upload:d length:sizeof(d)];
}
// Combined descriptor for fbfetch: tex0 = layer, tex1 = render target (self-
// sample); sampler0 = bilinear clamp, sampler1 = nearest clamp. Returns the
// GPU address of the texture array; samplers are at +128 (2 * 16 dwords * 4).
- (uint64_t)fbFetchDescriptor {
    uint64_t base; uint32_t bpr;
    if (![self resolveTexGpu:&base bpr:&bpr]) return 0;
    uint64_t rtbase = _rt.iova + _rt.offset;
    if (sky_draw_id + 1 >= 70 && sky_draw_id + 1 <= 80)
        sky_log("fbfetch id %u: tex %lux%lu fmt %lu %#llx bpr %u | rt %ux%u %#llx bpr %llu",
                sky_draw_id + 1, (unsigned long)_tex.width, (unsigned long)_tex.height,
                (unsigned long)_tex.pixelFormat, base, bpr, _w, _h, rtbase, (unsigned long long)_rt.bpr);
    uint32_t d[40] = {0};
    // tex0: layer texture (same as textureDescriptor)
    d[0] = 0x4c006880;
    d[1] = (uint32_t)_tex.width | ((uint32_t)_tex.height << 15);
    d[2] = 2 | (bpr << 7) | (1u << 29);
    d[4] = (uint32_t)base;
    d[5] = (uint32_t)(base >> 32) | (1u << 17);
    // tex1: render target (fb self-sample), same format/layout
    d[16] = 0x4c006880;
    d[17] = (_w) | ((uint32_t)_h << 15);
    d[18] = 2 | ((uint32_t)_rt.bpr << 7) | (1u << 29);
    d[20] = (uint32_t)rtbase;
    d[21] = (uint32_t)(rtbase >> 32) | (1u << 17);
    // sampler0: bilinear, clamp (0x92a, 0x40)
    d[32] = 0x92a;
    d[33] = 0x40;
    // sampler1: nearest, clamp (for fb fetch - exact pixel)
    d[36] = 0x920;
    d[37] = 0x40;
    return [self upload:d length:sizeof(d)];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {
    if (i < 16)
        _samps[i] = s;
}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}
@end

#pragma mark - pass set-up

// cp3d.rs emit_init, then the clear: 2D solid fill of the whole target
static void begin_pass(NSMutableData *s, SkyImport rt, uint32_t w, uint32_t h, MTLRenderPassColorAttachmentDescriptor *c) {
    uint64_t ts = sky_code.iova + CODE_TS, border = sky_code.iova + CODE_BORDER;
    event(s, 0x31);            // CACHE_INVALIDATE
    reg1(s, 0xbb08, 0x000fffff);
    wfi(s);
    for (size_t i = 0; i < sizeof(CP3D_INIT) / sizeof(CP3D_INIT[0]); i++)
        reg1(s, CP3D_INIT[i][0], CP3D_INIT[i][1]);
    reg64(s, 0xb302, border);  // TPL1_GFX_BORDER_COLOR_BASE
    reg64(s, 0xb180, border);  // TPL1_CS_BORDER_COLOR_BASE
    emit(s, pkt7(0x43, 3));    // CP_SET_DRAW_STATE: DISABLE_ALL_GROUPS
    emit(s, 1 << 18);
    emit(s, 0);
    emit(s, 0);
    event_ts(s, 0x1d, ts, 0x10);
    event_ts(s, 0x1c, ts, 0x11);
    event(s, 0x19);
    event(s, 0x18);
    wfi(s);
    reg1(s, 0x8e07, CCU_CNTL_BYPASS);
    if (c.loadAction != MTLLoadActionClear)
        return;
    // clear colour as UNORM8 per channel; RB writes R into the low byte, so
    // swap R/B for BGRA memory order
    MTLClearColor cc = c.clearColor;
    BOOL bgra = c.texture.pixelFormat == MTLPixelFormatBGRA8Unorm || c.texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
    double ch[4] = {bgra ? cc.blue : cc.red, cc.green, bgra ? cc.red : cc.blue, cc.alpha};
    uint32_t rgba[4];
    for (int i = 0; i < 4; i++)
        rgba[i] = (uint32_t)lround(fmin(fmax(ch[i], 0), 1) * 255);
    uint32_t blt = (1 << 7) | (FMT6_8_8_8_8_UNORM << 8) | (0xf << 20);
    reg1(s, 0x8c00, blt);                                      // RB_A2D_BLT_CNTL
    reg1(s, 0x8400, blt);                                      // GRAS_A2D_BLT_CNTL
    reg1(s, 0xacc0, (FMT6_8_8_8_8_UNORM << 3) | (0xf << 12));  // SP_A2D_OUTPUT_INFO
    reg1(s, 0x8c01, 0);                                        // RB_A2D_PIXEL_CNTL
    uint64_t base = rt.iova + rt.offset;
    uint32_t info[4] = {FMT6_8_8_8_8_UNORM, (uint32_t)base, (uint32_t)(base >> 32), (uint32_t)(rt.bpr >> 6)};
    reg(s, 0x8c17, info, 4);                                   // RB_A2D_DEST_BUFFER_*
    uint32_t zero3[3] = {0, 0, 0};
    reg(s, 0x8c20, zero3, 3);
    reg(s, 0x8c2c, rgba, 4);                                   // RB_A2D_CLEAR_COLOR_DW0..3
    uint32_t tl[2] = {0, (w - 1) | ((h - 1) << 16)};
    reg(s, 0x8405, tl, 2);                                     // GRAS_A2D_DEST_TL/BR
    event(s, 0x3f);                                            // FD_LABEL
    wfi(s);
    emit(s, pkt7(0x2c, 1));                                    // CP_BLIT
    emit(s, 3);                                                // BLIT_OP_SCALE
    wfi(s);
    event_ts(s, 0x1d, ts, 0x12);
    event(s, 0x19);
    wfi(s);
}

id sky_draw_encoder(id<MTLDevice> dev, MTLRenderPassDescriptor *d, NSMutableData *stream, id owner) {
    MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[0];
    id<MTLTexture> t = c.texture;
    IOSurfaceRef surf = t.iosurface;
    MTLPixelFormat f = t.pixelFormat;
    BOOL fmt_ok = f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB ||
                  f == MTLPixelFormatRGBA8Unorm_sRGB;
    SkyImport rt = {0};
    BOOL cr = code_ready();
    // a render target is flushed from the CPU caches once, on its first use:
    // only the GPU writes it afterwards (flushing it on every submit cost
    // ~1 ms each), but a new surface can hold dirty lines from its zero fill
    // whose eviction would overwrite what the GPU drew (lock screen text went
    // missing without any flush, probe100)
    BOOL imp = cr && surf && import_surface(surf, &rt);
    if (imp) {
        static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
        static NSMutableSet<NSNumber *> *flushed;
        os_unfair_lock_lock(&lock);
        if (!flushed)
            flushed = [NSMutableSet set];
        NSNumber *sid = @(IOSurfaceGetID(surf));
        BOOL first = ![flushed containsObject:sid];
        if (first)
            [flushed addObject:sid];
        os_unfair_lock_unlock(&lock);
        if (first)
            note_surface(owner, &rt);
    }
    if (!surf || !fmt_ok || !cr || !imp || (rt.bpr & 63)) {
        static int n;
        if (n++ < 40)
            sky_log("draw encoder rejected: surf=%p fmt=%d(%s) code=%d imp=%d bpr=%llu conn=%#x",
                    surf, (int)f, fmt_ok ? "ok" : "bad", cr, imp, (unsigned long long)rt.bpr, sky_conn);
        return nil;
    }
    static BOOL first_ok;
    if (!first_ok) {
        first_ok = YES;
        sky_log("draw encoder ACCEPTED: %ux%u bpr=%llu gpu=%#llx", (uint32_t)t.width, (uint32_t)t.height, (unsigned long long)rt.bpr, (unsigned long long)rt.iova);
    }
    uint32_t w = (uint32_t)t.width, h = (uint32_t)t.height;
    begin_pass(stream, rt, w, h, c);
    // BGRA memory order: COLOR_SWAP WXYZ (a3xx_color_swap 1) in RB_MRT[0].BUF_INFO
    BOOL bgra = f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB;
    uint32_t info = FMT6_8_8_8_8_UNORM | ((bgra ? 1u : 0u) << 13);
    SkyDrawEncoder *e = [[SkyDrawEncoder alloc] initWithStream:stream owner:owner target:rt surface:surf width:w height:h info:info];
    e.device = dev;
    return e;
}
