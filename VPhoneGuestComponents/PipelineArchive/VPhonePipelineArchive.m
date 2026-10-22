#import "VPhonePipelineArchive.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

// CoreAnimation's ordinary fallback does not attach its context archive.
// Intercept the public pipeline APIs, retaining the original compiler path for
// every miss. Nothing here changes IsVirtualDevice or another task's identity.
static NSLock *vpLock;
static dispatch_queue_t vpWork;
static NSString *vpRoot;
static BOOL vpInstalled;
static __thread unsigned vpDepth;
static const NSUInteger vpMaxPending = 64, vpMaxLearned = 1024;
static const off_t vpMaxBytes = 64 * 1024 * 1024;

typedef id<MTLRenderPipelineState> VPNewRender(id, SEL, MTLRenderPipelineDescriptor *, NSError *__autoreleasing *) NS_RETURNS_RETAINED;
typedef id<MTLRenderPipelineState> VPNewRenderOptions(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError *__autoreleasing *) NS_RETURNS_RETAINED;
typedef id<MTLComputePipelineState> VPNewCompute(id, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection *, NSError *__autoreleasing *) NS_RETURNS_RETAINED;
static VPNewRender *vpRender;
static VPNewRenderOptions *vpRenderOptions;
static VPNewCompute *vpCompute;

@interface VPhonePipelineArchive : NSObject
@property id<MTLDevice> device;
@property id<MTLBinaryArchive> reader;
@property id<MTLBinaryArchive> writer; // Confined to vpWork after initialization.
@property NSURL *directory;
@property NSURL *file;
@property NSString *identity;
@property NSString *lastError;
@property NSMutableDictionary<NSString *, NSNumber *> *counts;
@property NSUInteger pending;
@property NSUInteger accepted;
@property BOOL dirty;
@property BOOL scheduled;
@property int lockFD;
@end
@implementation VPhonePipelineArchive
- (instancetype)init {
    if ((self = [super init])) {
        _counts = [NSMutableDictionary dictionary];
        _lockFD = -1;
    }
    return self;
}
- (void)dealloc { if (_lockFD >= 0) close(_lockFD); }
@end
static VPhonePipelineArchive *vpCache;

static void vpInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vpLock = [NSLock new];
        vpWork = dispatch_queue_create("com.vphone.pipeline-archive", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(vpWork, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
}

static NSString *vpSysctl(const char *name) {
    char bytes[256] = {0};
    size_t size = sizeof(bytes);
    return sysctlbyname(name, bytes, &size, NULL, 0) == 0
        ? [NSString stringWithUTF8String:bytes] : @"unknown";
}

static NSString *vpImageUUID(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"unknown";
    const struct mach_header_64 *h = (const void *)header;
    const uint8_t *cursor = (const void *)(h + 1), *end = cursor + h->sizeofcmds;
    for (uint32_t i = 0; i < h->ncmds && cursor + sizeof(struct load_command) <= end; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const void *)cursor;
            return [[[NSUUID alloc] initWithUUIDBytes:uuid->uuid] UUIDString];
        }
        cursor += command->cmdsize;
    }
    return @"unknown";
}

static NSString *vpExecutableUUID(void) {
    // Injected libraries can precede the executable in dyld's image list.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header && header->filetype == MH_EXECUTE) return vpImageUUID(header);
    }
    return @"unknown";
}

static NSString *vpIdentity(id<MTLDevice> device) {
    NSString *executable = vpExecutableUUID();
    if ([executable isEqualToString:@"unknown"]) return nil;
    NSMutableString *key = [NSMutableString stringWithFormat:@"v2|%@|%@|%@", vpSysctl("kern.osversion"),
                            executable, device.architecture.name];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && (strstr(path, "/QuartzCore.framework/QuartzCore") ||
                     strstr(path, "/Metal.framework/Metal") ||
                     strstr(path, "/AppleParavirtGPUMetalIOGPUFamily"))) {
            [images addObject:[NSString stringWithFormat:@"%s=%@", path, vpImageUUID(_dyld_get_image_header(i))]];
        }
    }
    // Image load order is not part of the compatibility identity.
    for (NSString *image in [images sortedArrayUsingSelector:@selector(compare:)]) [key appendFormat:@"|%@", image];
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [result appendFormat:@"%02x", hash[i]];
    return result;
}

static void vpCount(VPhonePipelineArchive *cache, NSString *name) {
    [vpLock lock];
    cache.counts[name] = @(cache.counts[name].unsignedLongLongValue + 1);
    [vpLock unlock];
}

