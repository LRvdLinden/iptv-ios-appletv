// Build 173: zie BingrObjC.h.
#import "BingrObjC.h"

BOOL BingrCatchException(NS_NOESCAPE void (^block)(void), NSString * _Nullable * _Nullable reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]; }
        return NO;
    }
}
