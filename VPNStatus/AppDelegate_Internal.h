//
//  AppDelegate_Internal.h
//  VPNStatus
//
//  Internal surface of AppDelegate, factored out so the unit tests can exercise
//  the pure per-service menu-row mapping (state -> title / action) directly.
//  Not part of the public API; imported by AppDelegate.m and the menu-row unit
//  tests only.
//

#import "AppDelegate.h"

#import <SystemConfiguration/SystemConfiguration.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate ()

// The per-service action row title for a given connection state.
- (NSString *)titleForServiceActionState:(SCNetworkConnectionStatus)inState name:(NSString *)inName;

// The per-service action row selector for a given connection state, or nil when
// the state is not actionable (Disconnecting / invalid).
- (SEL)actionForServiceActionState:(SCNetworkConnectionStatus)inState;

@end

NS_ASSUME_NONNULL_END
