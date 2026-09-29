//
//  ACConnectionManager.m
//  VPN
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//

#import "ACConnectionManager.h"

#import <os/log.h>

#import "ACConnectionManager_Internal.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"
#import "ACPreferences.h"

// To get the current WiFi SSID (CWInterface)
#import "CoreWLAN/CoreWLAN.h"

// Once a service has been continuously connected for this many seconds, its
// reconnect backoff is reset so a future drop starts from an immediate retry.
static const NSTimeInterval kBackoffStabilityResetSeconds = 120.0;

@implementation ACServiceBackoff
@end


@implementation ACConnectionManager

+ (ACConnectionManager *)sharedManager {
  static ACConnectionManager *sSharedManager = nil;
  if(sSharedManager == nil) {
    sSharedManager = [[ACConnectionManager alloc] init];
  }

  return sSharedManager;
}

- (instancetype)init {
  self = [super init];
  if(self) {
    _backoffByServiceIdentifier = [[NSMutableDictionary alloc] init];

    // React to every VPN session-state change: reconnect dropped always-connect
    // services (with per-service backoff) and manage the stability reset.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionStateChanged:) name:kSessionStateChangedNotification object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Backoff state

- (ACServiceBackoff *)backoffForServiceIdentifier:(NSString *)inServiceIdentifier {
  ACServiceBackoff *backoff = self.backoffByServiceIdentifier[inServiceIdentifier];
  if(backoff == nil) {
    backoff = [[ACServiceBackoff alloc] init];
    backoff.nextDelay = 0;
    self.backoffByServiceIdentifier[inServiceIdentifier] = backoff;
  }
  return backoff;
}

// Reset a service's backoff to the start of the sequence (next retry immediate)
// and cancel any pending retry / stability timers.
- (void)resetBackoffForServiceIdentifier:(NSString *)inServiceIdentifier {
  ACServiceBackoff *backoff = self.backoffByServiceIdentifier[inServiceIdentifier];
  if(backoff == nil) {
    return;
  }

  os_log_info(OS_LOG_DEFAULT, "reset reconnect backoff for %{public}@", inServiceIdentifier);

  [backoff.retryTimer invalidate];
  backoff.retryTimer = nil;
  [backoff.stabilityTimer invalidate];
  backoff.stabilityTimer = nil;
  backoff.nextDelay = 0;
}

// Advance the delay sequence: 0 (immediate) -> min -> clamp(previous*2, 1, max).
// The growth path always floors to 1 so the sequence cannot get stuck at 0 when
// min is 0 (otherwise doubling 0 stays 0 forever).
- (NSInteger)advanceDelay:(NSInteger)inCurrentDelay {
  NSInteger minReconnect = [[ACPreferences sharedPreferences] minReconnect];
  NSInteger maxReconnect = [[ACPreferences sharedPreferences] maxReconnect];

  NSInteger next;
  if(inCurrentDelay <= 0) {
    // Leaving the immediate (0) attempt: step to min, but never stall at 0 —
    // if min is 0, floor to 1 so doubling can take over.
    next = (minReconnect >= 1) ? minReconnect : 1;
  } else {
    next = inCurrentDelay * 2;
    if(next < 1) {
      next = 1;
    }
  }

  if(next > maxReconnect) {
    next = maxReconnect;
  }
  if(next < 0) {
    next = 0;
  }

  return next;
}

#pragma mark - Session events

- (void)sessionStateChanged:(NSNotification *)inNotification {
  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];

  for(ACNEService *neService in neServices) {
    NSString *serviceIdentifier = [neService.configuration.identifier UUIDString];
    if(![alwaysConnectedServicesIdentifiers containsObject:serviceIdentifier]) {
      // Not an always-connect service: nothing to schedule. If it happens to
      // carry stale backoff state, drop it.
      [self resetBackoffForServiceIdentifier:serviceIdentifier];
      [self.backoffByServiceIdentifier removeObjectForKey:serviceIdentifier];
      continue;
    }

    [self handleStateForAlwaysConnectService:neService];
  }
}

- (void)handleStateForAlwaysConnectService:(ACNEService *)inService {
  NSString *serviceIdentifier = [inService.configuration.identifier UUIDString];
  SCNetworkConnectionStatus state = [inService state];
  ACServiceBackoff *backoff = [self backoffForServiceIdentifier:serviceIdentifier];

  switch(state) {
  case kSCNetworkConnectionConnected:
    // Connected: no pending retry needed. Start (or keep) the stability timer
    // that resets the backoff once the connection has held long enough.
    [backoff.retryTimer invalidate];
    backoff.retryTimer = nil;
    if(backoff.stabilityTimer == nil) {
      __weak ACConnectionManager *weakSelf = self;
      backoff.stabilityTimer = [NSTimer scheduledTimerWithTimeInterval:kBackoffStabilityResetSeconds
                                                               repeats:NO
                                                                 block:^(NSTimer *timer) {
                                                                   os_log_info(OS_LOG_DEFAULT, "VPN %{public}@ stable for %.0fs; resetting backoff", serviceIdentifier, kBackoffStabilityResetSeconds);
                                                                   [weakSelf resetBackoffForServiceIdentifier:serviceIdentifier];
                                                                 }];
    }
    break;

  case kSCNetworkConnectionDisconnected:
    // Dropped: the stability window is broken; schedule a backed-off retry.
    [backoff.stabilityTimer invalidate];
    backoff.stabilityTimer = nil;
    [self scheduleReconnectForService:inService];
    break;

  default:
    // Connecting / disconnecting / invalid: transitional, take no action.
    break;
  }
}

// Schedule a reconnect for a dropped always-connect service after its current
// backoff delay, then advance the delay for the next attempt. Idempotent: if a
// retry is already pending for this service, leave it in place.
- (void)scheduleReconnectForService:(ACNEService *)inService {
  NSString *serviceIdentifier = [inService.configuration.identifier UUIDString];
  ACServiceBackoff *backoff = [self backoffForServiceIdentifier:serviceIdentifier];

  if(backoff.retryTimer != nil) {
    // Already scheduled; don't stack retries for the same service.
    return;
  }

  if([self shouldPreventAutoConnectOnCurrentSSID]) {
    os_log_info(OS_LOG_DEFAULT, "auto-connect skipping %{public}@ due to ignored SSID", serviceIdentifier);
    return;
  }

  NSInteger delay = backoff.nextDelay;
  backoff.nextDelay = [self advanceDelay:delay];

  os_log_info(OS_LOG_DEFAULT, "scheduling reconnect for VPN '%{public}@' (%{public}@) in %lds (next delay %lds)", inService.name, serviceIdentifier, (long)delay, (long)backoff.nextDelay);

  __weak ACConnectionManager *weakSelf = self;
  backoff.retryTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)delay
                                                       repeats:NO
                                                         block:^(NSTimer *timer) {
                                                           [weakSelf performScheduledReconnectForServiceIdentifier:serviceIdentifier];
                                                         }];
}

