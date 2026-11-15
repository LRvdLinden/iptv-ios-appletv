// Build 173: kleine Objective-C-hulpjes voor Swift (via Bingr-Bridging-Header.h).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Voert `block` uit en vangt een Objective-C-exceptie (NSException) op, die Swift zelf niet kan opvangen.
/// VLCKit gooit er een bij `saveVideoSnapshotAt:` als er (nog of niet meer) geen video-uitvoer is: zonder dit
/// stopte de app (SIGABRT). Geeft YES als het blok zonder exceptie klaar is; anders NO en de reden in `reason`.
BOOL BingrCatchException(NS_NOESCAPE void (^block)(void), NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
