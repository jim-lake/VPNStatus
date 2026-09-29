//
//  ACConnectionManagerBackoffTests.m
//  VPNStatusTests
//

#import <XCTest/XCTest.h>

#import "ACConnectionManager.h"
#import "ACPreferences.h"

@interface ACConnectionManagerBackoffTests : XCTestCase
@property (strong) ACConnectionManager *manager;
@property (assign) NSInteger savedMin;
@property (assign) NSInteger savedMax;
@end

@implementation ACConnectionManagerBackoffTests

- (void)setUp {
  [super setUp];
  // Fresh instance so tests don't share backoff state with the singleton.
  self.manager = [[ACConnectionManager alloc] init];

  // Preserve and later restore the real preferences we mutate.
  self.savedMin = [[ACPreferences sharedPreferences] minReconnect];
  self.savedMax = [[ACPreferences sharedPreferences] maxReconnect];
}

- (void)tearDown {
  [[ACPreferences sharedPreferences] setMinReconnect:self.savedMin];
  [[ACPreferences sharedPreferences] setMaxReconnect:self.savedMax];
  self.manager = nil;
  [super tearDown];
}

// Runs advanceDelay: from 0 for `count` steps and returns the sequence, where
// element 0 is the starting delay (0) and each subsequent element is the next
// scheduled delay.
- (NSArray<NSNumber *> *)sequenceOfLength:(NSUInteger)count {
  NSMutableArray<NSNumber *> *seq = [NSMutableArray array];
  NSInteger delay = 0;
  [seq addObject:@(delay)];
  for(NSUInteger i = 1; i < count; i++) {
    delay = [self.manager advanceDelay:delay];
    [seq addObject:@(delay)];
  }
  return seq;
}

#pragma mark - advanceDelay: sequence

// Default bounds (min=0, max=60): 0, 1, 2, 4, 8, 16, 32, 60, 60, ...
// (a single immediate attempt, then doubling with a floor of 1, capped at max).
- (void)testDefaultSequence {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:60];

  NSArray<NSNumber *> *expected = @[ @0, @1, @2, @4, @8, @16, @32, @60, @60, @60 ];
  XCTAssertEqualObjects([self sequenceOfLength:expected.count], expected);
}

// Non-zero min (min=5, max=60): 0, 5, 10, 20, 40, 60, 60, ...
- (void)testNonZeroMinSequence {
  [[ACPreferences sharedPreferences] setMinReconnect:5];
  [[ACPreferences sharedPreferences] setMaxReconnect:60];

  NSArray<NSNumber *> *expected = @[ @0, @5, @10, @20, @40, @60, @60 ];
  XCTAssertEqualObjects([self sequenceOfLength:expected.count], expected);
}

// With min=0 the sequence must not stall at 0: the floor of 1 guarantees growth
// even though doubling 0 would stay 0.
- (void)testFloorOfOneGuaranteesGrowthFromZero {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:60];

  // 0 -> 1 (floor), then 1 -> 2.
  XCTAssertEqual([self.manager advanceDelay:0], 1);
  XCTAssertEqual([self.manager advanceDelay:[self.manager advanceDelay:0]], 2);
}

// max clamps every step; with a small max, growth saturates immediately.
- (void)testMaxClampsSequence {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:3];

  // 0 -> 1 -> 2 -> clamp(4,1,3)=3 -> 3 ...
  NSArray<NSNumber *> *expected = @[ @0, @1, @2, @3, @3, @3 ];
  XCTAssertEqualObjects([self sequenceOfLength:expected.count], expected);
}

// min is itself clamped to max: if a user sets min > max, the next delay never
// exceeds max.
- (void)testMinGreaterThanMaxIsClampedToMax {
  [[ACPreferences sharedPreferences] setMinReconnect:100];
  [[ACPreferences sharedPreferences] setMaxReconnect:10];

  // 0 -> min(100) clamped to max(10) -> clamp(20,1,10)=10 -> 10 ...
  XCTAssertEqual([self.manager advanceDelay:0], 10);
  XCTAssertEqual([self.manager advanceDelay:10], 10);
}

