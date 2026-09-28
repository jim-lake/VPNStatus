//
//  AppDelegate.m
//  VPNStatus
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//

#import "AppDelegate.h"

#import "ACDefines.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"
#import "ACPreferences.h"
#import "ACPreferencesWindowController.h"
#import "ACConnectionManager.h"
#import "ACMenuReconciler.h"

#import "VPNStatus-Swift.h"

@interface AppDelegate () <NSMenuDelegate>

@property (strong) NSStatusItem *statusItem;
@property (strong) ACMenuReconciler *menuReconciler;

@end

@implementation AppDelegate

- (void)reloadConfigurations {
  [self reloadConfigurationsAndApplyAutoConnect:YES];
}

- (void)reloadConfigurationsAndApplyAutoConnect:(BOOL)applyAutoConnect {
  // Make sure that the ACNEServicesManager singleton is created and load the configurations
  [[ACNEServicesManager sharedNEServicesManager] loadConfigurationsWithHandler:^(NSError *error) {
    if(error != nil) {
      NSLog(@"Failed to load the configurations - %@", error);
    }

    if(applyAutoConnect) {
      // Connect all services that are marked as always auto connect
      [[ACConnectionManager sharedManager] connectAllAutoConnectedServices];
    }

    // Refresh the menu
    [self refreshMenu];
  }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
  // Create the ACConnectionManager singleton
  [ACConnectionManager sharedManager];

  // Create the NSStatusItem
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

  // Accessibility identifier so UI tests can locate and click the status item.
  self.statusItem.button.accessibilityIdentifier = @"VPNStatusItem";
  self.statusItem.button.accessibilityLabel = @"VPNStatus";

  // Build the persistent menu skeleton once. It is updated in place from now
  // on (see refreshMenu / reconcile*), never rebuilt.
  self.statusItem.menu = [self buildInitialMenu];

  [self updateStatusItemIcon];

  // Refresh the menu
  [self refreshMenu];

  // Register for notifications to refresh the UI
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMenu) name:kSessionStateChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadConfigurations) name:kACConfigurationDidChange object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMenu) name:kACMenuBarImageDidChange object:nil];

  // Make sure that the ACNEServicesManager singleton is created and load the configurations
  [self reloadConfigurations];

  if(![[ACPreferences sharedPreferences] disabledCheckForUpdatesAutomatically]) {
    [[UpdateManager shared] checkForUpdateWithShowUpToDateAlert:NO];
  }

  // UI-test automation hook. Only installed when the app is launched with the
  // UITEST_AUTOMATION environment variable set (see VPNStatusUITests). A
  // popped-up NSStatusItem menu cannot be geometrically clicked by XCUITest
  // (its rows are non-hittable and XCUITest's click hangs on a menu-open wait),
  // so under automation we let the test ask us to activate a menu row by its
  // stable identifier. This drives the *real* NSMenuItem target/action exactly
  // as a user click would (e.g. connectService:/disconnectService:/doQuit:).
  [self installUITestAutomationHookIfNeeded];
}

#pragma mark - UI test automation hook (no-op unless UITEST_AUTOMATION is set)

static NSString *const kUITestActivateRequest = @"org.timac.VPNStatus.uitest.activate"; // object = row identifier

- (void)installUITestAutomationHookIfNeeded {
  if([[[NSProcessInfo processInfo] environment][@"UITEST_AUTOMATION"] boolValue] == NO) {
    return;
  }

  // Use the distributed center so the (separate) UI-test process can signal us.
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(uiTestActivateRow:)
                                                          name:kUITestActivateRequest
                                                        object:nil];
}