- (void)performScheduledReconnectForServiceIdentifier:(NSString *)inServiceIdentifier {
  ACServiceBackoff *backoff = self.backoffByServiceIdentifier[inServiceIdentifier];
  backoff.retryTimer = nil;

  // Re-validate: the service may have been unmarked, connected, or the SSID
  // rules may now apply.
  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];
  if(![alwaysConnectedServicesIdentifiers containsObject:inServiceIdentifier]) {
    return;
  }

  if([self shouldPreventAutoConnectOnCurrentSSID]) {
    os_log_info(OS_LOG_DEFAULT, "auto-connect skipping %{public}@ due to ignored SSID", inServiceIdentifier);
    return;
  }

  [self startConnectionForService:inServiceIdentifier];
}

#pragma mark - Connect / disconnect

- (void)toggleConnectionForService:(ACNEService *)inService {
  if(inService == nil)
    return;

  SCNetworkConnectionStatus serviceState = [inService state];

  switch(serviceState) {
  case kSCNetworkConnectionDisconnected: {
    // Connect
    [inService connect];
  } break;

  case kSCNetworkConnectionConnected: {
    // Disconnect
    [inService disconnect];
  } break;

  default:
    break;
  }
}

- (void)startConnectionForService:(NSString *)inServiceIdentifier {
  if([inServiceIdentifier length] <= 0)
    return;

  // Get all services and find the correct NEService
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];

  ACNEService *foundNEService = nil;
  for(ACNEService *neService in neServices) {
    if([inServiceIdentifier isEqualToString:[neService.configuration.identifier UUIDString]]) {
      foundNEService = neService;
      break;
    }
  }

  // Connect to the service if it is currently disconnected
  if(foundNEService != nil) {
    if([foundNEService state] == kSCNetworkConnectionDisconnected) {
      os_log_info(OS_LOG_DEFAULT, "auto-connect connecting VPN '%{public}@' (%{public}@)", foundNEService.name, inServiceIdentifier);
      [foundNEService connect];
    }
  }
}

