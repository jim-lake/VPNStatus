//
//  ACMenuReconcilerTests.m
//  VPNAppTests
//
//  Behavior-focused tests for the in-place menu reconciler. These deliberately
//  assert *properties* of reconciliation (identity/reuse, ordering, removal,
//  in-place updates) rather than exact cosmetic strings, so they don't need to
//  change every time a title or layout detail changes.
//

#import <XCTest/XCTest.h>
#import "ACMenuReconciler.h"

static NSString *const kBegin = @"test.begin";
static NSString *const kEnd = @"test.end";

@interface ACMenuReconcilerTests : XCTestCase
@property (strong) ACMenuReconciler *reconciler;
@end

@implementation ACMenuReconcilerTests

- (void)setUp {
  [super setUp];
  self.reconciler = [[ACMenuReconciler alloc] initWithActionTarget:self];
}

#pragma mark - Helpers

// Builds a menu with just the two anchors and (optionally) an unrelated trailing
// item so we can confirm the reconciler never touches things outside its region.
- (NSMenu *)menuWithAnchorsAndTrailer:(BOOL)withTrailer {
  NSMenu *menu = [[NSMenu alloc] init];

  NSMenuItem *begin = [NSMenuItem separatorItem];
  begin.identifier = kBegin;
  [menu addItem:begin];

  NSMenuItem *end = [NSMenuItem separatorItem];
  end.identifier = kEnd;
  [menu addItem:end];

  if(withTrailer) {
    NSMenuItem *trailer = [[NSMenuItem alloc] initWithTitle:@"Quit" action:nil keyEquivalent:@""];
    trailer.identifier = @"static.quit";
    [menu addItem:trailer];
  }

  return menu;
}

- (ACMenuRowDescriptor *)rowWithKey:(NSString *)key title:(NSString *)title {
  return [ACMenuRowDescriptor descriptorWithKey:key
                                          title:title
                                         action:@selector(dummyAction:)
                                          state:NSControlStateValueOff
                                        enabled:YES
                              representedObject:key];
}

- (void)reconcile:(NSMenu *)menu with:(NSArray<ACMenuRowDescriptor *> *)rows {
  [self.reconciler reconcileMenu:menu
           beginAnchorIdentifier:kBegin
             endAnchorIdentifier:kEnd
                     descriptors:rows];
}

// Returns the item identifiers that live strictly between the two anchors.
- (NSArray<NSString *> *)regionKeysOfMenu:(NSMenu *)menu {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  BOOL inRegion = NO;
  for(NSInteger i = 0; i < menu.numberOfItems; i++) {
    NSString *identifier = [menu itemAtIndex:i].identifier;
    if([identifier isEqualToString:kBegin]) {
      inRegion = YES;
      continue;
    }
    if([identifier isEqualToString:kEnd]) {
      break;
    }
    if(inRegion) {
      [keys addObject:(identifier ?: @"")];
    }
  }
  return keys;
}

- (NSMenuItem *)itemWithKey:(NSString *)key inMenu:(NSMenu *)menu {
  for(NSInteger i = 0; i < menu.numberOfItems; i++) {
    if([[menu itemAtIndex:i].identifier isEqualToString:key]) {
      return [menu itemAtIndex:i];
    }
  }
  return nil;
}

- (void)dummyAction:(id)sender {
}

#pragma mark - Tests

// A run on an empty region should produce exactly the desired rows, in order.
- (void)testInitialPopulationProducesRowsInOrder {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"],
                     [self rowWithKey:@"c"
                                title:@"C"] ]];

  XCTAssertEqualObjects([self regionKeysOfMenu:menu], (@[ @"a", @"b", @"c" ]));
}

// The core promise: reconciling again with the same set must reuse the *same*
// NSMenuItem instances (no wholesale rebuild).
- (void)testUnchangedReconciliationReusesSameItemInstances {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  NSArray *rows = @[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"] ];
  [self reconcile:menu with:rows];

  NSMenuItem *aBefore = [self itemWithKey:@"a" inMenu:menu];
  NSMenuItem *bBefore = [self itemWithKey:@"b" inMenu:menu];

  [self reconcile:menu with:rows];

  XCTAssertTrue([self itemWithKey:@"a" inMenu:menu] == aBefore, @"item 'a' should be reused, not recreated");
  XCTAssertTrue([self itemWithKey:@"b" inMenu:menu] == bBefore, @"item 'b' should be reused, not recreated");
}

// Removing a service removes only its row; survivors keep their instances.
- (void)testRemovedRowIsDroppedAndSurvivorsReused {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"],
                     [self rowWithKey:@"c"
                                title:@"C"] ]];

  NSMenuItem *aBefore = [self itemWithKey:@"a" inMenu:menu];
  NSMenuItem *cBefore = [self itemWithKey:@"c" inMenu:menu];

  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"c"
                                title:@"C"] ]];

  XCTAssertEqualObjects([self regionKeysOfMenu:menu], (@[ @"a", @"c" ]));
  XCTAssertNil([self itemWithKey:@"b" inMenu:menu]);
  XCTAssertTrue([self itemWithKey:@"a" inMenu:menu] == aBefore);
  XCTAssertTrue([self itemWithKey:@"c" inMenu:menu] == cBefore);
}

