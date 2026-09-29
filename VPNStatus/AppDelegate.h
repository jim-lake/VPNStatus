#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

- (NSString *)titleForServiceActionState:(SCNetworkConnectionStatus)inState name:(NSString *)inName;

// nil when the state is not actionable (Disconnecting / invalid).
- (SEL)actionForServiceActionState:(SCNetworkConnectionStatus)inState;

@end
