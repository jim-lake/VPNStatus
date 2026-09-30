//
//  ACNEService.h
//  VPN
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//
//	The ACNEService class replicates the ANPNEService class from Network.prefPane
//	The initializer takes a NEConfiguration object from the NetworkExtension.framework.
//
//

#import <Foundation/Foundation.h>
#import "ACDefines.h"

@interface ACNEService : NSObject

@property (retain) NEConfiguration *configuration;
@property (assign) ne_session_t session;

// Use to ensure we got the session status
@property (assign) BOOL gotInitialSessionStatus;

@property (assign) ne_session_status_t sessionStatus;

// While the state is Connected, the moment the session last transitioned
// (LastStatusChangeTime from ne_session_get_info type 2) — i.e. "connected
// since". nil whenever the service is not Connected. See NE_PRIVATE_VPN.md.
@property (strong, nullable) NSDate *connectedDate;

// After a disconnect, YES if the last disconnect was a clean, user-initiated
// stop (VPN.LastCause == 1, no LastDisconnectError); NO if it was an involuntary
// drop (server death/abort, network change, collateral kill, ...) that
// auto-connect should recover from. Meaningful only while the state is
// Disconnected; established on the disconnect event via ne_session_get_info.
@property (assign) BOOL lastDisconnectWasClean;

// init
- (instancetype)initWithConfiguration:(NEConfiguration *)inConfiguration;

// Access information
- (NSString *)name;
- (NSString *)serverAddress;
- (NSString *)protocol;

// Refresh and get the state of the session
- (void)refreshSession;
- (SCNetworkConnectionStatus)state;

// Connect and disconnect
- (void)connect;
- (void)disconnect;

// Cancel an in-progress connection (Connecting/Reasserting). Uses
// ne_session_cancel, which aborts negotiation, rather than ne_session_stop.
- (void)cancel;

@end
