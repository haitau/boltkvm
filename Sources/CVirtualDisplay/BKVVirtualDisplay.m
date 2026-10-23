// BKVVirtualDisplay.m
//
// A minimal wrapper over the private CGVirtualDisplay API. The creation and
// HiDPI-negotiation logic is extracted from lyonDan/vdscreen (MIT); see
// THIRD_PARTY_NOTICES.md. Only what boltkvm needs is vendored: create, verify
// the mode, report the displayID, and notice when the system takes the display
// away. Layout restore, main-display switching and the CLI stay upstream.

#import "BKVVirtualDisplay.h"
#import "CGVirtualDisplayShim.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

struct BKVVirtualDisplay {
    void *display;              // CGVirtualDisplay, +1 retained
    int width;
    int height;
    int hiDPI;
    void (*lostHandler)(void *);
    void *lostContext;
};

/// Stable per-identity serial: the system remembers a display's last mode by
/// identity, and a fresh random serial would make every launch a new display.
static uint32_t BKVSerialFor(NSString *identity) {
    uint32_t hash = 2166136261u;
    const char *bytes = identity.UTF8String;
    while (bytes && *bytes) {
        hash ^= (uint32_t)(uint8_t)*bytes++;
        hash *= 16777619u;
    }
    return hash;
}

/// Runs the main run loop briefly so the window server can apply a mode change.
static void BKVPump(double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static CGVirtualDisplayDescriptor *BKVDescriptor(NSString *name, int w, int h,
                                                 BOOL hiDPI, NSString *identity,
                                                 BKVVirtualDisplay *owner) {
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.queue = dispatch_get_main_queue();
    desc.name = name;
    desc.maxPixelsWide = (unsigned)(hiDPI ? w * 2 : w);
    desc.maxPixelsHigh = (unsigned)(hiDPI ? h * 2 : h);
    // ~100 DPI is what makes the system treat the size as physically plausible;
    // getting this wrong silently costs the HiDPI variant.
    desc.sizeInMillimeters = CGSizeMake(w * 0.254, h * 0.254);
    desc.vendorID = 0x1AB2;
    desc.productID = 0x1234;
    desc.serialNum = BKVSerialFor(identity);
    if (owner) {
        desc.terminationHandler = ^(id reason, id gone) {
            void (*handler)(void *) = owner->lostHandler;
            void *context = owner->lostContext;
            if (handler) handler(context);
        };
    }
    return desc;
}

static CGVirtualDisplay *BKVMakeDisplay(NSString *name, int w, int h, BOOL hiDPI,
                                        NSString *identity, BKVVirtualDisplay *owner) {
    CGVirtualDisplayDescriptor *desc = BKVDescriptor(name, w, h, hiDPI, identity, owner);
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    CGVirtualDisplayMode *base =
        [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned)w height:(unsigned)h refreshRate:60.0];
    if (hiDPI) {
        settings.modes = @[base,
                           [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned)(w * 2)
                                                                height:(unsigned)(h * 2)
                                                           refreshRate:60.0]];
    } else {
        settings.modes = @[base];
    }
    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) {
        fprintf(stderr, "virtual display: initWithDescriptor returned nil (class present: %d)\n",
                NSClassFromString(@"CGVirtualDisplay") != nil);
        return nil;
    }
    BOOL applied = [display applySettings:settings];
    if (!applied) {
        fprintf(stderr, "virtual display: applySettings refused %dx%d hiDPI=%d\n", w, h, hiDPI ? 1 : 0);
    }
    return applied ? display : nil;
}

/// Reads back the mode the system actually picked. CGDisplayModeGetPixelWidth is
/// trustworthy for virtual displays, so this confirms both the logical size and
/// that the backing store really is 2x.
static BOOL BKVModeMatches(CGVirtualDisplay *display, int w, int h, BOOL requireHiDPI) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode((CGDirectDisplayID)[display displayID]);
    if (!mode) return NO;
    BOOL sizeOK = (int)CGDisplayModeGetWidth(mode) == w && (int)CGDisplayModeGetHeight(mode) == h;
    BOOL hidpiOK = !requireHiDPI || ((int)CGDisplayModeGetPixelWidth(mode) == w * 2 &&
                                     (int)CGDisplayModeGetPixelHeight(mode) == h * 2);
    CFRelease(mode);
    return sizeOK && hidpiOK;
}

/// The system can hand back the LoDPI variant because it cached that choice for
/// this display identity; ask for the HiDPI variant explicitly, with a second
/// API path because the first one is not always honoured.
static BOOL BKVSelectHiDPIMode(CGVirtualDisplay *display, int w, int h) {
    CGDirectDisplayID did = (CGDirectDisplayID)[display displayID];
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, NULL);
    if (!modes) return NO;

    BOOL done = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(modes) && !done; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if ((int)CGDisplayModeGetWidth(mode) != w || (int)CGDisplayModeGetHeight(mode) != h) continue;
        if ((int)CGDisplayModeGetPixelWidth(mode) != w * 2) continue;

        CGDisplayConfigRef config = NULL;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(config, did, mode, NULL);
            if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess) {
                BKVPump(0.8);
                done = BKVModeMatches(display, w, h, YES);
            }
        }
        if (!done) {
            CGDisplaySetDisplayMode(did, mode, NULL);
            BKVPump(0.8);
            done = BKVModeMatches(display, w, h, YES);
        }
    }
    CFRelease(modes);
    return done;
}

