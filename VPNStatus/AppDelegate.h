#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

- (NSString *)titleForServiceActionState:(SCNetworkConnectionStatus)inState name:(NSString *)inName connectedDate:(NSDate *_Nullable)inConnectedDate;

// Formats an elapsed interval (>= 0) as h:mm:ss, e.g. 0:00:05, 1:23:45,
// 26:00:00. Hours are not zero-padded and not capped at 24.
- (NSString *)elapsedStringForInterval:(NSTimeInterval)inInterval;

// nil when the state is not actionable (Disconnecting / invalid).
- (SEL)actionForServiceActionState:(SCNetworkConnectionStatus)inState;

@end