- (void)uiTestActivateRow:(NSNotification *)inNotification {
  NSString *identifier = inNotification.object;
  if(![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
    return;
  }

  NSMenu *menu = self.statusItem.menu;
  NSInteger index = -1;
  for(NSInteger i = 0; i < menu.numberOfItems; i++) {
    if([[menu itemAtIndex:i].identifier isEqualToString:identifier]) {
      index = i;
      break;
    }
  }
  if(index >= 0) {
    // Fire the item's action through its real target, exactly like a click.
    [menu performActionForItemAtIndex:index];
  }
}

- (void)updateStatusItemIcon {
  NSButton *statusItemButton = [self.statusItem button];
  if(statusItemButton != nil) {
    BOOL oneServiceConnected = NO;
    NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
    for(ACNEService *service in neServices) {
      if([service state] == kSCNetworkConnectionConnected) {
        oneServiceConnected = YES;
        break;
      }
    }

    MenuBarImageState state = oneServiceConnected ? MenuBarImageState_On : MenuBarImageState_Off;
    [statusItemButton setImage:[ACPreferences menuBarImageForState:state]];
  }
}

//
// The menu is built once and then updated in place ("reconciled") on every
// refresh. We never rebuild the whole NSMenu or reassign statusItem.menu,
// because doing so while the menu is open is intrusive: it resets the
// highlighted item, can flicker, and fights the user's cursor. Instead each
// refresh mutates only the items whose content actually changed and
// inserts/removes items only when the set of VPN services changes.
//
// To locate items across refreshes we tag them with stable identifiers
// (NSMenuItem.identifier). Per-service items additionally carry the service's
// configuration UUID in representedObject so that actions resolve the correct
// service regardless of its current position in the list.
//

// Section anchor identifiers. Each dynamic region lives between its "begin"
// marker (an item stored via identifier) and the next region.
//
// Layout (top to bottom):
//   disconnect-all region  → "Disconnect All (…)" + separator
//   services region        → one Connect/Disconnect row per VPN (checked when connected)
//   static region          → Settings / Quit (built once)
static NSString *const kMenuIDDisconnectAllSectionBegin = @"disconnectall.begin";
static NSString *const kMenuIDServicesSectionBegin = @"services.begin";
static NSString *const kMenuIDStaticSectionBegin = @"static.begin";

// Per-item identifier prefixes.
static NSString *const kMenuIDServiceActionPrefix = @"service.action."; // + UUID

// Stable identifiers for the static bottom items (used by UI tests).
static NSString *const kMenuIDSettingsItem = @"static.settings";
static NSString *const kMenuIDQuitItem = @"static.quit";

- (NSString *)uuidForService:(ACNEService *)inService {
  return [inService.configuration.identifier UUIDString];
}

- (ACMenuReconciler *)menuReconciler {
  if(_menuReconciler == nil) {
    _menuReconciler = [[ACMenuReconciler alloc] initWithActionTarget:self];
  }
  return _menuReconciler;
}

//
// Builds the fixed skeleton of the menu once: the static Settings/Quit items
// at the bottom and the invisible section-anchor items. All dynamic content is
// inserted/removed relative to these anchors during reconciliation.
//
- (NSMenu *)buildInitialMenu {
  NSMenu *menu = [[NSMenu alloc] init];
  menu.autoenablesItems = NO;
  menu.delegate = self;

  // Section anchors are zero-height separator items that we keep hidden. They
  // give each dynamic region a stable insertion point.
  NSMenuItem * (^makeAnchor)(NSString *) = ^NSMenuItem *(NSString *identifier) {
    NSMenuItem *anchor = [NSMenuItem separatorItem];
    anchor.identifier = identifier;
    anchor.hidden = YES;
    return anchor;
  };

  [menu addItem:makeAnchor(kMenuIDDisconnectAllSectionBegin)];
  [menu addItem:makeAnchor(kMenuIDServicesSectionBegin)];
  [menu addItem:makeAnchor(kMenuIDStaticSectionBegin)];

  // Static bottom section — built once, never touched again.
  // Stable identifiers are set so UI tests can locate these items reliably
  // (without them, AppKit derives the accessibility identifier from the action
  // selector, e.g. "openSettings:" / "doQuit:", which is an implementation
  // detail tests should not depend on).
  NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:@selector(openSettings:) keyEquivalent:@","];
  settingsItem.identifier = kMenuIDSettingsItem;
  [menu addItem:settingsItem];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit VPNStatus" action:@selector(doQuit:) keyEquivalent:@"q"];
  quitItem.identifier = kMenuIDQuitItem;
  [menu addItem:quitItem];

  return menu;
}

