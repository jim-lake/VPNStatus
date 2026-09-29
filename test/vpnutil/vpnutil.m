//
// vpnutil.m — standalone NetworkExtension VPN debugging CLI
//
// A self-contained command-line tool for inspecting the NE/IKEv2 VPNs that
// macOS's stock tooling (scutil --nc, networksetup) cannot see. Reaches into
// the private NEConfigurationManager / ne_session_* APIs — the same path the
// VPNStatus app uses — so it observes the real VPN state.
//
// Built off the original vpnutil from https://github.com/Timac/VPNStatus
// (Alexandre Colucci, blog.timac.org). This version is a single translation
// unit with no dependency on the app's Common/ sources, and adds a `dump`
// command for enhanced debugging: it probes every ne_session_get_info info
// type and pretty-prints the raw XPC dictionaries (byte counters, connect
// time, disconnect cause, routing, etc.).
//
// Build:
//   clang -fobjc-arc -framework Foundation -framework SystemConfiguration \
//         -framework NetworkExtension -o vpnutil vpnutil.m
//
// Usage:
//   ./vpnutil list                 # JSON of {name, status} for every NE VPN
//   ./vpnutil status <name>        # one line: "<name> <Status>"
//   ./vpnutil dump <name>          # raw ne_session_get_info dictionaries
//   ./vpnutil dump                 # dump every VPN
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <NetworkExtension/NetworkExtension.h>
#import <xpc/xpc.h>

#pragma mark - Private API declarations

// See /usr/lib/system/libsystem_networkextension.dylib and Apple's open-source
// configd (SCNetworkConnection.c). These private symbols are re-declared here;
// if Apple changes them in a future macOS this is where breakage surfaces.
//
// ne_session_get_info reference: OSXPrivateSDK ne_session.h
//   https://github.com/samdmarshall/OSXPrivateSDK

typedef int ne_session_status_t;
typedef struct ne_session_t *ne_session_t;

#define NESessionTypeVPN 1

extern ne_session_t ne_session_create(uuid_t serviceID, int sessionConfigType);
extern void ne_session_release(ne_session_t session);
extern void ne_session_start(ne_session_t session);
extern void ne_session_stop(ne_session_t session);
extern void ne_session_cancel(ne_session_t session);

typedef int ne_session_event_t;
typedef void (^ne_session_set_event_handler_block)(ne_session_event_t event, void *event_data);
extern void ne_session_set_event_handler(ne_session_t session, dispatch_queue_t queue, ne_session_set_event_handler_block block);

typedef void (^ne_session_get_status_block)(ne_session_status_t result);
extern void ne_session_get_status(ne_session_t session, dispatch_queue_t queue, ne_session_get_status_block block);

// Returns an xpc_object_t dictionary describing the session. `info` is an
// NESessionInfoType selector. Empirically on macOS 15/26:
//   1 -> connection byte/packet statistics
//   2 -> extended status (LastStatusChangeTime, IPv4, VPN{ConnectTime,
//        RemoteAddress, LastCause}, ConnectionStatistics, StartMessage, ...)
// Other selectors time out (no result).
typedef void (^ne_session_get_info_block)(xpc_object_t _Nullable result);
extern void ne_session_get_info(ne_session_t session, int info, dispatch_queue_t queue, ne_session_get_info_block block);

extern SCNetworkConnectionStatus SCNetworkConnectionGetStatusFromNEStatus(ne_session_status_t status);

@interface NEVPN : NSObject
@property (copy) NEVPNProtocol *protocol;
@end

@interface NEConfiguration : NSObject
@property (readonly) NSUUID *identifier;
@property (copy) NSString *name;
@property (copy) NEVPN *VPN;
@end

@interface NEConfigurationManager : NSObject
+ (id)sharedManager;
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)completionQueue handler:(void (^)(NSArray<NEConfiguration *> *_Nullable configurations, NSError *_Nullable error))handler;
@end

#pragma mark - Helpers

static NSString *DescribeStatus(SCNetworkConnectionStatus status) {
  switch (status) {
    case kSCNetworkConnectionInvalid:
      return @"Invalid";
    case kSCNetworkConnectionDisconnected:
      return @"Disconnected";
    case kSCNetworkConnectionConnecting:
      return @"Connecting";
    case kSCNetworkConnectionConnected:
      return @"Connected";
    case kSCNetworkConnectionDisconnecting:
      return @"Disconnecting";
    default:
      return @"Unknown";
  }
}