static void vpError(VPhonePipelineArchive *cache, NSError *error) {
    [vpLock lock];
    cache.lastError = error.localizedDescription ?: @"Archive operation failed";
    cache.counts[@"errors"] = @(cache.counts[@"errors"].unsignedLongLongValue + 1);
    [vpLock unlock];
}

static NSError *vpFileError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code ?: EIO userInfo:nil];
}

// Only one default virtual device is handled. An unexpected second device
// keeps its original pipeline behavior rather than sharing incompatible state.
static VPhonePipelineArchive *vpState(id<MTLDevice> device) {
    vpDepth++;
    [vpLock lock];
    if (!vpCache) {
        VPhonePipelineArchive *cache = [VPhonePipelineArchive new];
        cache.device = device;
        cache.identity = vpIdentity(device);
        NSString *base = vpRoot ?: [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                                    stringByAppendingPathComponent:@"VPhonePipelineArchive"];
        NSString *program = NSProcessInfo.processInfo.processName;
        NSString *path = base.length && cache.identity ? [[base stringByAppendingPathComponent:program] stringByAppendingPathComponent:cache.identity] : nil;
        if (!path) {
            cache.lastError = @"No process cache directory or executable identity is available";
            vpCache = cache;
            [vpLock unlock];
            vpDepth--;
            return cache;
        }
        cache.directory = [NSURL fileURLWithPath:path isDirectory:YES];
        cache.file = [cache.directory URLByAppendingPathComponent:@"archive.metallib"];
        NSError *error = nil;
        BOOL created = [[NSFileManager defaultManager] createDirectoryAtURL:cache.directory withIntermediateDirectories:YES
                                                               attributes:@{NSFilePosixPermissions: @0700} error:&error];
        struct stat directoryStat, fileStat;
        BOOL directoryOK = created && lstat(path.fileSystemRepresentation, &directoryStat) == 0 &&
                           S_ISDIR(directoryStat.st_mode) && directoryStat.st_uid == getuid();
        if (directoryOK) {
            NSString *lockPath = [path stringByAppendingPathComponent:@"writer.lock"];
            cache.lockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
            struct stat lockStat;
            BOOL canWrite = cache.lockFD >= 0 && fstat(cache.lockFD, &lockStat) == 0 &&
                            S_ISREG(lockStat.st_mode) && lockStat.st_nlink == 1 && lockStat.st_uid == getuid() &&
                            flock(cache.lockFD, LOCK_EX | LOCK_NB) == 0;
            MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
            if (lstat(cache.file.path.fileSystemRepresentation, &fileStat) == 0 && S_ISREG(fileStat.st_mode) &&
                fileStat.st_uid == getuid() && fileStat.st_size > 0 && fileStat.st_size <= vpMaxBytes) {
                descriptor.url = cache.file;
                cache.reader = [device newBinaryArchiveWithDescriptor:descriptor error:&error];
            }
            // A corrupt archive must not stop compilation or prevent relearning.
            descriptor.url = cache.reader ? cache.file : nil;
            if (canWrite) cache.writer = [device newBinaryArchiveWithDescriptor:descriptor error:&error];
        }
        if (error) cache.lastError = error.localizedDescription;
        vpCache = cache;
    }
    VPhonePipelineArchive *result = vpCache.device == device ? vpCache : nil;
    [vpLock unlock];
    vpDepth--;
    return result;
}

char *vphone_pipeline_archive_copy_statistics(void) {
    vpInitialize();
    [vpLock lock];
    VPhonePipelineArchive *cache = vpCache;
    NSDictionary *snapshot = @{@"installed": @(vpInstalled), @"pid": @(getpid()),
        @"bootSessionUUID": vpSysctl("kern.bootsessionuuid"),
        @"archivePath": cache.file.path ?: @"", @"identity": cache.identity ?: @"",
        @"executableUUID": vpExecutableUUID(),
        @"readable": @(cache.reader != nil), @"writable": @(cache.writer != nil),
        @"pending": @(cache.pending), @"counts": [cache.counts copy] ?: @{},
        @"lastError": cache.lastError ?: @""};
    [vpLock unlock];
    NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:NULL];
    return json ? strndup(json.bytes, json.length) : strdup("{}");
}