// Returns the index just after the anchor identified by inIdentifier.
- (NSInteger)indexAfterAnchor:(NSString *)inIdentifier inMenu:(NSMenu *)inMenu {
  NSInteger anchorIndex = -1;
  for(NSInteger i = 0; i < inMenu.numberOfItems; i++) {
    if([[inMenu itemAtIndex:i].identifier isEqualToString:inIdentifier]) {
      anchorIndex = i;
      break;
    }
  }
  return anchorIndex + 1;
}

// Removes every item strictly between the two anchors, leaving the anchors in
// place. Returns the index at which new content for that section should start.
- (NSInteger)clearSectionFromAnchor:(NSString *)inBeginAnchor toAnchor:(NSString *)inEndAnchor inMenu:(NSMenu *)inMenu {
  NSInteger start = [self indexAfterAnchor:inBeginAnchor inMenu:inMenu];
  while(start < inMenu.numberOfItems) {
    NSMenuItem *item = [inMenu itemAtIndex:start];
    if([item.identifier isEqualToString:inEndAnchor]) {
      break;
    }
    [inMenu removeItemAtIndex:start];
  }
  return start;
}

//
// Sets a value on the menu item only if it differs, so that we never poke the
// UI when nothing changed.
//
- (void)updateItem:(NSMenuItem *)inItem title:(NSString *)inTitle action:(SEL)inAction state:(NSControlStateValue)inState enabled:(BOOL)inEnabled {
  if(![inItem.title isEqualToString:inTitle]) {
    inItem.title = inTitle;
  }
  if(inItem.action != inAction) {
    inItem.action = inAction;
    inItem.target = inAction ? self : nil;
  }
  if(inItem.state != inState) {
    inItem.state = inState;
  }
  if(inItem.enabled != inEnabled) {
    inItem.enabled = inEnabled;
  }
}

// Public entry point kept under the old name so existing callers/observers are
// unchanged. Delegates to the in-place reconciler.
- (void)refreshMenu {
  if(self.statusItem.menu == nil) {
    self.statusItem.menu = [self buildInitialMenu];
  }

  [self reconcileDisconnectAllSection];
  [self reconcileServiceSections];

  [self updateStatusItemIcon];
}

#pragma mark - Menu reconciliation

// Returns the services that are currently connected (kSCNetworkConnectionConnected).
- (NSArray<ACNEService *> *)connectedServices {
  NSMutableArray<ACNEService *> *connected = [NSMutableArray array];
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    if([neService state] == kSCNetworkConnectionConnected) {
      [connected addObject:neService];
    }
  }
  return connected;
}

//
// Reconciles the "Disconnect All" row that sits at the very top of the menu,
// followed by a separator. The row's title reflects the number of connected
// VPNs:
//   0 connected  → "Disconnect All"                    (disabled)
//   1 connected  → "Disconnect All (<vpn-name>)"       (enabled)
//   N connected  → "Disconnect All (N connections)"    (enabled)
//
static NSString *const kMenuIDDisconnectAllItem = @"disconnectall.item";