// max of 0 pins every delay to 0 (immediate retries only).
- (void)testMaxZeroPinsToZero {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:0];

  NSArray<NSNumber *> *expected = @[ @0, @0, @0, @0, @0 ];
  XCTAssertEqualObjects([self sequenceOfLength:expected.count], expected);
}

#pragma mark - backoff bookkeeping / reset

// A freshly-created backoff starts at nextDelay = 0.
- (void)testFreshBackoffStartsAtZero {
  NSString *identifier = @"svc-A";
  ACServiceBackoff *backoff = [self.manager backoffForServiceIdentifier:identifier];
  XCTAssertNotNil(backoff);
  XCTAssertEqual(backoff.nextDelay, 0);
  XCTAssertNil(backoff.retryTimer);
  XCTAssertNil(backoff.stabilityTimer);
}

// backoffForServiceIdentifier: returns the same instance for the same id.
- (void)testBackoffIsStablePerIdentifier {
  ACServiceBackoff *a1 = [self.manager backoffForServiceIdentifier:@"svc-A"];
  ACServiceBackoff *a2 = [self.manager backoffForServiceIdentifier:@"svc-A"];
  ACServiceBackoff *b = [self.manager backoffForServiceIdentifier:@"svc-B"];
  XCTAssertTrue(a1 == a2, @"same identifier should yield the same backoff instance");
  XCTAssertTrue(a1 != b, @"different identifiers should yield distinct backoff instances");
}

// Reset returns nextDelay to 0 and cancels any pending timers.
- (void)testResetReturnsToStartOfSequence {
  NSString *identifier = @"svc-A";
  ACServiceBackoff *backoff = [self.manager backoffForServiceIdentifier:identifier];
  backoff.nextDelay = 32;
  backoff.retryTimer = [NSTimer scheduledTimerWithTimeInterval:9999 repeats:NO block:^(NSTimer *t){}];
  backoff.stabilityTimer = [NSTimer scheduledTimerWithTimeInterval:9999 repeats:NO block:^(NSTimer *t){}];

  [self.manager resetBackoffForServiceIdentifier:identifier];

  XCTAssertEqual(backoff.nextDelay, 0, @"reset should return the delay to the start of the sequence");
  XCTAssertFalse(backoff.retryTimer.isValid, @"reset should invalidate the pending retry timer");
  XCTAssertFalse(backoff.stabilityTimer.isValid, @"reset should invalidate the stability timer");
}

// Resetting a service that has no backoff state is a safe no-op.
- (void)testResetUnknownIdentifierIsSafe {
  XCTAssertNoThrow([self.manager resetBackoffForServiceIdentifier:@"never-seen"]);
}

// Each service's backoff advances independently: touching one must not disturb
// another's nextDelay.
- (void)testPerServiceBackoffIsIndependent {
  [[ACPreferences sharedPreferences] setMinReconnect:0];
  [[ACPreferences sharedPreferences] setMaxReconnect:60];

  ACServiceBackoff *a = [self.manager backoffForServiceIdentifier:@"svc-A"];
  ACServiceBackoff *b = [self.manager backoffForServiceIdentifier:@"svc-B"];

  a.nextDelay = [self.manager advanceDelay:a.nextDelay]; // 0 -> 1
  a.nextDelay = [self.manager advanceDelay:a.nextDelay]; // 1 -> 2
  a.nextDelay = [self.manager advanceDelay:a.nextDelay]; // 2 -> 4

  XCTAssertEqual(a.nextDelay, 4);
  XCTAssertEqual(b.nextDelay, 0, @"advancing svc-A must not change svc-B's backoff");

  [self.manager resetBackoffForServiceIdentifier:@"svc-A"];
  XCTAssertEqual(a.nextDelay, 0);
  XCTAssertEqual(b.nextDelay, 0);
}

@end
