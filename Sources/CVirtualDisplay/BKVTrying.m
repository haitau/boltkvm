#import "BKVTrying.h"

BOOL BKVTryCatching(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[BoltKVM] caught %@: %@", exception.name, exception.reason);
        return NO;
    }
}