- (void)reconcileDisconnectAllSection {
  NSMenu *menu = self.statusItem.menu;

  NSArray<ACNEService *> *connected = [self connectedServices];
  NSUInteger count = [connected count];

  NSString *title = nil;
  if(count == 0) {
    title = @"Disconnect All";
  } else if(count == 1) {
    title = [NSString stringWithFormat:@"Disconnect All (%@)", [connected.firstObject name] ?: @""];
  } else {
    title = [NSString stringWithFormat:@"Disconnect All (%lu connections)", (unsigned long)count];
  }

  BOOL enabled = (count > 0);

  NSInteger cursor = [self indexAfterAnchor:kMenuIDDisconnectAllSectionBegin inMenu:menu];

  // The "Disconnect All" row itself.
  NSString *capturedTitle = title;
  BOOL capturedEnabled = enabled;
  cursor = [self ensureItemAtCursor:cursor
    identifier:kMenuIDDisconnectAllItem
    menu:menu
    untilAnchor:kMenuIDServicesSectionBegin
    makeItem:^NSMenuItem * {
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:capturedTitle action:@selector(disconnectAll:) keyEquivalent:@""];
      item.identifier = kMenuIDDisconnectAllItem;
      item.target = self;
      item.enabled = capturedEnabled;
      return item;
    }
    configure:^(NSMenuItem *item) {
      if(![item.title isEqualToString:capturedTitle]) {
        item.title = capturedTitle;
      }
      if(item.enabled != capturedEnabled) {
        item.enabled = capturedEnabled;
      }
    }];

  // Trailing separator.
  cursor = [self ensureItemAtCursor:cursor
                         identifier:@"disconnectall.sep"
                               menu:menu
                        untilAnchor:kMenuIDServicesSectionBegin
                           makeItem:^NSMenuItem * {
                             NSMenuItem *sep = [NSMenuItem separatorItem];
                             sep.identifier = @"disconnectall.sep";
                             return sep;
                           }
                          configure:nil];

  // Remove anything stale in this region.
  [self removeItemsFromIndex:cursor untilAnchor:kMenuIDServicesSectionBegin inMenu:menu];
}

- (NSString *)titleForServiceActionState:(SCNetworkConnectionStatus)inState name:(NSString *)inName {
  switch(inState) {
  case kSCNetworkConnectionDisconnected:
    return [NSString stringWithFormat:@"Connect %@", inName];
  case kSCNetworkConnectionConnected:
    return [NSString stringWithFormat:@"Disconnect %@", inName];
  case kSCNetworkConnectionConnecting:
    return [NSString stringWithFormat:@"Connecting %@...", inName];
  case kSCNetworkConnectionDisconnecting:
    return [NSString stringWithFormat:@"Disconnecting %@...", inName];
  case kSCNetworkConnectionInvalid:
  default:
    return [NSString stringWithFormat:@"%@ is invalid", inName];
  }
}

- (SEL)actionForServiceActionState:(SCNetworkConnectionStatus)inState {
  switch(inState) {
  case kSCNetworkConnectionDisconnected:
    return @selector(connectService:);
  case kSCNetworkConnectionConnected:
    return @selector(disconnectService:);
  default:
    return nil; // transitional / invalid: not actionable
  }
}

//
// Reconciles the per-service "action" region (Connect/Disconnect rows). Items
// are matched to services by UUID via their identifier, so surviving services
// keep their existing NSMenuItem instances and only added/removed services
// cause insertions/removals. A connected service's row shows a checkmark.
//
- (void)reconcileServiceSections {
  NSMenu *menu = self.statusItem.menu;
  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];

  NSInteger insertIndex = [self indexAfterAnchor:kMenuIDServicesSectionBegin inMenu:menu];

  if([neServices count] == 0) {
    // Show a single placeholder row; reconcile it in place.
    NSInteger sectionEnd = [self indexOfAnchor:kMenuIDStaticSectionBegin inMenu:menu];
    NSMenuItem *existing = (insertIndex < sectionEnd) ? [menu itemAtIndex:insertIndex] : nil;
    if(existing != nil && [existing.identifier isEqualToString:@"service.none"]) {
      // Already correct — remove any extra rows beyond it.
      [self removeItemsFromIndex:insertIndex + 1 untilAnchor:kMenuIDStaticSectionBegin inMenu:menu];
    } else {
      [self clearSectionFromAnchor:kMenuIDServicesSectionBegin toAnchor:kMenuIDStaticSectionBegin inMenu:menu];
      NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No VPN available" action:nil keyEquivalent:@""];
      none.identifier = @"service.none";
      none.enabled = NO;
      [menu insertItem:none atIndex:insertIndex++];
      [menu insertItem:[NSMenuItem separatorItem] atIndex:insertIndex++];
    }
  } else {
    [self reconcileActionItemsForServices:neServices insertIndex:insertIndex menu:menu];
  }
}

