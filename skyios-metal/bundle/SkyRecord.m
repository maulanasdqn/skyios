// Recording stand-ins for what CoreAnimation asks of Metal before the
// Adreno can draw it: libraries, functions (with their function constant
// values, captured by swizzling MTLFunctionConstantValues), pipeline states,
// textures (incl. IOSurface ones), samplers, depth/stencil states and render
// encoders. Nothing is drawn; each distinct request is logged once, so a
// boot lists the shader specialisations and state the GPU path must cover.

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

#import "SkyMetal.h"
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#include <os/lock.h>

#define SKY_LOG_MAX 400

void sky_log_once(NSString *line) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet *seen;
    os_unfair_lock_lock(&lock);
    if (!seen)
        seen = [NSMutableSet new];
    BOOL first = seen.count < SKY_LOG_MAX && ![seen containsObject:line];
    if (first)
        [seen addObject:line];
    os_unfair_lock_unlock(&lock);
    if (!first)
        return;
    // the kernel log line is limited: long lines go out in pieces
    const char *s = line.UTF8String;
    size_t n = strlen(s);
    for (size_t off = 0; off < n; off += 140)
        sky_log("%s%.140s", off ? "  ..." : "rec ", s + off);
}

#pragma mark - function constants

static const void *kConsts = &kConsts;

static NSMutableDictionary *consts_of(id values) {
    NSMutableDictionary *d = objc_getAssociatedObject(values, kConsts);
    if (!d) {
        d = [NSMutableDictionary new];
        objc_setAssociatedObject(values, kConsts, d, OBJC_ASSOCIATION_RETAIN);
    }
    return d;
}

static size_t type_size(MTLDataType t) {
    switch (t) {
    case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
    case MTLDataTypeHalf: case MTLDataTypeShort: case MTLDataTypeUShort: return 2;
    case MTLDataTypeFloat2: case MTLDataTypeInt2: case MTLDataTypeUInt2: return 8;
    case MTLDataTypeFloat4: case MTLDataTypeInt4: case MTLDataTypeUInt4: return 16;
    case MTLDataTypeHalf4: return 8;
    default: return 4;
    }
}

static NSString *hex(const void *p, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++)
        [s appendFormat:@"%02x", ((const uint8_t *)p)[i]];
    return s;
}

static void (*orig_by_name)(id, SEL, const void *, MTLDataType, NSString *);
static void (*orig_by_index)(id, SEL, const void *, MTLDataType, NSUInteger);
static void (*orig_range)(id, SEL, const void *, MTLDataType, NSRange);

static void rec_by_name(id self, SEL _cmd, const void *v, MTLDataType t, NSString *name) {
    consts_of(self)[name] = [NSString stringWithFormat:@"%lu:%@", (unsigned long)t, hex(v, type_size(t))];
    orig_by_name(self, _cmd, v, t, name);
}

static void rec_by_index(id self, SEL _cmd, const void *v, MTLDataType t, NSUInteger i) {
    consts_of(self)[[NSString stringWithFormat:@"#%lu", (unsigned long)i]] =
        [NSString stringWithFormat:@"%lu:%@", (unsigned long)t, hex(v, type_size(t))];
    orig_by_index(self, _cmd, v, t, i);
}

static void rec_range(id self, SEL _cmd, const void *v, MTLDataType t, NSRange r) {
    size_t sz = type_size(t);
    for (NSUInteger i = 0; i < r.length; i++)
        consts_of(self)[[NSString stringWithFormat:@"#%lu", (unsigned long)(r.location + i)]] =
            [NSString stringWithFormat:@"%lu:%@", (unsigned long)t, hex((const uint8_t *)v + i * sz, sz)];
    orig_range(self, _cmd, v, t, r);
}

static void swizzle(Class c, SEL sel, IMP imp, void *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (m)
        *(IMP *)orig = method_setImplementation(m, imp);
}

void sky_record_init(void) {
    // the objects are MTLFunctionConstantValuesInternal, which overrides
    // the setters (0111m captured nothing from the base class)
    Class c = NSClassFromString(@"MTLFunctionConstantValuesInternal") ?: [MTLFunctionConstantValues class];
    swizzle(c, @selector(setConstantValue:type:withName:), (IMP)rec_by_name, &orig_by_name);
    swizzle(c, @selector(setConstantValue:type:atIndex:), (IMP)rec_by_index, &orig_by_index);
    swizzle(c, @selector(setConstantValues:type:withRange:), (IMP)rec_range, &orig_range);
}

