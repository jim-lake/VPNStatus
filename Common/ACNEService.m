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
    SCNetworkConnectionStatus scStatus = SCNetworkConnectionGetStatusFromNEStatus(status);

    if(scStatus == kSCNetworkConnectionDisconnected) {
      // Disconnected: read the extended status to learn WHY, so the
      // auto-connect policy can distinguish a clean user stop (leave it
      // disconnected, drop auto-connect) from an involuntary drop (reconnect).
      // Stay on neServiceQueue for the info query, then finish on the main queue.
      ne_session_get_info(_session, NESessionInfoTypeExtendedStatus, [[ACNEServicesManager sharedNEServicesManager] neServiceQueue], ^(xpc_object_t _Nullable info) {
        BOOL wasClean = [self disconnectWasCleanFromInfo:info];
        [self finishRefreshWithStatus:status lastDisconnectWasClean:wasClean connectedDate:nil];
      });
      return;
    }

    if(scStatus == kSCNetworkConnectionConnected) {
      // Connected: read the extended status to capture LastStatusChangeTime —
      // the reliable "connected since" timestamp used to render the live
      // connection duration. See NE_PRIVATE_VPN.md.
      ne_session_get_info(_session, NESessionInfoTypeExtendedStatus, [[ACNEServicesManager sharedNEServicesManager] neServiceQueue], ^(xpc_object_t _Nullable info) {
        NSDate *connectedDate = [self connectedDateFromInfo:info];
        [self finishRefreshWithStatus:status lastDisconnectWasClean:NO connectedDate:connectedDate];
      });
      return;
    }

    [self finishRefreshWithStatus:status lastDisconnectWasClean:NO connectedDate:nil];
  });
}

// LastStatusChangeTime is an xpc_date storing nanoseconds since the Unix epoch;
// while Connected it is the moment the session became Connected. Returns nil if
// absent or the wrong type. See NE_PRIVATE_VPN.md.
- (NSDate *)connectedDateFromInfo:(xpc_object_t _Nullable)inInfo {
  if(inInfo == NULL || xpc_get_type(inInfo) != XPC_TYPE_DICTIONARY) {
    return nil;
  }

  xpc_object_t lastStatusChangeTime = xpc_dictionary_get_value(inInfo, "LastStatusChangeTime");
  if(lastStatusChangeTime == NULL || xpc_get_type(lastStatusChangeTime) != XPC_TYPE_DATE) {
    return nil;
  }

  int64_t nanos = xpc_date_get_value(lastStatusChangeTime);
  return [NSDate dateWithTimeIntervalSince1970:(nanos / 1e9)];
}

// A clean, user-initiated stop is VPN.LastCause == 1 with NO LastDisconnectError.
// Any other cause, or the presence of a LastDisconnectError, is an involuntary
// drop. If the info dictionary is missing the cause entirely, treat it as NOT
// clean so auto-connect errs toward reconnecting. See NE_PRIVATE_VPN.md.
- (BOOL)disconnectWasCleanFromInfo:(xpc_object_t _Nullable)inInfo {
  if(inInfo == NULL || xpc_get_type(inInfo) != XPC_TYPE_DICTIONARY) {
    return NO;
  }

  size_t errorLength = 0;
  if(xpc_dictionary_get_data(inInfo, "LastDisconnectError", &errorLength) != NULL && errorLength > 0) {
    return NO;
  }

  xpc_object_t vpn = xpc_dictionary_get_value(inInfo, "VPN");
  if(vpn == NULL || xpc_get_type(vpn) != XPC_TYPE_DICTIONARY) {
    return NO;
  }

  xpc_object_t lastCause = xpc_dictionary_get_value(vpn, "LastCause");
  if(lastCause == NULL || xpc_get_type(lastCause) != XPC_TYPE_INT64) {
    return NO;
  }

  return xpc_int64_get_value(lastCause) == NELastCauseCleanUserStop;
}

- (void)finishRefreshWithStatus:(ne_session_status_t)inStatus lastDisconnectWasClean:(BOOL)inWasClean connectedDate:(NSDate *)inConnectedDate {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.sessionStatus = inStatus;
    self.lastDisconnectWasClean = inWasClean;
    self.connectedDate = inConnectedDate;
    self.gotInitialSessionStatus = YES;

    os_log_info(OS_LOG_DEFAULT, "VPN '%{public}@' (%{public}@) session status changed to %d (lastDisconnectWasClean=%{public}s)", self.name, [self.configuration.identifier UUIDString], (int)inStatus, inWasClean ? "YES" : "NO");

    // Post a notification to refresh the UI
    [[NSNotificationCenter defaultCenter] postNotificationName:kSessionStateChangedNotification object:nil];
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