static void vpSave(VPhonePipelineArchive *cache) {
    if (!cache.directory) return;
    if (cache.dirty) {
        vpDepth++;
        NSURL *temporary = [cache.directory URLByAppendingPathComponent:@"pending.metallib"];
        unlink(temporary.path.fileSystemRepresentation);
        NSError *error = nil;
        BOOL saved = [cache.writer serializeToURL:temporary error:&error];
        struct stat info;
        if (saved && lstat(temporary.path.fileSystemRepresentation, &info) != 0) {
            saved = NO; error = vpFileError(errno);
        }
        if (saved && (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > vpMaxBytes)) {
            saved = NO; error = vpFileError(info.st_size > vpMaxBytes ? EFBIG : EINVAL);
        }
        id<MTLBinaryArchive> reader = nil;
        // Validate the candidate before replacing the last usable disk copy.
        if (saved) {
            MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
            descriptor.url = temporary;
            reader = [cache.device newBinaryArchiveWithDescriptor:descriptor error:&error];
            saved = reader != nil;
        }
        if (saved) {
            if (chmod(temporary.path.fileSystemRepresentation, 0600) != 0 ||
                rename(temporary.path.fileSystemRepresentation, cache.file.path.fileSystemRepresentation) != 0) {
                saved = NO; error = vpFileError(errno);
            }
        }
        if (saved) {
            // Keep the reader associated with the durable URL, including
            // drivers that defer opening part of an archive until lookup.
            MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
            descriptor.url = cache.file;
            reader = [cache.device newBinaryArchiveWithDescriptor:descriptor error:&error];
            saved = reader != nil;
        }
        if (saved) {
            [vpLock lock]; cache.reader = reader; [vpLock unlock];
            cache.dirty = NO;
            vpCount(cache, @"saves");
        } else vpError(cache, error);
        unlink(temporary.path.fileSystemRepresentation);
        vpDepth--;
    }
    char *json = vphone_pipeline_archive_copy_statistics();
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    [data writeToURL:[cache.directory URLByAppendingPathComponent:@"statistics.json"] options:NSDataWritingAtomic error:NULL];
    free(json);
}

static void vpScheduleSave(VPhonePipelineArchive *cache) {
    if (cache.scheduled) return; // vpWork only.
    cache.scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), vpWork, ^{
        @autoreleasepool { cache.scheduled = NO; vpSave(cache); }
    });
}

static void vpLearn(VPhonePipelineArchive *cache, id descriptor, BOOL compute) {
    [vpLock lock];
    BOOL accept = cache.writer && cache.pending < vpMaxPending && cache.accepted < vpMaxLearned;
    if (accept) { cache.pending++; cache.accepted++; }
    [vpLock unlock];
    if (!accept) return;
    // Called only after a normal PSO succeeds: the virtual driver's compute
    // harvest API can otherwise report success without writing usable entries.
    id copy = [descriptor copy];
    [copy setBinaryArchives:@[]];
    dispatch_async(vpWork, ^{
        @autoreleasepool {
            vpDepth++;
            NSError *error = nil;
            BOOL success = compute ? [cache.writer addComputePipelineFunctionsWithDescriptor:copy error:&error]
                                   : [cache.writer addRenderPipelineFunctionsWithDescriptor:copy error:&error];
            if (success) { cache.dirty = YES; vpCount(cache, @"learned"); }
            else vpError(cache, error);
            vpDepth--;
            [vpLock lock]; cache.pending--; [vpLock unlock];
            vpScheduleSave(cache);
        }
    });
}

static BOOL vpIsCoreAnimation(NSString *label) {
    return [label hasPrefix:@"com.apple.coreanimation."];
}

static id<MTLRenderPipelineState> vpMakeRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection,
    NSError *__autoreleasing *error, BOOL hasOptions) NS_RETURNS_RETAINED;
static id<MTLRenderPipelineState> vpMakeRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection,
    NSError *__autoreleasing *error, BOOL hasOptions) {
    VPhonePipelineArchive *cache = nil;
    if (!vpDepth && vpIsCoreAnimation(descriptor.label)) cache = vpState(device);
    vpDepth++;
    id<MTLRenderPipelineState> state = nil;
    if (cache) {
        [vpLock lock]; id<MTLBinaryArchive> reader = cache.reader; [vpLock unlock];
        if (reader) {
            MTLRenderPipelineDescriptor *copy = [descriptor copy];
            copy.binaryArchives = [(descriptor.binaryArchives ?: @[]) arrayByAddingObject:reader];
            NSError *miss = nil;
            state = vpRenderOptions(device, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), copy,
                                    options | MTLPipelineOptionFailOnBinaryArchiveMiss, reflection, &miss);
            vpCount(cache, state ? @"renderHits" : @"renderMisses");
            if (!state && (options & MTLPipelineOptionFailOnBinaryArchiveMiss)) {
                if (error) *error = miss;
                vpDepth--;
                return nil;
            }
        }
    }
    if (!state) {
        state = hasOptions ? vpRenderOptions(device, selector, descriptor, options, reflection, error)
                           : vpRender(device, selector, descriptor, error);
        if (state && cache) { vpCount(cache, @"renderFallbacks"); vpLearn(cache, descriptor, NO); }
    }
    if (cache) dispatch_async(vpWork, ^{ vpScheduleSave(cache); });
    vpDepth--;
    return state;
}