- (void)setAlwaysAutoConnect:(BOOL)inAlwaysAutoConnect forACNEService:(ACNEService *)inNEService {
  if(inNEService == nil)
    return;

  NSString *serviceIdentifier = [inNEService.configuration.identifier UUIDString];

  os_log_info(OS_LOG_DEFAULT, "set always-auto-connect=%{public}s for VPN '%{public}@' (%{public}@)", inAlwaysAutoConnect ? "YES" : "NO", inNEService.name, serviceIdentifier);

  // Save the preferences
  [[ACPreferences sharedPreferences] setAlwaysConnected:inAlwaysAutoConnect forServicesIdentifier:serviceIdentifier];

  // Toggling auto-connect (either direction) resets this service's backoff.
  [self resetBackoffForServiceIdentifier:serviceIdentifier];
}

- (BOOL)isAtLeastOneServiceSetToAutoConnect {
  BOOL outCanEnableAutoConnect = NO;

  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];
  if([alwaysConnectedServicesIdentifiers count] <= 0)
    return outCanEnableAutoConnect;

  // Check each service
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    if([alwaysConnectedServicesIdentifiers containsObject:[neService.configuration.identifier UUIDString]]) {
      outCanEnableAutoConnect = YES;
      break;
    }
  }

  return outCanEnableAutoConnect;
}

- (void)disconnectAllAutoConnectedServices {
  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];
  if([alwaysConnectedServicesIdentifiers count] <= 0)
    return;

  os_log_info(OS_LOG_DEFAULT, "disconnecting all auto-connected services (%lu)", (unsigned long)[alwaysConnectedServicesIdentifiers count]);

  // Disconnect each service marked as always auto connecting
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    if([alwaysConnectedServicesIdentifiers containsObject:[neService.configuration.identifier UUIDString]]) {
      [neService disconnect];
    }
  }
}

/**
  Return YES if the current WiFi SSID is in the list of SSIDs to ignore
*/
- (BOOL)shouldPreventAutoConnectOnCurrentSSID {
  // Assuming we have any Wi-Fi interfaces available...
  if([[CWWiFiClient interfaceNames] count] > 0) {
    CWInterface *wifi = [[CWWiFiClient sharedWiFiClient] interface];
    NSArray<NSString *> *ignoredSSIDs = [[ACPreferences sharedPreferences] ignoredSSIDs];

    // ...if the current SSID exists, and it's in the list of ignored SSIDs...
    if(wifi.ssid != nil && [ignoredSSIDs containsObject:wifi.ssid]) {
      // ...do not connect.
      return YES;
    }
  }

  return NO;
}

- (void)connectAllAutoConnectedServices {
  NSArray<NSString *> *alwaysConnectedServicesIdentifiers = [[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers];
  if([alwaysConnectedServicesIdentifiers count] <= 0)
    return;

  os_log_info(OS_LOG_DEFAULT, "connecting all auto-connected services (%lu)", (unsigned long)[alwaysConnectedServicesIdentifiers count]);

  // Connect each service marked as always auto connecting
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    if([alwaysConnectedServicesIdentifiers containsObject:[neService.configuration.identifier UUIDString]]) {
      BOOL shouldConnect = YES;

      // If the current WiFi SSID is is the list of ignored SSID, we shouldn't auto connect
      if([self shouldPreventAutoConnectOnCurrentSSID]) {
        shouldConnect = NO;
      }

      if(shouldConnect) {
        [neService connect];
      }
    }
  }
}

@end
