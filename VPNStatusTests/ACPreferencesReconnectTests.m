//
//  ACPreferencesReconnectTests.m
//  VPNStatusTests
//
//  Unit tests for the Min/Max Reconnect preferences that back the reconnect
//  backoff: their defaults (0 / 60) and their write-side clamping (>= 0).
//

#import <XCTest/XCTest.h>

#import "ACPreferences.h"

static NSString *const kMinReconnectPrefKey = @"MinReconnect";
static NSString *const kMaxReconnectPrefKey = @"MaxReconnect";

@interface ACPreferencesReconnectTests : XCTestCase
@property (assign) BOOL hadMin;
@property (assign) NSInteger savedMin;
@property (assign) BOOL hadMax;
@property (assign) NSInteger savedMax;
@end

@implementation ACPreferencesReconnectTests

- (void)setUp {
  [super setUp];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  self.hadMin = ([defaults objectForKey:kMinReconnectPrefKey] != nil);
  self.savedMin = [defaults integerForKey:kMinReconnectPrefKey];
  self.hadMax = ([defaults objectForKey:kMaxReconnectPrefKey] != nil);
  self.savedMax = [defaults integerForKey:kMaxReconnectPrefKey];

  // Start each test from the unset (default) state.
  [defaults removeObjectForKey:kMinReconnectPrefKey];
  [defaults removeObjectForKey:kMaxReconnectPrefKey];
}

- (void)tearDown {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if(self.hadMin) {
    [defaults setInteger:self.savedMin forKey:kMinReconnectPrefKey];
  } else {
    [defaults removeObjectForKey:kMinReconnectPrefKey];
  }
  if(self.hadMax) {
    [defaults setInteger:self.savedMax forKey:kMaxReconnectPrefKey];
  } else {
    [defaults removeObjectForKey:kMaxReconnectPrefKey];
  }
  [super tearDown];
}

// Unset -> documented defaults: min = 0, max = 60.
- (void)testDefaults {
  XCTAssertEqual([[ACPreferences sharedPreferences] minReconnect], 0);
  XCTAssertEqual([[ACPreferences sharedPreferences] maxReconnect], 60);
}

// Normal values round-trip unchanged.
- (void)testRoundTrip {
  [[ACPreferences sharedPreferences] setMinReconnect:5];
  [[ACPreferences sharedPreferences] setMaxReconnect:120];
  XCTAssertEqual([[ACPreferences sharedPreferences] minReconnect], 5);
  XCTAssertEqual([[ACPreferences sharedPreferences] maxReconnect], 120);
}

// Negative writes are clamped to 0 on the way in.
- (void)testNegativeWritesClampToZero {
  [[ACPreferences sharedPreferences] setMinReconnect:-10];
  [[ACPreferences sharedPreferences] setMaxReconnect:-1];
  XCTAssertEqual([[ACPreferences sharedPreferences] minReconnect], 0);
  XCTAssertEqual([[ACPreferences sharedPreferences] maxReconnect], 0);
}

// A negative value that somehow lands in defaults is still read back as 0.
- (void)testNegativeStoredValueReadsAsZero {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setInteger:-7 forKey:kMinReconnectPrefKey];
  [defaults setInteger:-7 forKey:kMaxReconnectPrefKey];
  XCTAssertEqual([[ACPreferences sharedPreferences] minReconnect], 0);
  XCTAssertEqual([[ACPreferences sharedPreferences] maxReconnect], 0);
}

// Zero is a legal explicit value (immediate retries only), distinct from unset.
- (void)testZeroIsLegal {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:0];
  XCTAssertEqual([[ACPreferences sharedPreferences] minReconnect], 0);
  XCTAssertEqual([[ACPreferences sharedPreferences] maxReconnect], 0);
}

@end