static NSString *consts_string(MTLFunctionConstantValues *v) {
    NSDictionary *d = v ? objc_getAssociatedObject(v, kConsts) : nil;
    if (v && !d.count) {
        // copies lose the associated values: parse Metal's own dump,
        // "name: fc_x; type: MTLDataTypeUChar; value: (2)", keep non-zero
        NSMutableArray *parts = [NSMutableArray array];
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"name: fc_([A-Za-z0-9_]+); type: MTLDataType[A-Za-z0-9]+; value: \\(([^)]*)\\)"
                                 options:0
                                   error:NULL];
        NSString *text = [v description];
        // debug: the whole dump of the first fragment-uber constant sets
        // (constants set by index print without a name)
        static int nraw;
        if (nraw < 4 && [text containsString:@"blend_function"]) {
            nraw++;
            NSString *flat = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@"|"];
            for (NSUInteger off = 0; off < flat.length; off += 140)
                sky_log("fcraw%d %s", nraw, [flat substringWithRange:NSMakeRange(off, MIN(140, flat.length - off))].UTF8String);
        }
        for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
            NSString *val = [[text substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@" " withString:@""];
            if (![val isEqualToString:@"0"] && ![val isEqualToString:@"0,0,0"])
                [parts addObject:[NSString stringWithFormat:@"%@=%@", [text substringWithRange:[m rangeAtIndex:1]], val]];
        }
        // sorted, as the offline program table (tools/air-spec/genprogs.py)
        [parts sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a compare:b options:NSLiteralSearch];
        }];
        return [parts componentsJoinedByString:@" "];
    }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, d[k]]];
    return [parts componentsJoinedByString:@","];
}

#pragma mark - library and functions

@interface SkyFunction : SkyObject <MTLFunction>
@property (copy) NSString *name, *constants;
@property (weak) id<MTLDevice> device;
@end