- (NSInteger)indexOfAnchor:(NSString *)inIdentifier inMenu:(NSMenu *)inMenu {
  for(NSInteger i = 0; i < inMenu.numberOfItems; i++) {
    if([[inMenu itemAtIndex:i].identifier isEqualToString:inIdentifier]) {
      return i;
    }
  }
  return inMenu.numberOfItems;
}

- (void)removeItemsFromIndex:(NSInteger)inStart untilAnchor:(NSString *)inEndAnchor inMenu:(NSMenu *)inMenu {
  while(inStart < inMenu.numberOfItems) {
    NSMenuItem *item = [inMenu itemAtIndex:inStart];
    if([item.identifier isEqualToString:inEndAnchor]) {
      break;
    }
    [inMenu removeItemAtIndex:inStart];
  }
}

//
// Reconciles the Connect/Disconnect rows. One row per service, ordered to match
// neServices, followed by a trailing separator. A connected service's row shows
// a checkmark (NSControlStateValueOn). Delegates the actual diffing to
// ACMenuReconciler (which is exercised directly by ACMenuReconcilerTests), so
// the tested code path is the one that actually runs here.
//
- (void)reconcileActionItemsForServices:(NSArray<ACNEService *> *)inServices insertIndex:(NSInteger)inInsertIndex menu:(NSMenu *)inMenu {
  NSMutableArray<ACMenuRowDescriptor *> *descriptors = [NSMutableArray array];

  for(ACNEService *neService in inServices) {
    NSString *uuid = [self uuidForService:neService];
    NSString *identifier = [kMenuIDServiceActionPrefix stringByAppendingString:uuid];

    SCNetworkConnectionStatus state = [neService state];
    NSString *title = [self titleForServiceActionState:state name:neService.name];
    SEL action = [self actionForServiceActionState:state];
    BOOL enabled = (action != nil);

    // Checkmark when the service is connected.
    NSControlStateValue checkState = (state == kSCNetworkConnectionConnected) ? NSControlStateValueOn : NSControlStateValueOff;

    [descriptors addObject:[ACMenuRowDescriptor descriptorWithKey:identifier
                                                            title:title
                                                           action:action
                                                            state:checkState
                                                          enabled:enabled
                                                representedObject:uuid]];
  }

  [descriptors addObject:[ACMenuRowDescriptor separatorDescriptorWithKey:@"service.action.sep"]];

  [self.menuReconciler reconcileMenu:inMenu
               beginAnchorIdentifier:kMenuIDServicesSectionBegin
                 endAnchorIdentifier:kMenuIDStaticSectionBegin
                         descriptors:descriptors];
}

//
// Ensures the item with inIdentifier sits at inCursor. If it's already there,
// applies the optional configure block and advances. If it exists later in the
// region (reorder), moves it. Otherwise inserts a freshly-made item. Returns the
// next cursor position.
//
- (NSInteger)ensureItemAtCursor:(NSInteger)inCursor
                     identifier:(NSString *)inIdentifier
                           menu:(NSMenu *)inMenu
                    untilAnchor:(NSString *)inEndAnchor
                       makeItem:(NSMenuItem * (^)(void))inMakeItem
                      configure:(void (^)(NSMenuItem *item))inConfigure {
  NSMenuItem *itemAtCursor = (inCursor < inMenu.numberOfItems) ? [inMenu itemAtIndex:inCursor] : nil;
  if(itemAtCursor != nil && [itemAtCursor.identifier isEqualToString:inIdentifier]) {
    if(inConfigure) {
      inConfigure(itemAtCursor);
    }
    return inCursor + 1;
  }

  NSInteger existingIndex = [self indexOfItemWithIdentifier:inIdentifier inMenu:inMenu fromIndex:inCursor untilAnchor:inEndAnchor];
  if(existingIndex != NSNotFound) {
    NSMenuItem *existing = [inMenu itemAtIndex:existingIndex];
    [inMenu removeItemAtIndex:existingIndex];
    [inMenu insertItem:existing atIndex:inCursor];
    if(inConfigure) {
      inConfigure(existing);
    }
    return inCursor + 1;
  }

  NSMenuItem *item = inMakeItem();
  [inMenu insertItem:item atIndex:inCursor];
  return inCursor + 1;
}

