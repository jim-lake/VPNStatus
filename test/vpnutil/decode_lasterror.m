#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <NetworkExtension/NetworkExtension.h>
#import <xpc/xpc.h>

typedef int ne_session_status_t;
typedef struct ne_session_t *ne_session_t;
#define NESessionTypeVPN 1
extern ne_session_t ne_session_create(uuid_t serviceID, int sessionConfigType);
extern void ne_session_release(ne_session_t session);
typedef void (^ne_session_get_info_block)(xpc_object_t _Nullable result);
extern void ne_session_get_info(ne_session_t session, int info, dispatch_queue_t queue, ne_session_get_info_block block);

@interface NEConfiguration : NSObject
@property (readonly) NSUUID *identifier;
@property (copy) NSString *name;
@end
@interface NEConfigurationManager : NSObject
+ (id)sharedManager;
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)completionQueue handler:(void (^)(NSArray<NEConfiguration *> *_Nullable configurations, NSError *_Nullable error))handler;
@end

static void DumpError(NSError *err, NSString *indent) {
  if (!err) return;
  printf("%sdomain = %s\n", indent.UTF8String, err.domain.UTF8String);
  printf("%scode   = %ld\n", indent.UTF8String, (long)err.code);
  printf("%sdesc   = %s\n", indent.UTF8String, err.localizedDescription.UTF8String);
  for (NSString *k in err.userInfo) {
    id v = err.userInfo[k];
    if ([v isKindOfClass:[NSError class]]) {
      printf("%suserInfo[%s] = (NSError):\n", indent.UTF8String, k.UTF8String);
      DumpError(v, [indent stringByAppendingString:@"    "]);
    } else {
      printf("%suserInfo[%s] = %s\n", indent.UTF8String, k.UTF8String, [[v description] UTF8String]);
    }
  }
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *target = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
    dispatch_queue_t queue = dispatch_queue_create("dec.q", NULL);
    __block NSArray<NEConfiguration *> *cfgs = nil;
    __block BOOL loaded = NO;
    [[NEConfigurationManager sharedManager] loadConfigurationsWithCompletionQueue:queue handler:^(NSArray<NEConfiguration *> *c, NSError *e) {
      cfgs = c; loaded = YES;
    }];
    while (!loaded) { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; }

    for (NEConfiguration *cfg in cfgs) {
      if (target && ![cfg.name isEqualToString:target]) continue;
      uuid_t u; [cfg.identifier getUUIDBytes:u];
      ne_session_t s = ne_session_create(u, NESessionTypeVPN);
      dispatch_semaphore_t sema = dispatch_semaphore_create(0);
      __block xpc_object_t cap = NULL;
      ne_session_get_info(s, 2, queue, ^(xpc_object_t r) { cap = r; dispatch_semaphore_signal(sema); });
      dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
      if (!cap || xpc_get_type(cap) != XPC_TYPE_DICTIONARY) { printf("%s: no info\n", cfg.name.UTF8String); continue; }

      printf("========= %s =========\n", cfg.name.UTF8String);
      xpc_object_t vpn = xpc_dictionary_get_value(cap, "VPN");
      if (vpn && xpc_get_type(vpn) == XPC_TYPE_DICTIONARY) {
        xpc_object_t lc = xpc_dictionary_get_value(vpn, "LastCause");
        if (lc && xpc_get_type(lc) == XPC_TYPE_INT64)
          printf("VPN.LastCause = %lld\n", xpc_int64_get_value(lc));
      }
      size_t len = 0;
      const void *bytes = xpc_dictionary_get_data(cap, "LastDisconnectError", &len);
      if (bytes && len) {
        NSData *d = [NSData dataWithBytes:bytes length:len];
        NSError *decErr = nil;
        id obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                    [NSSet setWithObjects:[NSError class], [NSString class], [NSNumber class], [NSDictionary class], [NSArray class], nil]
                                                     fromData:d error:&decErr];
        if ([obj isKindOfClass:[NSError class]]) {
          printf("LastDisconnectError (decoded NSError):\n");
          DumpError(obj, @"  ");
        } else {
          printf("LastDisconnectError decode -> %s (unarchive err: %s)\n",
                 [[obj description] UTF8String], [[decErr description] UTF8String]);
        }
      } else {
        printf("LastDisconnectError: (absent)\n");
      }
      printf("\n");
      ne_session_release(s);
    }
  }
  return 0;
}
