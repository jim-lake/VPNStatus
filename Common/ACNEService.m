//
//  ACNEService.m
//  VPN
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//

#import "ACNEService.h"

#import <os/log.h>

#import "ACNEServicesManager.h"

@implementation ACNEService

- (instancetype)initWithConfiguration:(NEConfiguration *)inConfiguration {
  self = [super init];
  if(self) {
    _configuration = inConfiguration;
    _gotInitialSessionStatus = NO;

    // Get the configuration identifier to initialize the ne_session_t
    NSUUID *uuid = [inConfiguration identifier];
    uuid_t uuidBytes;
    [uuid getUUIDBytes:uuidBytes];

    // Create the ne_session
    _session = ne_session_create(uuidBytes, NESessionTypeVPN);

    // Setup the callbacks
    [self setupEventCallback];
    [self refreshSession];
  }

  return self;
}

- (void)dealloc {
  ne_session_set_event_handler(_session, [[ACNEServicesManager sharedNEServicesManager] neServiceQueue], ^(ne_session_event_t event, void *event_data){
                                           // Nothing
                                         });

  // Cancel and release the session
  ne_session_cancel(_session);
  ne_session_release(_session);
}

- (NSString *)name {
  return _configuration.name;
}

- (NSString *)serverAddress {
  NSString *serverAddress = _configuration.VPN.protocol.serverAddress;
  return ([serverAddress length] > 0) ? serverAddress : @"Unknown";
}

- (NSString *)protocol {
  NEVPNProtocol *protocol = _configuration.VPN.protocol;
  if([protocol isKindOfClass:[NEVPNProtocolIKEv2 class]]) {
    return @"IKEv2";
  } else if([protocol isKindOfClass:[NEVPNProtocolIPSec class]]) {
    return @"IPSec";
  } else if([[protocol className] isEqualToString:@"NEVPNProtocolL2TP"]) {
    // The NEVPNProtocolL2TP is a private class of the public NetworkExtension.framework
    return @"L2TP";
  }

  // Fallback to catch future protocols?
  NSString *className = [protocol className];
  if([className hasPrefix:@"NEVPNProtocol"]) {
    return [className substringFromIndex:[@"NEVPNProtocol" length]];
  }


  return @"Unknown";
}

- (SCNetworkConnectionStatus)state {
  if(self.gotInitialSessionStatus) {
    return SCNetworkConnectionGetStatusFromNEStatus(self.sessionStatus);
  } else {
    return kSCNetworkConnectionInvalid;
  }
}

- (void)setupEventCallback {
  ne_session_set_event_handler(_session, [[ACNEServicesManager sharedNEServicesManager] neServiceQueue], ^(ne_session_event_t event, void *event_data) {
    [self refreshSession];
  });
}

- (void)refreshSession {
  ne_session_get_status(_session, [[ACNEServicesManager sharedNEServicesManager] neServiceQueue], ^(ne_session_status_t status) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.sessionStatus = status;
      self.gotInitialSessionStatus = YES;

      os_log_info(OS_LOG_DEFAULT, "VPN '%{public}@' (%{public}@) session status changed to %d", self.name, [self.configuration.identifier UUIDString], (int)status);

      // Post a notification to refresh the UI
      [[NSNotificationCenter defaultCenter] postNotificationName:kSessionStateChangedNotification object:nil];
    });
  });
}

- (void)connect {
  os_log_info(OS_LOG_DEFAULT, "connect VPN '%{public}@' (%{public}@)", self.name, [self.configuration.identifier UUIDString]);
  ne_session_start(_session);
}

- (void)disconnect {
  os_log_info(OS_LOG_DEFAULT, "disconnect VPN '%{public}@' (%{public}@)", self.name, [self.configuration.identifier UUIDString]);
  ne_session_stop(_session);
}

- (void)cancel {
  os_log_info(OS_LOG_DEFAULT, "cancel connecting VPN '%{public}@' (%{public}@)", self.name, [self.configuration.identifier UUIDString]);

  // Aborting an in-progress connection is done with ne_session_stop, not
  // ne_session_cancel. ne_session_cancel tears down the client session object
  // (it is what -dealloc uses before ne_session_release); it does NOT stop the
  // daemon's ongoing negotiation, so a Connecting session stays stuck at
  // Connecting. ne_session_stop actually drives it Disconnecting -> Disconnected
  // and fires the event handler, which refreshes the UI.
  ne_session_stop(_session);
}

@end