- (NSInteger)indexOfItemWithIdentifier:(NSString *)inIdentifier inMenu:(NSMenu *)inMenu fromIndex:(NSInteger)inFrom untilAnchor:(NSString *)inEndAnchor {
  for(NSInteger i = inFrom; i < inMenu.numberOfItems; i++) {
    NSMenuItem *item = [inMenu itemAtIndex:i];
    if([item.identifier isEqualToString:inEndAnchor]) {
      break;
    }
    if(item.identifier != nil && [item.identifier isEqualToString:inIdentifier]) {
      return i;
    }
  }
  return NSNotFound;
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
  // The user just opened the menu. Kick off an asynchronous reload of the VPN
  // configurations so that VPNs added or removed from the system UI are picked
  // up. This does not block the menu from opening: it shows the last known
  // list immediately, and the reload rebuilds the menu in place once it
  // completes (if anything changed).
  //
  // We deliberately do not re-apply the auto-connect policy here: merely
  // opening the menu should not reconnect user-disconnected VPNs.
  [self reloadConfigurationsAndApplyAutoConnect:NO];
}

- (ACNEService *)serviceForMenuItem:(id)sender {
  if(![sender isKindOfClass:[NSMenuItem class]]) {
    return nil;
  }

  NSString *uuid = [(NSMenuItem *)sender representedObject];
  if(![uuid isKindOfClass:[NSString class]] || [uuid length] == 0) {
    return nil;
  }

  NSArray<ACNEService *> *neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
  for(ACNEService *neService in neServices) {
    if([[self uuidForService:neService] isEqualToString:uuid]) {
      return neService;
    }
  }

  return nil;
}

- (IBAction)connectService:(id)sender {
  ACNEService *neService = [self serviceForMenuItem:sender];
  if(neService == nil) {
    return;
  }

  // Manually connecting through the app enables auto connect for this service.
  [[ACConnectionManager sharedManager] setAlwaysAutoConnect:YES forACNEService:neService];

  [neService connect];

  [self refreshMenu];
}

- (IBAction)disconnectService:(id)sender {
  ACNEService *neService = [self serviceForMenuItem:sender];
  if(neService == nil) {
    return;
  }

  // Manually disconnecting through the app disables auto connect for this
  // service so it is not immediately reconnected by the auto-connect timer.
  [[ACConnectionManager sharedManager] setAlwaysAutoConnect:NO forACNEService:neService];

  [neService disconnect];

  [self refreshMenu];
}

//
// Disconnects every currently-connected service. Disabling auto connect for each
// prevents the auto-connect timer from immediately reconnecting them.
//
- (IBAction)disconnectAll:(id)sender {
  ACConnectionManager *connectionManager = [ACConnectionManager sharedManager];

  for(ACNEService *neService in [self connectedServices]) {
    [connectionManager setAlwaysAutoConnect:NO forACNEService:neService];
    [neService disconnect];
  }

  [self refreshMenu];
}

- (IBAction)openSettings:(id)sender {
  // Create the window (if it doesn't exist yet) and bring it front as the key
  // window. Activating the app is required because a menu-bar (LSUIElement)
  // agent is not frontmost by default, so -showWindow:/-makeKeyAndOrderFront:
  // alone would order the window in behind the previously active app.
  // orderFrontRegardless guarantees it comes to the very front even if the
  // activation hasn't fully taken effect yet.
  ACPreferencesWindowController *windowController = [ACPreferencesWindowController sharedWindowController];

  [NSApp activateIgnoringOtherApps:YES];
  [windowController showWindow:self];

  NSWindow *window = windowController.window;
  [window makeKeyAndOrderFront:self];
  [window orderFrontRegardless];
}

- (IBAction)doQuit:(id)sender {
  [NSApp terminate:self];
}

@end
