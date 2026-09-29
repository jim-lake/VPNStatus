#import "ACAutoConnectPolicy.h"

#import <os/log.h>

#import "ACConnectionManager.h"
#import "ACDefines.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"

@implementation ACAutoConnectPolicy

+ (ACAutoConnectPolicy *)sharedPolicy {
  static ACAutoConnectPolicy *sSharedPolicy = nil;
  if(sSharedPolicy == nil) {
    sSharedPolicy = [[ACAutoConnectPolicy alloc] init];
  }
  return sSharedPolicy;
}

- (instancetype)init {
  self = [super init];
  if(self) {
    _armedServiceIdentifiers = [[NSMutableSet alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionStateChanged:) name:kSessionStateChangedNotification object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)identifierForService:(ACNEService *)inService {
  return [inService.configuration.identifier UUIDString];
}

- (void)armServiceIdentifier:(NSString *)inServiceIdentifier {
  [self.armedServiceIdentifiers addObject:inServiceIdentifier];
}

- (void)disarmServiceIdentifier:(NSString *)inServiceIdentifier {
  [self.armedServiceIdentifiers removeObject:inServiceIdentifier];
}

- (BOOL)isArmedServiceIdentifier:(NSString *)inServiceIdentifier {
  return [self.armedServiceIdentifiers containsObject:inServiceIdentifier];
}

- (void)requestConnectService:(ACNEService *)inService {
  if(inService == nil) {
    return;
  }

  NSString *serviceIdentifier = [self identifierForService:inService];
  os_log_info(OS_LOG_DEFAULT, "user action: connect VPN '%{public}@' (%{public}@); arming auto-connect until Connected", inService.name, serviceIdentifier);

  [self armServiceIdentifier:serviceIdentifier];
  [inService connect];
}

- (void)requestDisconnectService:(ACNEService *)inService {
  if(inService == nil) {
    return;
  }

  NSString *serviceIdentifier = [self identifierForService:inService];
  os_log_info(OS_LOG_DEFAULT, "user action: disconnect VPN '%{public}@' (%{public}@)", inService.name, serviceIdentifier);

  [self disarmServiceIdentifier:serviceIdentifier];
  [[ACConnectionManager sharedManager] setAlwaysAutoConnect:NO forACNEService:inService];
  [inService disconnect];
}

- (void)requestCancelService:(ACNEService *)inService {
  if(inService == nil) {
    return;
  }

  NSString *serviceIdentifier = [self identifierForService:inService];
  os_log_info(OS_LOG_DEFAULT, "user action: cancel connecting VPN '%{public}@' (%{public}@)", inService.name, serviceIdentifier);

  [self disarmServiceIdentifier:serviceIdentifier];
  [[ACConnectionManager sharedManager] setAlwaysAutoConnect:NO forACNEService:inService];
  [inService cancel];
}

- (void)requestDisconnectServices:(NSArray<ACNEService *> *)inServices {
  os_log_info(OS_LOG_DEFAULT, "user action: disconnect %lu service(s)", (unsigned long)[inServices count]);

  ACConnectionManager *connectionManager = [ACConnectionManager sharedManager];
  for(ACNEService *neService in inServices) {
    [self disarmServiceIdentifier:[self identifierForService:neService]];
    [connectionManager setAlwaysAutoConnect:NO forACNEService:neService];
    [neService disconnect];
  }
}

- (void)sessionStateChanged:(NSNotification *)inNotification {
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    NSString *serviceIdentifier = [self identifierForService:neService];
    if([self isArmedServiceIdentifier:serviceIdentifier]) {
      [self handleState:[neService state] forService:neService];
    }
  }
}

- (void)handleState:(SCNetworkConnectionStatus)inState forService:(ACNEService *)inService {
  NSString *serviceIdentifier = [self identifierForService:inService];

  switch(inState) {
  case kSCNetworkConnectionConnected:
    os_log_info(OS_LOG_DEFAULT, "armed VPN (%{public}@) reached Connected; enabling auto-connect", serviceIdentifier);
    [self disarmServiceIdentifier:serviceIdentifier];
    [[ACConnectionManager sharedManager] setAlwaysAutoConnect:YES forACNEService:inService];
    break;

  case kSCNetworkConnectionDisconnected:
    os_log_info(OS_LOG_DEFAULT, "armed VPN (%{public}@) reached Disconnected without connecting; leaving auto-connect off", serviceIdentifier);
    [self disarmServiceIdentifier:serviceIdentifier];
    break;

  default:
    break;
  }
}

@end
