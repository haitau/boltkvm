#ifndef BKV_VIRTUAL_DISPLAY_H
#define BKV_VIRTUAL_DISPLAY_H

#include <stdint.h>

/// Opaque handle. The private API ties the display's lifetime to the process
/// that created it, so this must outlive every capture session that reads it.
typedef struct BKVVirtualDisplay BKVVirtualDisplay;

/// Creates a virtual display. **Call on the main thread**: the private API hands
/// its work to the main queue and this function pumps the main run loop while
/// the system applies the mode. Blocks for up to ~4 s when HiDPI has to be
/// negotiated or falls back.
///
/// `hiDPI` asks for a 2x backing store. macOS only offers HiDPI above a size
/// threshold and remembers the last mode per display identity, so the actual
/// mode is verified afterwards; when no HiDPI variant exists this falls back to
/// 1:1 (correct proportions, softer picture) rather than reporting a bogus mode.
///
/// Returns NULL when the system refuses the display.
BKVVirtualDisplay *BKVVirtualDisplayCreate(const char *name, int width, int height, int hiDPI);

uint32_t BKVVirtualDisplayID(const BKVVirtualDisplay *display);

/// Non-zero when the display ended up with a 2x backing store.
int BKVVirtualDisplayIsHiDPI(const BKVVirtualDisplay *display);

/// Writes the backing store size actually in effect and returns 1, or returns 0
/// when the mode is not readable yet.
int BKVVirtualDisplayBackingPixels(const BKVVirtualDisplay *display, int *outWidth, int *outHeight);

/// Called when the system removes the display — sleep/wake, a mode change forced
/// by the user, or the private API changing behaviour. Fires on the main queue.
/// The callback must not destroy the display from inside itself.
void BKVVirtualDisplaySetLostHandler(BKVVirtualDisplay *display,
                                     void (*handler)(void *context),
                                     void *context);

void BKVVirtualDisplayDestroy(BKVVirtualDisplay *display);

#endif
