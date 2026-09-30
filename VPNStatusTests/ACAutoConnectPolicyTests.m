#import <XCTest/XCTest.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "ACAutoConnectPolicy.h"
#import "ACDefines.h"
#import "ACNEService.h"
#import "ACPreferences.h"

@interface ACAutoConnectFakeConfiguration : NSObject
@property (copy) NSString *name;
@property (strong, nullable) NEVPN *VPN;
@property (strong) NSUUID *identifier;
@end

@implementation ACAutoConnectFakeConfiguration
- (instancetype)init {
  self = [super init];
  if(self) {
    _identifier = [NSUUID UUID];
    _VPN = [[NEVPN alloc] init];
  }
  return self;
}
@end

@interface ACAutoConnectPolicyTests : XCTestCase
@property (strong) ACAutoConnectPolicy *policy;
@property (strong) ACNEService *service;
@property (copy) NSString *serviceIdentifier;
@end

@implementation ACAutoConnectPolicyTests

- (void)setUp {
  [super setUp];
  self.policy = [[ACAutoConnectPolicy alloc] init];

  ACAutoConnectFakeConfiguration *config = [[ACAutoConnectFakeConfiguration alloc] init];
  self.service = [[ACNEService alloc] initWithConfiguration:(NEConfiguration *)config];
  self.serviceIdentifier = [config.identifier UUIDString];

  // Start from a known-clean auto-connect state for this service.
  [[ACPreferences sharedPreferences] setAlwaysConnected:NO forServicesIdentifier:self.serviceIdentifier];
}

- (void)tearDown {
  [[ACPreferences sharedPreferences] setAlwaysConnected:NO forServicesIdentifier:self.serviceIdentifier];
  self.service = nil;
  self.policy = nil;
  [super tearDown];
}

- (BOOL)isPersistedAutoConnect {
  return [[[ACPreferences sharedPreferences] alwaysConnectedServicesIdentifiers] containsObject:self.serviceIdentifier];
}

- (void)testArmedReachingConnectedEnablesAutoConnectAndDisarms {
  [self.policy armServiceIdentifier:self.serviceIdentifier];

  [self.policy handleState:kSCNetworkConnectionConnected forService:self.service];

  XCTAssertTrue([self isPersistedAutoConnect], @"reaching Connected while armed must enable auto-connect");
  XCTAssertFalse([self.policy isArmedServiceIdentifier:self.serviceIdentifier], @"committing must disarm");
}

- (void)testArmedReachingDisconnectedDoesNotEnableAutoConnect {
  [self.policy armServiceIdentifier:self.serviceIdentifier];

  [self.policy handleState:kSCNetworkConnectionDisconnected forService:self.service];

  XCTAssertFalse([self isPersistedAutoConnect], @"a failed attempt (Connecting -> Disconnected) must NOT enable auto-connect");
  XCTAssertFalse([self.policy isArmedServiceIdentifier:self.serviceIdentifier], @"a failed attempt must disarm");
}

- (void)testConnectingKeepsServiceArmedWithoutCommitting {
  [self.policy armServiceIdentifier:self.serviceIdentifier];

  [self.policy handleState:kSCNetworkConnectionConnecting forService:self.service];

  XCTAssertFalse([self isPersistedAutoConnect], @"still Connecting must not enable auto-connect yet");
  XCTAssertTrue([self.policy isArmedServiceIdentifier:self.serviceIdentifier], @"still Connecting must stay armed");
}

- (void)testDisconnectRequestDisablesAutoConnectImmediately {
  [[ACPreferences sharedPreferences] setAlwaysConnected:YES forServicesIdentifier:self.serviceIdentifier];
  XCTAssertTrue([self isPersistedAutoConnect]);

  [self.policy requestDisconnectService:self.service];

  XCTAssertFalse([self isPersistedAutoConnect], @"disconnect must turn auto-connect off immediately");
  XCTAssertFalse([self.policy isArmedServiceIdentifier:self.serviceIdentifier]);
}

- (void)testCancelRequestDisablesAutoConnectAndDisarms {
  [self.policy armServiceIdentifier:self.serviceIdentifier];
  [[ACPreferences sharedPreferences] setAlwaysConnected:YES forServicesIdentifier:self.serviceIdentifier];

  [self.policy requestCancelService:self.service];

  XCTAssertFalse([self isPersistedAutoConnect], @"cancel must turn auto-connect off");
  XCTAssertFalse([self.policy isArmedServiceIdentifier:self.serviceIdentifier], @"cancel must disarm");
}

- (void)testConnectRequestArmsButDoesNotCommitYet {
  [self.policy requestConnectService:self.service];

  XCTAssertTrue([self.policy isArmedServiceIdentifier:self.serviceIdentifier], @"connect request must arm the service");
  XCTAssertFalse([self isPersistedAutoConnect], @"connect request alone must not enable auto-connect before Connected");
}

- (void)testCleanDisconnectOfAlwaysConnectServiceDisablesAutoConnect {
  [[ACPreferences sharedPreferences] setAlwaysConnected:YES forServicesIdentifier:self.serviceIdentifier];
  XCTAssertTrue([self isPersistedAutoConnect]);

  [self.policy handleAlwaysConnectState:kSCNetworkConnectionDisconnected wasClean:YES forService:self.service];

  XCTAssertFalse([self isPersistedAutoConnect], @"a clean (user-initiated) disconnect must turn auto-connect off");
}

- (void)testInvoluntaryDisconnectOfAlwaysConnectServiceKeepsAutoConnect {
  [[ACPreferences sharedPreferences] setAlwaysConnected:YES forServicesIdentifier:self.serviceIdentifier];
  XCTAssertTrue([self isPersistedAutoConnect]);

  [self.policy handleAlwaysConnectState:kSCNetworkConnectionDisconnected wasClean:NO forService:self.service];

  XCTAssertTrue([self isPersistedAutoConnect], @"an involuntary drop must leave auto-connect on so it reconnects");
}

- (void)testConnectedAlwaysConnectServiceLeavesAutoConnectOn {
  [[ACPreferences sharedPreferences] setAlwaysConnected:YES forServicesIdentifier:self.serviceIdentifier];
  XCTAssertTrue([self isPersistedAutoConnect]);

  [self.policy handleAlwaysConnectState:kSCNetworkConnectionConnected wasClean:NO forService:self.service];

  XCTAssertTrue([self isPersistedAutoConnect], @"a Connected transition must not disable auto-connect");
}

@end