static id<MTLRenderPipelineState> vpHookRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
                                            NSError *__autoreleasing *error) NS_RETURNS_RETAINED;
static id<MTLRenderPipelineState> vpHookRender(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
                                            NSError *__autoreleasing *error) {
    return vpMakeRender(device, selector, descriptor, 0, NULL, error, NO);
}
static id<MTLRenderPipelineState> vpHookRenderOptions(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection,
    NSError *__autoreleasing *error) NS_RETURNS_RETAINED;
static id<MTLRenderPipelineState> vpHookRenderOptions(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection, NSError *__autoreleasing *error) {
    return vpMakeRender(device, selector, descriptor, options, reflection, error, YES);
}
static id<MTLComputePipelineState> vpHookCompute(id device, SEL selector, MTLComputePipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedComputePipelineReflection *reflection,
    NSError *__autoreleasing *error) NS_RETURNS_RETAINED;
static id<MTLComputePipelineState> vpHookCompute(id device, SEL selector, MTLComputePipelineDescriptor *descriptor,
    MTLPipelineOption options, MTLAutoreleasedComputePipelineReflection *reflection, NSError *__autoreleasing *error) {
    VPhonePipelineArchive *cache = nil;
    if (!vpDepth && vpIsCoreAnimation(descriptor.label)) cache = vpState(device);
    vpDepth++;
    id<MTLComputePipelineState> state = nil;
    if (cache) {
        [vpLock lock]; id<MTLBinaryArchive> reader = cache.reader; [vpLock unlock];
        if (reader) {
            MTLComputePipelineDescriptor *copy = [descriptor copy];
            copy.binaryArchives = [(descriptor.binaryArchives ?: @[]) arrayByAddingObject:reader];
            NSError *miss = nil;
            state = vpCompute(device, selector, copy, options | MTLPipelineOptionFailOnBinaryArchiveMiss, reflection, &miss);
            vpCount(cache, state ? @"computeHits" : @"computeMisses");
            if (!state && (options & MTLPipelineOptionFailOnBinaryArchiveMiss)) {
                if (error) *error = miss;
                vpDepth--;
                return nil;
            }
        }
    }
    if (!state) {
        state = vpCompute(device, selector, descriptor, options, reflection, error);
        if (state && cache) { vpCount(cache, @"computeFallbacks"); vpLearn(cache, descriptor, YES); }
    }
    if (cache) dispatch_async(vpWork, ^{ vpScheduleSave(cache); });
    vpDepth--;
    return state;
}

int vphone_pipeline_archive_install(const char *cacheRoot) {
    vpInitialize();
    [vpLock lock];
    if (vpInstalled) { [vpLock unlock]; return 1; }
    Class cls = objc_getClass("AppleParavirtDevice");
    SEL render = @selector(newRenderPipelineStateWithDescriptor:error:);
    SEL options = @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:);
    SEL compute = @selector(newComputePipelineStateWithDescriptor:options:reflection:error:);
    Method a = class_getInstanceMethod(cls, render), b = class_getInstanceMethod(cls, options), c = class_getInstanceMethod(cls, compute);
    if (!a || !b || !c) { [vpLock unlock]; return 0; }
    vpRoot = cacheRoot ? [NSString stringWithUTF8String:cacheRoot] : nil;
    vpRender = (VPNewRender *)method_getImplementation(a);
    vpRenderOptions = (VPNewRenderOptions *)method_getImplementation(b);
    vpCompute = (VPNewCompute *)method_getImplementation(c);
    // Add an override if inherited; never replace a superclass implementation.
    class_replaceMethod(cls, render, (IMP)vpHookRender, method_getTypeEncoding(a));
    class_replaceMethod(cls, options, (IMP)vpHookRenderOptions, method_getTypeEncoding(b));
    class_replaceMethod(cls, compute, (IMP)vpHookCompute, method_getTypeEncoding(c));
    vpInstalled = YES;
    [vpLock unlock];
    return 1;
}

