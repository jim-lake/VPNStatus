//
//  AppDelegateServiceRowTests.m
//  VPNStatusTests
//
//  Unit tests for AppDelegate's per-service menu-row mapping: which title and
//  action each VPN connection state produces. In particular that a Connecting
//  service is actionable and mapped to -cancelService: (cancel support), and
//  that Disconnecting / invalid states stay non-actionable.
//

#import <XCTest/XCTest.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "AppDelegate.h"

@interface AppDelegateServiceRowTests : XCTestCase
@property (strong) AppDelegate *delegate;
@end

@implementation AppDelegateServiceRowTests

- (void)setUp {
  [super setUp];
  self.delegate = [[AppDelegate alloc] init];
}

- (void)tearDown {
  self.delegate = nil;
  [super tearDown];
}

- (void)testDisconnectedMapsToConnect {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionDisconnected name:@"VPN"], @"Connect VPN");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionDisconnected], @selector(connectService:));
}

- (void)testConnectedMapsToDisconnect {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionConnected name:@"VPN"], @"Disconnect VPN");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionConnected], @selector(disconnectService:));
}

// The key new behavior: a Connecting service can be canceled.
- (void)testConnectingMapsToCancelAndIsActionable {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionConnecting name:@"VPN"], @"Disconnect VPN - Connecting...");
  SEL action = [self.delegate actionForServiceActionState:kSCNetworkConnectionConnecting];
  XCTAssertEqual(action, @selector(cancelService:));
  XCTAssertTrue(action != nil, @"Connecting rows must be actionable so the user can cancel");
}

// Disconnecting remains a non-actionable, informational row.
- (void)testDisconnectingIsNotActionable {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionDisconnecting name:@"VPN"], @"Disconnecting VPN...");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionDisconnecting], (SEL)NULL);
}

- (void)testInvalidIsNotActionable {
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionInvalid], (SEL)NULL);
}

@end
