#import <Cocoa/Cocoa.h>

@class ACNEService;

NS_ASSUME_NONNULL_BEGIN

@interface ACServiceBackoff : NSObject

// nextDelay follows: 0 (first) -> clamp(previous*2 or min, 1, maxReconnect).
@property (assign) NSInteger nextDelay;
@property (strong, nullable) NSTimer *retryTimer;
@property (strong, nullable) NSTimer *stabilityTimer;

@end

@interface ACConnectionManager : NSObject

// Mutated only on the main queue (all callers are main-queue), so no locking.
@property (strong) NSMutableDictionary<NSString *, ACServiceBackoff *> *backoffByServiceIdentifier;

+ (ACConnectionManager *)sharedManager;

- (void)toggleConnectionForService:(ACNEService *)inService;
- (void)setAlwaysAutoConnect:(BOOL)inAlwaysAutoConnect forACNEService:(ACNEService *)inNEService;
- (BOOL)isAtLeastOneServiceSetToAutoConnect;
- (void)disconnectAllAutoConnectedServices;
- (void)connectAllAutoConnectedServices;

- (ACServiceBackoff *)backoffForServiceIdentifier:(NSString *)inServiceIdentifier;
- (void)resetBackoffForServiceIdentifier:(NSString *)inServiceIdentifier;
- (NSInteger)advanceDelay:(NSInteger)inCurrentDelay;

@end

NS_ASSUME_NONNULL_END