BKVVirtualDisplay *BKVVirtualDisplayCreate(const char *nameC, int width, int height, int hiDPI) {
    if (width <= 0 || height <= 0) return NULL;
    NSString *name = nameC ? [NSString stringWithUTF8String:nameC] : @"boltKVM";
    // Fixed identity: same display across restarts, so the system's per-identity
    // mode cache and window positions survive a reboot.
    // Configurable for diagnostics: two processes cannot own the same identity,
    // and a stale display can hold it, which looks exactly like a system refusal.
    const char *identityEnv = getenv("BOLTKVM_DISPLAY_IDENTITY");
    NSString *identity = identityEnv && identityEnv[0]
        ? [NSString stringWithUTF8String:identityEnv]
        : @"io.github.boltkvm.virtualdisplay";

    BKVVirtualDisplay *handle = calloc(1, sizeof(BKVVirtualDisplay));
    if (!handle) return NULL;
    handle->width = width;
    handle->height = height;

    CGVirtualDisplay *display = BKVMakeDisplay(name, width, height, hiDPI != 0, identity, handle);
    BOOL gotHiDPI = NO;

    if (display && hiDPI) {
        BKVPump(1.8);
        gotHiDPI = BKVModeMatches(display, width, height, YES);
        if (!gotHiDPI) gotHiDPI = BKVSelectHiDPIMode(display, width, height);
        if (!gotHiDPI) {
            // No HiDPI variant exists: rebuild at 1x so proportions stay right
            // (a rejected 2x request silently degrades to a squashed picture).
            fprintf(stderr, "virtual display: no %dx%d HiDPI variant, falling back to 1:1\n", width, height);
            display = nil;
            BKVPump(0.6);
            display = BKVMakeDisplay(name, width, height, NO, identity, handle);
            BKVPump(1.8);
        }
    } else if (display) {
        BKVPump(1.8);
    }

    if (!display) {
        fprintf(stderr, "virtual display: system refused %dx%d (a display with this identity may already exist)\n",
                width, height);
        free(handle);
        return NULL;
    }

    handle->hiDPI = gotHiDPI ? 1 : 0;
    handle->display = (__bridge_retained void *)display;
    return handle;
}

uint32_t BKVVirtualDisplayID(const BKVVirtualDisplay *handle) {
    if (!handle || !handle->display) return 0;
    CGVirtualDisplay *display = (__bridge CGVirtualDisplay *)handle->display;
    return (uint32_t)[display displayID];
}

int BKVVirtualDisplayIsHiDPI(const BKVVirtualDisplay *handle) {
    return handle ? handle->hiDPI : 0;
}

int BKVVirtualDisplayBackingPixels(const BKVVirtualDisplay *handle, int *outWidth, int *outHeight) {
    if (!handle || !handle->display) return 0;
    CGVirtualDisplay *display = (__bridge CGVirtualDisplay *)handle->display;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode((CGDirectDisplayID)[display displayID]);
    if (!mode) return 0;
    if (outWidth) *outWidth = (int)CGDisplayModeGetPixelWidth(mode);
    if (outHeight) *outHeight = (int)CGDisplayModeGetPixelHeight(mode);
    CFRelease(mode);
    return 1;
}

void BKVVirtualDisplaySetLostHandler(BKVVirtualDisplay *handle,
                                     void (*handler)(void *context),
                                     void *context) {
    if (!handle) return;
    handle->lostHandler = handler;
    handle->lostContext = context;
}

void BKVVirtualDisplayDestroy(BKVVirtualDisplay *handle) {
    if (!handle) return;
    handle->lostHandler = NULL;
    handle->lostContext = NULL;
    if (handle->display) {
        // The descriptor owns the termination block; clearing our function
        // pointer above is what makes it harmless when the display is released.
        CGVirtualDisplay *display = (__bridge_transfer CGVirtualDisplay *)handle->display;
        (void)display;              // released when this scope ends
        handle->display = NULL;
    }
    // Deliberately not freed. The descriptor's termination block captured this
    // pointer and the block runs on the main queue, so it can run *after* this
    // function returns; reading lostHandler out of a freed block is a
    // use-after-free, and because the next BKVVirtualDisplayCreate calloc()s the
    // same size it usually gets this very chunk back — the stale block would
    // then call the *new* display's handler (which is exit(3) in the server) or
    // a garbage pointer. The struct is ~48 bytes and there is one per display
    // creation (a handful per process), so leaking it is the cheap correct
    // trade; BKVVirtualDisplayDestroy is idempotent per display because the
    // Swift wrapper clears its handle.
}
