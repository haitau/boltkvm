#ifndef BKV_TRYING_H
#define BKV_TRYING_H

#import <Foundation/Foundation.h>

/// Runs `block`, returning NO when it raised an Objective-C exception (the
/// exception's name and reason are logged).
///
/// Some system frameworks report a setup failure that way instead of returning
/// an NSError: `AVAudioEngine` raises NSException when it cannot build the output
/// graph (no audio device, unsupported format). Swift cannot catch that, so the
/// call has to go through Objective-C.
BOOL BKVTryCatching(NS_NOESCAPE void (^block)(void));

#endif