@implementation SkyFunction {
    NSString *_label;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (MTLFunctionType)functionType {
    return [self.name containsString:@"vert"] ? MTLFunctionTypeVertex
           : [self.name containsString:@"frag"] ? MTLFunctionTypeFragment : MTLFunctionTypeKernel;
}
- (NSString *)key {
    return self.constants.length ? [NSString stringWithFormat:@"%@[%@]", self.name, self.constants] : self.name;
}
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes { return @[]; }
- (NSDictionary *)functionConstantsDictionary { return @{}; }
- (MTLFunctionOptions)options { return 0; }
@end

@interface SkyLibrary : SkyObject <MTLLibrary>
@property (copy) NSString *path;
@property (weak) id<MTLDevice> device;
@end

@implementation SkyLibrary
- (id<MTLFunction>)fn:(NSString *)name constants:(MTLFunctionConstantValues *)v {
    SkyFunction *f = [SkyFunction new];
    f.name = name;
    f.constants = consts_string(v);
    f.device = self.device;
    sky_log_once([NSString stringWithFormat:@"function %@", [f key]]);
    return f;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    return [self fn:name constants:nil];
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)v error:(NSError **)e {
    return [self fn:name constants:v];
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)e {
    return [self fn:d.name constants:d.constantValues];
}
- (NSArray<NSString *> *)functionNames { return @[]; }
- (NSString *)installName { return nil; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
@end

#pragma mark - states

@interface SkyRenderPipeline : SkyObject <MTLRenderPipelineState>
@property (copy) NSString *key;
@property (copy) NSString *vname, *fname; // function names (SkyRender.m looks for built-in code)
@property (copy) NSString *fkey;          // fragment function key (name + constants)
@property (copy) NSString *vkey;          // vertex function key
@property SkyVertexDesc vdesc;
@property uint32_t mrtControl, mrtBlend;  // RB_MRT[0].CONTROL / BLEND_CONTROL (SkyRender.m)
@property (weak) id<MTLDevice> device;
@end
@implementation SkyRenderPipeline
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

@interface SkyComputePipeline : SkyObject <MTLComputePipelineState>
@property (weak) id<MTLDevice> device;
@end
@implementation SkyComputePipeline
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (NSUInteger)threadExecutionWidth { return 64; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
@end

@interface SkySampler : SkyObject <MTLSamplerState>
@property (weak) id<MTLDevice> device;
@property uint32_t samp0;
@property BOOL unnorm;
@end
@implementation SkySampler
@end

// MTLSamplerAddressMode -> a6xx_tex_clamp
static uint32_t sky_wrap(MTLSamplerAddressMode m) {
    switch (m) {
    case MTLSamplerAddressModeRepeat: return 0;
    case MTLSamplerAddressModeMirrorRepeat: return 2;
    case MTLSamplerAddressModeMirrorClampToEdge: return 4;
    case MTLSamplerAddressModeClampToZero:
    case MTLSamplerAddressModeClampToBorderColor: return 3; // border colour table: zeros
    default: return 1;                                      // clamp to edge
    }
}

BOOL sky_sampler_unnorm(id<MTLSamplerState> s) {
    return [s isKindOfClass:[SkySampler class]] && ((SkySampler *)s).unnorm;
}

uint32_t sky_sampler_word(id<MTLSamplerState> s) {
    return [s isKindOfClass:[SkySampler class]] ? ((SkySampler *)s).samp0 : 0x92a;
}

@interface SkyDepthStencil : SkyObject <MTLDepthStencilState>
@property (weak) id<MTLDevice> device;
@end
@implementation SkyDepthStencil
@end

#pragma mark - textures

// bytes per pixel of the formats the Adreno path samples and renders (0: none)
NSUInteger sky_tex_bpe(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatA8Unorm:
    case MTLPixelFormatR8Unorm:
        return 1;
    case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatR16Float:
        return 2;
    case SkyPixelFormatB3A8:
    case MTLPixelFormatBGR10_XR:
    case MTLPixelFormatBGR10_XR_sRGB:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRG16Float:
    case MTLPixelFormatR32Float:
        return 4;
    case MTLPixelFormatRGBA16Float:
        return 8;
    default:
        return 0;
    }
}

static BOOL sky_tex_astc(MTLPixelFormat f) {
    return f == MTLPixelFormatASTC_4x4_LDR || f == MTLPixelFormatASTC_4x4_sRGB;
}

BOOL sky_tex_layout(MTLPixelFormat f, NSUInteger w, NSUInteger h, NSUInteger *rowBytes, NSUInteger *rows) {
    if (sky_tex_astc(f)) {
        *rowBytes = (w + 3) / 4 * 16;
        *rows = (h + 3) / 4;
        return YES;
    }
    NSUInteger bpe = sky_tex_bpe(f);
    *rowBytes = w * bpe;
    *rows = h;
    return bpe != 0;
}

// A 2D texture made without an IOSurface gets one, so it has GPU
// memory to sample and render into (import_surface) and CPU memory for
// replaceRegion: rows 64-byte aligned, as A6XX linear textures need.
// ASTC 4x4 (CoreAnimation's compressed images, the wallpaper among them):
// a surface of 16-byte elements, one per block.
static IOSurfaceRef sky_tex_surface(MTLTextureDescriptor *d) {
    BOOL astc = sky_tex_astc(d.pixelFormat);
    NSUInteger bpe = astc ? 16 : sky_tex_bpe(d.pixelFormat);
    if (d.textureType != MTLTextureType2D || d.sampleCount > 1 || !bpe ||
        d.width == 0 || d.height == 0 || d.width > 8192 || d.height > 8192)
        return NULL;
    BOOL rgba = d.pixelFormat == MTLPixelFormatRGBA8Unorm || d.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB;
    NSUInteger rowBytes, rows;
    sky_tex_layout(d.pixelFormat, d.width, d.height, &rowBytes, &rows);
    size_t bpr = (rowBytes + 63) & ~(size_t)63;
    NSMutableDictionary *p = [@{
        (id)kIOSurfaceWidth: @(astc ? rowBytes / 16 : d.width),
        (id)kIOSurfaceHeight: @(rows),
        (id)kIOSurfaceBytesPerElement: @(bpe),
        (id)kIOSurfaceBytesPerRow: @(bpr),
        (id)kIOSurfaceAllocSize: @(bpr * rows),
    } mutableCopy];
    if (!astc)
        p[(id)kIOSurfacePixelFormat] = @(bpe == 1 ? 0x4c303038u : bpe == 2 ? 0x32433038u : bpe == 8 ? 0x52476841u
                                         : rgba ? 0x52474241u : 0x42475241u);
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)p);
    static int nlog;
    if (nlog++ < 8)
        sky_log("texture %lux%lu fmt %lu -> surface %#x bpr %zu", (unsigned long)d.width, (unsigned long)d.height,
                (unsigned long)d.pixelFormat, s ? IOSurfaceGetID(s) : 0, bpr);
    return s;
}

