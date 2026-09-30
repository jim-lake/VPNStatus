#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <NetworkExtension/NetworkExtension.h>
#import <xpc/xpc.h>

typedef int ne_session_status_t;
typedef struct ne_session_t *ne_session_t;
#define NESessionTypeVPN 1
extern ne_session_t ne_session_create(uuid_t serviceID, int sessionConfigType);
extern void ne_session_release(ne_session_t session);
typedef int ne_session_event_t;
typedef void (^ne_session_set_event_handler_block)(ne_session_event_t event, void *event_data);
extern void ne_session_set_event_handler(ne_session_t session, dispatch_queue_t queue, ne_session_set_event_handler_block block);
typedef void (^ne_session_get_status_block)(ne_session_status_t result);
extern void ne_session_get_status(ne_session_t session, dispatch_queue_t queue, ne_session_get_status_block block);
extern SCNetworkConnectionStatus SCNetworkConnectionGetStatusFromNEStatus(ne_session_status_t status);

@interface NEConfiguration : NSObject
@property (readonly) NSUUID *identifier;
@property (copy) NSString *name;
@end
@interface NEConfigurationManager : NSObject
+ (id)sharedManager;
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)completionQueue handler:(void (^)(NSArray<NEConfiguration *> *_Nullable configurations, NSError *_Nullable error))handler;
@end

static const char *StatusName(ne_session_status_t s) {
  switch (SCNetworkConnectionGetStatusFromNEStatus(s)) {
    case kSCNetworkConnectionDisconnected: return "Disconnected";
    case kSCNetworkConnectionConnecting:   return "Connecting";
    case kSCNetworkConnectionConnected:    return "Connected";
    case kSCNetworkConnectionDisconnecting:return "Disconnecting";
    default: return "Invalid/Other";
  }
}

// Try to describe event_data without assuming a type. It might be NULL, an
// xpc_object_t, or an opaque pointer. We defensively test for xpc.
static void DescribeEventData(void *event_data) {
  if (event_data == NULL) {
    printf("      event_data = NULL\n");
    return;
  }
  printf("      event_data = %p\n", event_data);
  // Attempt to treat as xpc_object_t. xpc_get_type will crash on non-xpc
  // pointers, so guard with a best-effort: only try if the pointer looks like a
  // heap object. We simply attempt and rely on it usually being xpc or NULL.
  @try {
    xpc_object_t obj = (__bridge xpc_object_t)event_data;
    xpc_type_t t = xpc_get_type(obj);
    char *desc = xpc_copy_description(obj);
    printf("      xpc type=%p desc=%s\n", (void *)t, desc ? desc : "(null)");
    if (desc) free(desc);
  } @catch (id ex) {
    printf("      (not an xpc object: %s)\n", [[ex description] UTF8String]);
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: event_probe <vpn name> [seconds]\n"); return 1; }
    NSString *target = [NSString stringWithUTF8String:argv[1]];
    int secs = argc > 2 ? atoi(argv[2]) : 60;

    dispatch_queue_t queue = dispatch_queue_create("probe.q", NULL);
    __block NEConfiguration *found = nil;
    __block BOOL loaded = NO;
    [[NEConfigurationManager sharedManager] loadConfigurationsWithCompletionQueue:queue handler:^(NSArray<NEConfiguration *> *cfgs, NSError *e) {
      for (NEConfiguration *c in cfgs) if ([c.name isEqualToString:target]) found = c;
      loaded = YES;
    }];
    while (!loaded) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (!found) { fprintf(stderr, "not found: %s\n", argv[1]); return 1; }

    uuid_t u; [found.identifier getUUIDBytes:u];
    ne_session_t s = ne_session_create(u, NESessionTypeVPN);

    printf("Watching events for '%s' for %ds. Toggle the VPN now.\n", argv[1], secs);
    ne_session_set_event_handler(s, queue, ^(ne_session_event_t event, void *event_data) {
      NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterMediumStyle];
      printf("[%s] EVENT: event=%d\n", ts.UTF8String, event);
      DescribeEventData(event_data);
      ne_session_get_status(s, queue, ^(ne_session_status_t st) {
        printf("      -> status now %d (%s)\n", (int)st, StatusName(st));
        fflush(stdout);
      });
    });

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    ne_session_release(s);
  }
  return 0;
}
