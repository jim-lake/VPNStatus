//
//  ACNEServicesManagerFilterTests.m
//  VPNStatusTests
//
//  Unit tests for ACNEServicesManager's configuration filtering
//  (-processConfigurations:). Verifies that non-VPN NEConfigurations — e.g.
//  Encrypted DNS (DoH/DoT) profiles, whose -VPN sub-object is nil — are dropped
//  by type, while real VPN configurations survive.
//

#import <XCTest/XCTest.h>

#import "ACDefines.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"
#import "ACNEServicesManager_Internal.h"

// Minimal stand-in for an NEConfiguration. -processConfigurations: only reads
// -name and -VPN (and -identifier for the VPN ones, when it builds the service),
// so the stub implements just those. A nil -VPN models a non-VPN configuration
// (Encrypted DNS profile, content filter); a non-nil -VPN models a real VPN.
@interface ACFakeConfiguration : NSObject
@property (copy) NSString *name;
@property (strong, nullable) NEVPN *VPN;
@property (strong) NSUUID *identifier;
@end

@implementation ACFakeConfiguration
- (instancetype)init {
  self = [super init];
  if(self) {
    _identifier = [NSUUID UUID];
  }
  return self;
}
@end

@interface ACNEServicesManagerFilterTests : XCTestCase
@property (strong) ACNEServicesManager *manager;
@end

@implementation ACNEServicesManagerFilterTests

- (void)setUp {
  [super setUp];
  self.manager = [[ACNEServicesManager alloc] init];
}

- (void)tearDown {
  self.manager = nil;
  [super tearDown];
}

- (ACFakeConfiguration *)vpnConfigNamed:(NSString *)inName {
  ACFakeConfiguration *config = [[ACFakeConfiguration alloc] init];
  config.name = inName;
  config.VPN = [[NEVPN alloc] init];
  return config;
}

- (ACFakeConfiguration *)nonVPNConfigNamed:(NSString *)inName {
  ACFakeConfiguration *config = [[ACFakeConfiguration alloc] init];
  config.name = inName;
  config.VPN = nil;
  return config;
}

- (NSArray<NSString *> *)serviceNames {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for(ACNEService *service in self.manager.neServices) {
    [names addObject:service.name];
  }
  return names;
}

// A non-VPN configuration (nil -VPN), like the Google Encrypted DNS profile, is
// dropped even though its name matches neither the ignored list nor the
// com.apple.preferences.* prefix.
- (void)testEncryptedDNSProfileIsFilteredOut {
  NSArray *configs = @[
    (id)[self nonVPNConfigNamed:@"Google Public DNS Encrypted DNS over HTTPS"],
    (id)[self vpnConfigNamed:@"ares-staging"],
  ];

  [self.manager processConfigurations:configs];

  NSArray<NSString *> *names = [self serviceNames];
  XCTAssertEqual(names.count, 1u);
  XCTAssertEqualObjects(names.firstObject, @"ares-staging");
  XCTAssertFalse([names containsObject:@"Google Public DNS Encrypted DNS over HTTPS"]);
}

// Real VPN configurations are kept and sorted by name.
- (void)testVPNConfigurationsAreKeptAndSorted {
  NSArray *configs = @[
    (id)[self vpnConfigNamed:@"zeta-vpn"],
    (id)[self vpnConfigNamed:@"alpha-vpn"],
  ];

  [self.manager processConfigurations:configs];

  NSArray<NSString *> *names = [self serviceNames];
  XCTAssertEqualObjects(names, (@[ @"alpha-vpn", @"zeta-vpn" ]));
}

// The pre-existing name-based filters still apply on top of the type filter.
- (void)testInternalPreferencesConfigurationIsFilteredOut {
  NSArray *configs = @[
    (id)[self vpnConfigNamed:@"com.apple.preferences.networkprivacy-abc"],
    (id)[self vpnConfigNamed:@"real-vpn"],
  ];

  [self.manager processConfigurations:configs];

  XCTAssertEqualObjects([self serviceNames], (@[ @"real-vpn" ]));
}

// A configuration that is both non-VPN and otherwise valid-named is still
// dropped purely on type.
- (void)testAllNonVPNConfigurationsProduceEmptyList {
  NSArray *configs = @[
    (id)[self nonVPNConfigNamed:@"Some Content Filter"],
    (id)[self nonVPNConfigNamed:@"Encrypted DNS"],
  ];

  [self.manager processConfigurations:configs];

  XCTAssertEqual(self.manager.neServices.count, 0u);
}

@end