// NEVPNConnectionError, confirmed from the macOS SDK header
// NetworkExtension.framework/Headers/NEVPNConnection.h (domain
// NEVPNConnectionErrorDomain, macOS 13+). This is the enum the app should map
// the VPN.LastCause field against IF LastCause proves to use it — that mapping
// is NOT yet empirically confirmed (a manual disconnect yields LastCause == 1,
// which the enum labels "Overslept", a poor fit for a user-initiated stop).
// Keep this table for reference while validating with the `dump` command.
static NSString *DescribeVPNConnectionError(int64_t code) {
  switch (code) {
    case 1:
      return @"Overslept";
    case 2:
      return @"NoNetworkAvailable";
    case 3:
      return @"UnrecoverableNetworkChange";
    case 4:
      return @"ConfigurationFailed";
    case 5:
      return @"ServerAddressResolutionFailed";
    case 6:
      return @"ServerNotResponding";
    case 7:
      return @"ServerDead";
    case 8:
      return @"AuthenticationFailed";
    case 9:
      return @"ClientCertificateInvalid";
    case 10:
      return @"ClientCertificateNotYetValid";
    case 11:
      return @"ClientCertificateExpired";
    case 12:
      return @"PluginFailed";
    case 13:
      return @"ConfigurationNotFound";
    case 14:
      return @"PluginDisabled";
    case 15:
      return @"NegotiationFailed";
    case 16:
      return @"ServerDisconnected";
    case 17:
      return @"ServerCertificateInvalid";
    case 18:
      return @"ServerCertificateNotYetValid";
    case 19:
      return @"ServerCertificateExpired";
    default:
      return @"Unknown";
  }
}

