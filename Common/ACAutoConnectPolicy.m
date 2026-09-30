#import "ACAutoConnectPolicy.h"

#import <os/log.h>

#import "ACConnectionManager.h"
#import "ACDefines.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"
#import "ACPreferences.h"

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
  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];

  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    NSString *serviceIdentifier = [self identifierForService:neService];

    if([self isArmedServiceIdentifier:serviceIdentifier]) {
      [self handleState:[neService state] forService:neService];
      continue;
    }

    // An always-auto-connect service that is cleanly (user-initiated) stopped
    // should have auto-connect turned off, which also cancels the reconnect
    // loop. Involuntary drops (server death, network change, ...) are left for
    // ACConnectionManager to reconnect.
    if([alwaysConnectedServicesIdentifiers containsObject:serviceIdentifier]) {
      [self handleAlwaysConnectState:[neService state] wasClean:[neService lastDisconnectWasClean] forService:neService];
    }
  }
}

- (void)handleAlwaysConnectState:(SCNetworkConnectionStatus)inState wasClean:(BOOL)inWasClean forService:(ACNEService *)inService {
  if(inState != kSCNetworkConnectionDisconnected || !inWasClean) {
    return;
  }

  NSString *serviceIdentifier = [self identifierForService:inService];
  os_log_info(OS_LOG_DEFAULT, "auto-connect VPN '%{public}@' (%{public}@) was cleanly disconnected; disabling auto-connect and cancelling reconnect", inService.name, serviceIdentifier);
  [[ACConnectionManager sharedManager] setAlwaysAutoConnect:NO forACNEService:inService];
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
