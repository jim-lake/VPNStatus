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
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionDisconnected name:@"VPN" connectedDate:nil], @"Connect VPN");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionDisconnected], @selector(connectService:));
}

- (void)testConnectedMapsToDisconnect {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionConnected name:@"VPN" connectedDate:nil], @"Disconnect VPN");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionConnected], @selector(disconnectService:));
}

// A connected row with a known "connected since" date shows a live h:mm:ss.
- (void)testConnectedWithDateShowsDuration {
  NSDate *fiveSecondsAgo = [NSDate dateWithTimeIntervalSinceNow:-5];
  NSString *title = [self.delegate titleForServiceActionState:kSCNetworkConnectionConnected name:@"VPN" connectedDate:fiveSecondsAgo];
  XCTAssertEqualObjects(title, @"Disconnect VPN - 0:00:05");
}

- (void)testConnectedWithDateShowsHoursMinutesSeconds {
  NSDate *start = [NSDate dateWithTimeIntervalSinceNow:-(1 * 3600 + 23 * 60 + 45)];
  NSString *title = [self.delegate titleForServiceActionState:kSCNetworkConnectionConnected name:@"VPN" connectedDate:start];
  XCTAssertEqualObjects(title, @"Disconnect VPN - 1:23:45");
}

- (void)testElapsedStringFormats {
  XCTAssertEqualObjects([self.delegate elapsedStringForInterval:0], @"0:00:00");
  XCTAssertEqualObjects([self.delegate elapsedStringForInterval:5], @"0:00:05");
  XCTAssertEqualObjects([self.delegate elapsedStringForInterval:65], @"0:01:05");
  XCTAssertEqualObjects([self.delegate elapsedStringForInterval:3661], @"1:01:01");
  // Hours are not capped at 24.
  XCTAssertEqualObjects([self.delegate elapsedStringForInterval:(26 * 3600)], @"26:00:00");
}

// The key new behavior: a Connecting service can be canceled.
- (void)testConnectingMapsToCancelAndIsActionable {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionConnecting name:@"VPN" connectedDate:nil], @"Disconnect VPN - Connecting...");
  SEL action = [self.delegate actionForServiceActionState:kSCNetworkConnectionConnecting];
  XCTAssertEqual(action, @selector(cancelService:));
  XCTAssertTrue(action != nil, @"Connecting rows must be actionable so the user can cancel");
}

// Disconnecting remains a non-actionable, informational row.
- (void)testDisconnectingIsNotActionable {
  XCTAssertEqualObjects([self.delegate titleForServiceActionState:kSCNetworkConnectionDisconnecting name:@"VPN" connectedDate:nil], @"Disconnecting VPN...");
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionDisconnecting], (SEL)NULL);
}

- (void)testInvalidIsNotActionable {
  XCTAssertEqual([self.delegate actionForServiceActionState:kSCNetworkConnectionInvalid], (SEL)NULL);
}

@end