static void PrintUsage(void) {
  fprintf(stderr, "Usage: vpnutil [list|status|dump] [VPN name]\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "  list           JSON of {name, status} for every NE VPN\n");
  fprintf(stderr, "  status <name>  one line: \"<name> <Status>\"\n");
  fprintf(stderr, "  dump [<name>]  raw ne_session_get_info dictionaries (all VPNs if no name)\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "Built off https://github.com/Timac/VPNStatus\n");
  exit(1);
}

#pragma mark - Model

@interface Service : NSObject
@property (retain) NEConfiguration *configuration;
@property (assign) ne_session_t session;
@property (assign) BOOL gotStatus;
@property (assign) ne_session_status_t status;
@property (readonly) NSString *name;
@property (readonly) SCNetworkConnectionStatus state;
@end

@implementation Service

- (instancetype)initWithConfiguration:(NEConfiguration *)configuration queue:(dispatch_queue_t)queue {
  self = [super init];
  if (self) {
    _configuration = configuration;
    _gotStatus = NO;

    NSUUID *uuid = [configuration identifier];
    uuid_t uuidBytes;
    [uuid getUUIDBytes:uuidBytes];
    _session = ne_session_create(uuidBytes, NESessionTypeVPN);

    ne_session_get_status(_session, queue, ^(ne_session_status_t status) {
      self.status = status;
      self.gotStatus = YES;
    });
  }
  return self;
}

- (NSString *)name {
  return _configuration.name;
}

- (SCNetworkConnectionStatus)state {
  if (self.gotStatus) {
    return SCNetworkConnectionGetStatusFromNEStatus(self.status);
  }
  return kSCNetworkConnectionInvalid;
}

@end

#pragma mark - dump

static void DumpService(Service *service, dispatch_queue_t queue) {
  printf("========================================================\n");
  printf("VPN '%s' (state: %s)\n", [service.name UTF8String],
         [DescribeStatus(service.state) UTF8String]);
  printf("UUID: %s\n", [[service.configuration.identifier UUIDString] UTF8String]);
  printf("========================================================\n\n");

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  for (int infoType = 0; infoType <= 12; infoType++) {
    __block xpc_object_t captured = NULL;
    ne_session_get_info(service.session, infoType, queue, ^(xpc_object_t result) {
      captured = result;
      dispatch_semaphore_signal(sema);
    });

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

    if (captured != NULL) {
      char *desc = xpc_copy_description(captured);
      printf("=== info type %d ===\n%s\n", infoType, desc ? desc : "(null description)");
      if (desc) {
        free(desc);
      }

      // Decode a few interesting fields when present in the extended status.
      if (xpc_get_type(captured) == XPC_TYPE_DICTIONARY) {
        xpc_object_t vpn = xpc_dictionary_get_value(captured, "VPN");
        if (vpn && xpc_get_type(vpn) == XPC_TYPE_DICTIONARY) {
          xpc_object_t lastCause = xpc_dictionary_get_value(vpn, "LastCause");
          if (lastCause && xpc_get_type(lastCause) == XPC_TYPE_INT64) {
            int64_t code = xpc_int64_get_value(lastCause);
            printf("  [decoded] VPN.LastCause = %lld  (NEVPNConnectionError candidate: %s)\n",
                   code, [DescribeVPNConnectionError(code) UTF8String]);
          }
        }
        xpc_object_t lastChange = xpc_dictionary_get_value(captured, "LastStatusChangeTime");
        if (lastChange && xpc_get_type(lastChange) == XPC_TYPE_DATE) {
          int64_t nanos = xpc_date_get_value(lastChange);
          NSDate *date = [NSDate dateWithTimeIntervalSince1970:(nanos / 1e9)];
          printf("  [decoded] LastStatusChangeTime = %s\n", [[date description] UTF8String]);
        }
      }
      printf("\n");
    } else {
      printf("=== info type %d ===\n(no result / timed out)\n\n", infoType);
    }
  }
}

#pragma mark - main

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc <= 1) {
      PrintUsage();
    }

    NSString *command = [NSString stringWithUTF8String:argv[1]];
    BOOL listCommand = [command isEqualToString:@"list"];
    BOOL statusCommand = [command isEqualToString:@"status"];
    BOOL dumpCommand = [command isEqualToString:@"dump"];

    if (!listCommand && !statusCommand && !dumpCommand) {
      PrintUsage();
    }

    // status requires a name; dump takes an optional name; list takes none.
    NSString *vpnName = nil;
    if (statusCommand) {
      if (argc != 3) {
        PrintUsage();
      }
      vpnName = [NSString stringWithUTF8String:argv[2]];
    } else if (dumpCommand && argc >= 3) {
      vpnName = [NSString stringWithUTF8String:argv[2]];
    } else if (listCommand && argc != 2) {
      PrintUsage();
    }

    dispatch_queue_t queue = dispatch_queue_create("vpnutil.session.queue", NULL);
    __block NSMutableArray<Service *> *services = [[NSMutableArray alloc] init];
    __block BOOL loaded = NO;

    [[NEConfigurationManager sharedManager] loadConfigurationsWithCompletionQueue:queue handler:^(NSArray<NEConfiguration *> *configurations, NSError *error) {
      if (error != nil) {
        fprintf(stderr, "Failed to load configurations: %s\n", [[error localizedDescription] UTF8String]);
      }
      for (NEConfiguration *configuration in configurations) {
        if ([configuration.name hasPrefix:@"com.apple.preferences."]) {
          continue;
        }
        [services addObject:[[Service alloc] initWithConfiguration:configuration queue:queue]];
      }
      [services sortUsingComparator:^NSComparisonResult(Service *a, Service *b) {
        return [a.name compare:b.name];
      }];
      loaded = YES;
    }];

    // Manually pump the run loop: wait for configs + a valid status for each
    // service, at least 1s, timing out after 10s.
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.25];
    BOOL keepRunning = YES;
    while (keepRunning && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:tick]) {
      tick = [NSDate dateWithTimeIntervalSinceNow:0.25];

      if (start + 10.0 < CFAbsoluteTimeGetCurrent()) {
        break;
      }
      if (start + 1.0 < CFAbsoluteTimeGetCurrent() && loaded) {
        keepRunning = NO;
        for (Service *service in services) {
          if (!service.gotStatus) {
            keepRunning = YES;
          }
        }
      }
    }

    if (listCommand) {
      NSMutableArray *vpns = [[NSMutableArray alloc] init];
      for (Service *service in services) {
        [vpns addObject:@{@"name" : service.name, @"status" : DescribeStatus(service.state)}];
      }
      NSDictionary *root = [vpns count] > 0 ? @{@"VPNs" : vpns} : @{};
      NSData *json = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
      printf("%s\n", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
    } else if (statusCommand) {
      Service *found = nil;
      for (Service *service in services) {
        if ([service.name isEqualToString:vpnName]) {
          found = service;
          break;
        }
      }
      if (found) {
        printf("%s %s\n", [found.name UTF8String], [DescribeStatus(found.state) UTF8String]);
      } else {
        fprintf(stderr, "Could not find %s\n", [vpnName UTF8String]);
        return 1;
      }
    } else if (dumpCommand) {
      BOOL any = NO;
      for (Service *service in services) {
        if (vpnName == nil || [service.name isEqualToString:vpnName]) {
          DumpService(service, queue);
          any = YES;
        }
      }
      if (!any) {
        fprintf(stderr, "Could not find %s\n", [vpnName UTF8String]);
        return 1;
      }
    }
  }
  return 0;
}