// Adding a service inserts a new row while keeping existing instances.
- (void)testAddedRowIsInsertedAndExistingReused {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  [self reconcile:menu with:@[ [self rowWithKey:@"a" title:@"A"] ]];
  NSMenuItem *aBefore = [self itemWithKey:@"a" inMenu:menu];

  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"] ]];

  XCTAssertEqualObjects([self regionKeysOfMenu:menu], (@[ @"a", @"b" ]));
  XCTAssertTrue([self itemWithKey:@"a" inMenu:menu] == aBefore);
}

// Reordering the desired list reorders items but reuses the same instances.
- (void)testReorderReusesInstances {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"],
                     [self rowWithKey:@"c"
                                title:@"C"] ]];

  NSMenuItem *aBefore = [self itemWithKey:@"a" inMenu:menu];
  NSMenuItem *bBefore = [self itemWithKey:@"b" inMenu:menu];
  NSMenuItem *cBefore = [self itemWithKey:@"c" inMenu:menu];

  [self reconcile:menu
             with:@[ [self rowWithKey:@"c" title:@"C"],
                     [self rowWithKey:@"a"
                                title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"] ]];

  XCTAssertEqualObjects([self regionKeysOfMenu:menu], (@[ @"c", @"a", @"b" ]));
  XCTAssertTrue([self itemWithKey:@"a" inMenu:menu] == aBefore);
  XCTAssertTrue([self itemWithKey:@"b" inMenu:menu] == bBefore);
  XCTAssertTrue([self itemWithKey:@"c" inMenu:menu] == cBefore);
}

// A changed presentation (title/state) updates the *same* item in place.
- (void)testChangedPresentationUpdatesInPlace {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  [self reconcile:menu with:@[ [self rowWithKey:@"a" title:@"Connect A"] ]];
  NSMenuItem *aBefore = [self itemWithKey:@"a" inMenu:menu];

  ACMenuRowDescriptor *changed = [ACMenuRowDescriptor descriptorWithKey:@"a"
                                                                  title:@"Disconnect A"
                                                                 action:@selector(dummyAction:)
                                                                  state:NSControlStateValueOn
                                                                enabled:YES
                                                      representedObject:@"a"];
  [self reconcile:menu with:@[ changed ]];

  NSMenuItem *aAfter = [self itemWithKey:@"a" inMenu:menu];
  XCTAssertTrue(aAfter == aBefore, @"presentation change must not recreate the item");
  XCTAssertEqualObjects(aAfter.title, @"Disconnect A");
  XCTAssertEqual(aAfter.state, NSControlStateValueOn);
}

// The reconciler must never disturb items outside its anchor region.
- (void)testItemsOutsideRegionAreUntouched {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:YES];
  NSMenuItem *trailerBefore = [self itemWithKey:@"static.quit" inMenu:menu];

  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"] ]];

  NSMenuItem *trailerAfter = [self itemWithKey:@"static.quit" inMenu:menu];
  XCTAssertTrue(trailerAfter == trailerBefore, @"static trailing item should be untouched");
  // And it should still be the last item.
  XCTAssertEqualObjects([menu itemAtIndex:menu.numberOfItems - 1].identifier, @"static.quit");
}

// Reconciling down to an empty list clears the region but keeps the anchors.
- (void)testReconcileToEmptyClearsRegionButKeepsAnchors {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:YES];
  [self reconcile:menu
             with:@[ [self rowWithKey:@"a" title:@"A"],
                     [self rowWithKey:@"b"
                                title:@"B"] ]];

  [self reconcile:menu with:@[]];

  XCTAssertEqualObjects([self regionKeysOfMenu:menu], @[]);
  XCTAssertNotNil([self itemWithKey:kBegin inMenu:menu]);
  XCTAssertNotNil([self itemWithKey:kEnd inMenu:menu]);
  XCTAssertNotNil([self itemWithKey:@"static.quit" inMenu:menu]);
}

// A missing begin anchor should be handled safely (no crash, no change).
- (void)testMissingAnchorIsSafe {
  NSMenu *menu = [[NSMenu alloc] init];
  [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Unrelated" action:nil keyEquivalent:@""]];

  XCTAssertNoThrow([self reconcile:menu with:@[ [self rowWithKey:@"a" title:@"A"] ]]);
  XCTAssertEqual(menu.numberOfItems, 1);
}

// Separator descriptors produce separator items and are reused in place across
// reconciliations like any other keyed row.
- (void)testSeparatorRowsAreCreatedAndReused {
  NSMenu *menu = [self menuWithAnchorsAndTrailer:NO];
  NSArray *rows = @[ [self rowWithKey:@"a" title:@"A"],
                     [ACMenuRowDescriptor separatorDescriptorWithKey:@"sep"] ];
  [self reconcile:menu with:rows];

  NSMenuItem *sep = [self itemWithKey:@"sep" inMenu:menu];
  XCTAssertNotNil(sep);
  XCTAssertTrue(sep.isSeparatorItem, @"separator descriptor should yield a separator item");
  XCTAssertEqualObjects([self regionKeysOfMenu:menu], (@[ @"a", @"sep" ]));

  [self reconcile:menu with:rows];
  XCTAssertTrue([self itemWithKey:@"sep" inMenu:menu] == sep, @"separator should be reused, not recreated");
}

@end
