//
//  ACConnectionManager_Internal.h
//  VPN
//
//  Internal state of ACConnectionManager, factored out of the .m so the unit
//  tests can inspect and seed the per-service reconnect-backoff bookkeeping
//  directly. Not part of the public API; imported by ACConnectionManager.m and
//  the backoff unit tests only.
//

#import "ACConnectionManager.h"

NS_ASSUME_NONNULL_BEGIN

// Per-service reconnect backoff state. Each always-auto-connect service tracks
// its own delay sequence and its own scheduled retry / stability timers so that
// one service dropping never affects another's schedule.
@interface ACServiceBackoff : NSObject

// The delay (seconds) to use for the NEXT scheduled retry of this service.
// Follows: 0 (first) -> clamp(previous*2 or min, 1, maxReconnect).
@property (assign) NSInteger nextDelay;

// One-shot timer for the pending reconnect attempt (nil if none scheduled).
@property (strong, nullable) NSTimer *retryTimer;

// One-shot timer that resets the backoff after the service stays connected
// (nil if the service is not currently counting toward a stable reset).
@property (strong, nullable) NSTimer *stabilityTimer;

@end

@interface ACConnectionManager ()

// Per-service backoff state keyed by service UUID string. Mutated only on the
// main queue (all callers are main-queue), so no locking is required.
@property (strong) NSMutableDictionary<NSString *, ACServiceBackoff *> *backoffByServiceIdentifier;

// Lazily creates (nextDelay = 0) and returns the backoff state for a service.
- (ACServiceBackoff *)backoffForServiceIdentifier:(NSString *)inServiceIdentifier;

// Resets a service's backoff to the start of the sequence and cancels its timers.
- (void)resetBackoffForServiceIdentifier:(NSString *)inServiceIdentifier;

// The delay sequence step: 0 -> clamp(previous*2 or min, 1, maxReconnect).
- (NSInteger)advanceDelay:(NSInteger)inCurrentDelay;

@end

NS_ASSUME_NONNULL_END