void vphone_pipeline_archive_flush(void) {
    vpInitialize();
    dispatch_sync(vpWork, ^{
        @autoreleasepool {
            [vpLock lock]; VPhonePipelineArchive *cache = vpCache; [vpLock unlock];
            if (cache) vpSave(cache);
        }
    });
}

static CALayer *vpScene(NSUInteger index) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, 96, 96);
    CGColorRef background = CGColorCreateGenericRGB(0.1, 0.2, 0.3, 1);
    root.backgroundColor = background; CGColorRelease(background);
    CALayer *child = [CALayer layer];
    child.frame = CGRectMake(12, 14, 64, 60);
    CGColorRef red = CGColorCreateGenericRGB(0.9, 0.1, 0.2, 1);
    child.backgroundColor = red; CGColorRelease(red);
    [root addSublayer:child];
    if (index >= 1) {
        child.cornerRadius = 12; child.opacity = 0.7;
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = CGRectMake(30, 40, 55, 45);
        CGColorRef green = CGColorCreateGenericRGB(0, 1, 0, 1), blue = CGColorCreateGenericRGB(0, 0, 1, 1);
        gradient.colors = @[(__bridge id)green, (__bridge id)blue];
        CGColorRelease(green); CGColorRelease(blue);
        [root addSublayer:gradient];
    }
    if (index >= 2) {
        child.shadowOpacity = 0.8; child.shadowRadius = 5; child.shadowOffset = CGSizeMake(3, 4);
        child.transform = CATransform3DMakeRotation(0.2, 0, 0, 1);
    }
    if (index >= 3) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, 8, 8, 8, 32, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        if (context) {
            CGContextSetRGBFillColor(context, 1, 0.7, 0.1, 1); CGContextFillRect(context, CGRectMake(0, 0, 8, 8));
            CGContextSetRGBFillColor(context, 0.2, 0.3, 1, 0.7); CGContextFillRect(context, CGRectMake(0, 0, 4, 4));
            CGImageRef image = CGBitmapContextCreateImage(context);
            child.contents = (__bridge id)image; CGImageRelease(image); CGContextRelease(context);
        }
        child.borderWidth = 2;
    }
    return root;
}

void vphone_pipeline_archive_prewarm(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device || !vphone_pipeline_archive_install(NULL)) return;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:96 height:96 mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (!queue || !texture) return;
        VPhonePipelineArchive *cache = vpState(device);
        if (!cache) return;
        vpCount(cache, @"prewarmStarted");
        for (NSUInteger i = 0; i < 4; i++) {
            CARenderer *renderer = [CARenderer rendererWithMTLTexture:texture options:@{kCARendererMetalCommandQueue: queue}];
            renderer.bounds = CGRectMake(0, 0, 96, 96);
            renderer.layer = vpScene(i);
            [CATransaction flush];
            [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
            [renderer addUpdateRect:renderer.bounds]; [renderer render]; [renderer endFrame];
            // Completion forces lazy host resources to materialize as well.
            id<MTLCommandBuffer> barrier = [queue commandBuffer];
            [barrier commit]; [barrier waitUntilCompleted];
            if (barrier.status != MTLCommandBufferStatusCompleted) vpError(cache, barrier.error);
            else vpCount(cache, @"prewarmFrames");
            renderer.layer = nil;
        }
        vpCount(cache, @"prewarmFinished");
    }
}

static void vpTryInstall(unsigned remaining) {
    @autoreleasepool {
        if (vphone_pipeline_archive_install(NULL)) return;
        if (remaining) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), vpWork, ^{ vpTryInstall(remaining - 1); });
    }
}

__attribute__((constructor)) static void vpStart(void) {
    // SystemHook loads this only in backboardd. Explicit installation remains
    // available for a separate, unprivileged on-device validation process.
    if (strcmp(getprogname(), "backboardd") != 0) return;
    vpInitialize();
    dispatch_async(vpWork, ^{ vpTryInstall(300); });
    // Never create a Metal device inside a dyld initializer. Prewarm after
    // startup on a utility queue, under backboardd's own Task3 identity.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), vpWork, ^{
        vphone_pipeline_archive_prewarm();
        [vpLock lock]; VPhonePipelineArchive *cache = vpCache; [vpLock unlock];
        if (cache) vpScheduleSave(cache);
    });
}