@interface SkyTexture : SkyObject <MTLTexture>
@property (weak) id<MTLDevice> device;
@property MTLTextureType textureType;
@property MTLPixelFormat pixelFormat;
@property NSUInteger width, height, depth, mipmapLevelCount, arrayLength, sampleCount;
@property MTLTextureUsage usage;
@property MTLStorageMode storageMode;
@property (copy) NSString *label;
@end

@implementation SkyTexture {
    IOSurfaceRef _surface;
    NSUInteger _plane;
    uint64_t _bufGpu;
    NSUInteger _bufOff, _bufBpr;
    id<MTLBuffer> _parent; // a texture made from a buffer keeps it alive, as in Metal
}
- (instancetype)initWithDevice:(id<MTLDevice>)dev descriptor:(MTLTextureDescriptor *)d surface:(IOSurfaceRef)s plane:(NSUInteger)plane {
    if ((self = [super init])) {
        _device = dev;
        _textureType = d.textureType;
        _pixelFormat = d.pixelFormat;
        _width = d.width;
        _height = d.height;
        _depth = d.depth;
        _mipmapLevelCount = d.mipmapLevelCount;
        _arrayLength = d.arrayLength;
        _sampleCount = d.sampleCount;
        _usage = d.usage;
        _storageMode = d.storageMode;
        if (s)
            _surface = (IOSurfaceRef)CFRetain(s);
        _plane = plane;
    }
    return self;
}
- (void)dealloc {
    if (_surface)
        CFRelease(_surface);
}
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (uint64_t)skyBufGpu { return _bufGpu; }
- (NSUInteger)skyBufOff { return _bufOff; }
- (NSUInteger)skyBufBpr { return _bufBpr; }
- (void)setSkyBuf:(id<MTLBuffer>)buf off:(NSUInteger)o bpr:(NSUInteger)b {
    _parent = buf;
    _bufGpu = buf.gpuAddress;
    _bufOff = o;
    _bufBpr = b;
}
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)isShareable { return NO; }
- (BOOL)allowGPUOptimizedContents { return NO; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return 0; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)s { return MTLPurgeableStateNonVolatile; }
- (MTLTextureSwizzleChannels)swizzle {
    return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)f {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:_width height:_height mipmapped:NO];
    return [[SkyTexture alloc] initWithDevice:_device descriptor:d surface:_surface plane:_plane];
}
// CPU uploads and readbacks for IOSurface-backed textures (level 0 only);
// CA fills its layer and image textures this way. A region of an ASTC
// texture is whole 4x4 blocks: rows of blocks, 16 bytes each.
static BOOL sky_tex_rows(SkyTexture *t, IOSurfaceRef s, MTLRegion r, NSUInteger l, BOOL readOnly,
                         uint8_t **base, size_t *sbpr, NSUInteger *rowBytes, NSUInteger *rows) {
    BOOL astc = sky_tex_astc(t.pixelFormat);
    NSUInteger bpe = astc ? 16 : sky_tex_bpe(t.pixelFormat);
    NSUInteger x = astc ? r.origin.x / 4 : r.origin.x, y = astc ? r.origin.y / 4 : r.origin.y;
    if (!s || l != 0 || !bpe || !sky_tex_layout(t.pixelFormat, r.size.width, r.size.height, rowBytes, rows) ||
        x + *rowBytes / bpe > IOSurfaceGetWidth(s) || y + *rows > IOSurfaceGetHeight(s))
        return NO;
    if (IOSurfaceLock(s, readOnly ? kIOSurfaceLockReadOnly : 0, NULL) != kIOReturnSuccess)
        return NO;
    *sbpr = IOSurfaceGetBytesPerRow(s);
    *base = (uint8_t *)IOSurfaceGetBaseAddress(s) + y * *sbpr + x * bpe;
    return YES;
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l withBytes:(const void *)b bytesPerRow:(NSUInteger)bpr {
    uint8_t *dst;
    size_t sbpr;
    NSUInteger rowBytes, rows;
    if (!b || !sky_tex_rows(self, _surface, r, l, NO, &dst, &sbpr, &rowBytes, &rows))
        return;
    for (NSUInteger y = 0; y < rows; ++y)
        memcpy(dst + y * sbpr, (const uint8_t *)b + y * bpr, rowBytes);
    IOSurfaceUnlock(_surface, 0, NULL);
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l slice:(NSUInteger)s withBytes:(const void *)b bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi {
    if (s == 0)
        [self replaceRegion:r mipmapLevel:l withBytes:b bytesPerRow:bpr];
}
- (void)getBytes:(void *)b bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l {
    uint8_t *src;
    size_t sbpr;
    NSUInteger rowBytes, rows;
    if (!b || !sky_tex_rows(self, _surface, r, l, YES, &src, &sbpr, &rowBytes, &rows))
        return;
    for (NSUInteger y = 0; y < rows; ++y)
        memcpy((uint8_t *)b + y * bpr, src + y * sbpr, rowBytes);
    IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
}
- (void)getBytes:(void *)b bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l slice:(NSUInteger)s {
    if (s == 0)
        [self getBytes:b bytesPerRow:bpr fromRegion:r mipmapLevel:l];
}
- (id<MTLBuffer>)buffer { return _parent; }
- (NSUInteger)bufferOffset { return _bufOff; }
- (NSUInteger)bufferBytesPerRow { return _bufBpr; }
- (NSUInteger)protectionOptions { return 0; }
@end

id sky_texture_from_buffer(id<MTLDevice> dev, MTLTextureDescriptor *d, id<MTLBuffer> buf, NSUInteger off, NSUInteger bpr) {
    sky_log_once([NSString stringWithFormat:@"buffer texture fmt %lu", (unsigned long)d.pixelFormat]);
    SkyTexture *t = [[SkyTexture alloc] initWithDevice:dev descriptor:d surface:NULL plane:0];
    [t setSkyBuf:buf off:off bpr:bpr];
    return t;
}

#pragma mark - render encoder

@interface SkyRenderEncoder : SkyObject <MTLRenderCommandEncoder>
@property (weak) id<MTLDevice> device;
@property (copy) NSString *label;
@property (copy) NSString *pass;
@end

@implementation SkyRenderEncoder {
    NSUInteger _draws, _verts;
    NSMutableSet *_pipes;
}
- (instancetype)init {
    if ((self = [super init]))
        _pipes = [NSMutableSet new];
    return self;
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p {
    if (p)
        [_pipes addObject:((SkyRenderPipeline *)p).key ?: @"?"];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
    _draws++;
    _verts += n;
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i {
    _draws++;
    _verts += n * i;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {
    _draws++;
    _verts += n;
}
- (void)endEncoding {
    sky_log_once([NSString stringWithFormat:@"pass %@: %lu pipelines", self.pass, (unsigned long)_pipes.count]);
    static int n;
    if (n++ % 120 == 0)
        sky_log("encoder %d: %lu draws, %lu vertices, pass %s", n, (unsigned long)_draws, (unsigned long)_verts,
                self.pass.UTF8String);
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i {}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)l atIndex:(NSUInteger)i {}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {}
- (void)setViewport:(MTLViewport)v {}
- (void)setScissorRect:(MTLScissorRect)r {}
- (void)setCullMode:(MTLCullMode)m {}
- (void)setFrontFacingWinding:(MTLWinding)w {}
- (void)setTriangleFillMode:(MTLTriangleFillMode)m {}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s {}
- (void)setStencilReferenceValue:(uint32_t)v {}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {}
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c {}
- (void)pushDebugGroup:(NSString *)s {}
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)s {}
@end

static NSString *pass_string(MTLRenderPassDescriptor *d) {
    MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[0];
    SkyTexture *t = (SkyTexture *)c.texture;
    return [NSString stringWithFormat:@"%lux%lu fmt %lu %s load %lu store %lu", (unsigned long)t.width,
                                      (unsigned long)t.height, (unsigned long)t.pixelFormat, t.iosurface ? "iosurface" : "tex",
                                      (unsigned long)c.loadAction, (unsigned long)c.storeAction];
}

id sky_render_encoder(id<MTLDevice> dev, MTLRenderPassDescriptor *d) {
    SkyRenderEncoder *e = [SkyRenderEncoder new];
    e.device = dev;
    e.pass = pass_string(d);
    return e;
}

#pragma mark - device methods

@implementation SkyDeviceMethods (Record)
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)e {
    sky_log_once([NSString stringWithFormat:@"library %@", url.path]);
    SkyLibrary *l = [SkyLibrary new];
    l.path = url.path;
    l.device = (id<MTLDevice>)self;
    return l;
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)e {
    return [self newLibraryWithURL:[NSURL fileURLWithPath:path] error:e];
}
- (id<MTLLibrary>)newDefaultLibrary {
    return [self newLibraryWithURL:[NSURL fileURLWithPath:@"default"] error:NULL];
}
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)e {
    sky_log_once([NSString stringWithFormat:@"pipeline library %@ (refused)", path]);
    return nil;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)e {
    MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
    SkyRenderPipeline *p = [SkyRenderPipeline new];
    p.device = (id<MTLDevice>)self;
    p.vname = d.vertexFunction.name;
    p.fname = d.fragmentFunction.name;
    p.fkey = [(SkyFunction *)d.fragmentFunction key];
    p.vkey = [(SkyFunction *)d.vertexFunction key];
    uint32_t ctl = 0, bl = 0;
    sky_blend_state(d.colorAttachments[0], &ctl, &bl);
    p.mrtControl = ctl;
    p.mrtBlend = bl;
    p.key = [NSString stringWithFormat:@"%@ + %@ fmt %lu blend %d %lu/%lu %lu/%lu wm %lu", [(SkyFunction *)d.vertexFunction key],
                                       [(SkyFunction *)d.fragmentFunction key], (unsigned long)c.pixelFormat, c.blendingEnabled,
                                       (unsigned long)c.sourceRGBBlendFactor, (unsigned long)c.destinationRGBBlendFactor,
                                       (unsigned long)c.sourceAlphaBlendFactor, (unsigned long)c.destinationAlphaBlendFactor,
                                       (unsigned long)c.writeMask];
    sky_log_once([NSString stringWithFormat:@"pipeline %@", p.key]);
    MTLVertexDescriptor *vd = d.vertexDescriptor;
    NSMutableString *vds = [NSMutableString stringWithFormat:@"vdesc %@:", [(SkyFunction *)d.vertexFunction key]];
    for (NSUInteger i = 0; i < 8; i++) {
        MTLVertexAttributeDescriptor *a = vd.attributes[i];
        if (a.format)
            [vds appendFormat:@" a%lu=f%lu@%lu/b%lu", (unsigned long)i, (unsigned long)a.format, (unsigned long)a.offset, (unsigned long)a.bufferIndex];
    }
    for (NSUInteger i = 0; i < 31; i++) {
        MTLVertexBufferLayoutDescriptor *l = vd.layouts[i];
        if (l.stride)
            [vds appendFormat:@" l%lu=%lu/%lu", (unsigned long)i, (unsigned long)l.stride, (unsigned long)l.stepFunction];
    }
    sky_log_once(vds);
    SkyVertexDesc v = {0};
    for (NSUInteger i = 0; i < 8; i++) {
        MTLVertexAttributeDescriptor *a = vd.attributes[i];
        v.fmt[i] = (uint32_t)a.format;
        v.off[i] = (uint32_t)a.offset;
        v.buf[i] = (uint32_t)a.bufferIndex;
    }
    for (NSUInteger i = 0; i < 31; i++)
        v.stride[i] = (uint32_t)vd.layouts[i].stride;
    p.vdesc = v;
    return p;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)d
                                                              options:(MTLPipelineOption)o
                                                           reflection:(id *)r
                                                                error:(NSError **)e {
    SkyRenderPipeline *p = [SkyRenderPipeline new];
    p.device = (id<MTLDevice>)self;
    p.key = [NSString stringWithFormat:@"tile %@", [(SkyFunction *)d.tileFunction key]];
    sky_log_once([NSString stringWithFormat:@"pipeline %@", p.key]);
    return p;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)e {
    sky_log_once([NSString stringWithFormat:@"compute %@", [(SkyFunction *)f key]]);
    SkyComputePipeline *p = [SkyComputePipeline new];
    p.device = (id<MTLDevice>)self;
    return p;
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d {
    SkySampler *s = [SkySampler new];
    s.device = (id<MTLDevice>)self;
    // A6XX_TEX_SAMP_0: XY_MAG, XY_MIN, WRAP_S/T/R (one mip level only)
    s.samp0 = ((uint32_t)d.magFilter << 1) | ((uint32_t)d.minFilter << 3) | (sky_wrap(d.sAddressMode) << 5) |
              (sky_wrap(d.tAddressMode) << 8) | (sky_wrap(d.rAddressMode) << 11);
    s.unnorm = !d.normalizedCoordinates;
    return s;
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d {
    SkyDepthStencil *s = [SkyDepthStencil new];
    s.device = (id<MTLDevice>)self;
    return s;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    sky_log_once([NSString stringWithFormat:@"texture fmt %lu type %lu usage %lu storage %lu", (unsigned long)d.pixelFormat,
                                            (unsigned long)d.textureType, (unsigned long)d.usage, (unsigned long)d.storageMode]);
    IOSurfaceRef s = sky_tex_surface(d);
    SkyTexture *t = [[SkyTexture alloc] initWithDevice:(id<MTLDevice>)self descriptor:d surface:s plane:0];
    if (s)
        CFRelease(s);
    return t;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)s plane:(NSUInteger)plane {
    sky_log_once([NSString stringWithFormat:@"iosurface texture fmt %lu usage %lu surface fmt %#x %zux%zu", (unsigned long)d.pixelFormat,
                                            (unsigned long)d.usage, IOSurfaceGetPixelFormat(s), IOSurfaceGetWidth(s),
                                            IOSurfaceGetHeight(s)]);
    return [[SkyTexture alloc] initWithDevice:(id<MTLDevice>)self descriptor:d surface:s plane:plane];
}
- (id<MTLTexture>)newTextureWithBytesNoCopy:(const void *)p length:(NSUInteger)len descriptor:(MTLTextureDescriptor *)d deallocator:(void (^)(void *, NSUInteger))dealloc {
    // the bytes copied into a GPU buffer (as newBufferWithBytesNoCopy),
    // rows tightly packed
    sky_log_once([NSString stringWithFormat:@"bytes texture fmt %lu %lux%lu len %lu", (unsigned long)d.pixelFormat,
                                            (unsigned long)d.width, (unsigned long)d.height, (unsigned long)len]);
    NSUInteger rowBytes, rows;
    if (p && sky_tex_layout(d.pixelFormat, d.width, d.height, &rowBytes, &rows) && len >= rowBytes * rows) {
        id<MTLBuffer> b = [(id<MTLDevice>)self newBufferWithBytes:p length:len options:0];
        if (b)
            return sky_texture_from_buffer((id<MTLDevice>)self, d, b, 0, rowBytes);
    }
    return [[SkyTexture alloc] initWithDevice:(id<MTLDevice>)self descriptor:d surface:NULL plane:0];
}
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)f { return 64; }
- (NSUInteger)minConstantBufferAlignmentBytes { return 64; }
- (NSUInteger)maxFragmentSamplers { return 16; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (BOOL)supportsFamily:(MTLGPUFamily)f {
    sky_log_once([NSString stringWithFormat:@"supportsFamily %ld", (long)f]);
    // no Apple4: that family has tile shaders and imageblocks, which the
    // Adreno cannot run (0111l: CA's warmup asked for tile_downsample_*)
    // without any Apple family (0111o) CoreAnimation stopped after the
    // shader warm-up and drew no frame
    // Apple1 only switched CA's shaders between half (_lph) and float (_lpf)
    // precision (0111p), framebuffer_fetch stayed on
    return f == MTLGPUFamilyApple1 || f == MTLGPUFamilyApple2 || f == MTLGPUFamilyApple3 ||
           f == MTLGPUFamilyCommon1 || f == MTLGPUFamilyCommon2;
}
- (BOOL)supportsFeatureSet:(MTLFeatureSet)f {
    sky_log_once([NSString stringWithFormat:@"supportsFeatureSet %ld", (long)f]);
    return YES;
}
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n == 1; }
@end
