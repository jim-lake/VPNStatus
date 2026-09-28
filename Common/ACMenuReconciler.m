//
//  ACMenuReconciler.m
//  VPN
//

#import "ACMenuReconciler.h"

@implementation ACMenuRowDescriptor

+ (instancetype)descriptorWithKey:(NSString *)key
                            title:(NSString *)title
                           action:(SEL)action
                            state:(NSControlStateValue)state
                          enabled:(BOOL)enabled
                representedObject:(id)representedObject {
  ACMenuRowDescriptor *descriptor = [[ACMenuRowDescriptor alloc] init];
  descriptor.key = key;
  descriptor.title = title;
  descriptor.action = action;
  descriptor.state = state;
  descriptor.enabled = enabled;
  descriptor.representedObject = representedObject;
  return descriptor;
}

+ (instancetype)separatorDescriptorWithKey:(NSString *)key {
  ACMenuRowDescriptor *descriptor = [[ACMenuRowDescriptor alloc] init];
  descriptor.key = key;
  descriptor.title = @"";
  descriptor.enabled = YES;
  descriptor.separator = YES;
  return descriptor;
}

@end


@implementation ACMenuReconciler

- (instancetype)initWithActionTarget:(id)actionTarget {
  self = [super init];
  if(self) {
    _actionTarget = actionTarget;
  }
  return self;
}

#pragma mark - Anchor lookup

- (NSInteger)indexOfItemWithIdentifier:(NSString *)inIdentifier inMenu:(NSMenu *)inMenu {
  for(NSInteger i = 0; i < inMenu.numberOfItems; i++) {
    NSString *identifier = [inMenu itemAtIndex:i].identifier;
    if(identifier != nil && [identifier isEqualToString:inIdentifier]) {
      return i;
    }
  }
  return NSNotFound;
}

// Finds an item with the given identifier at or after inFrom, stopping at the
// end anchor. Returns NSNotFound if not present in the region.
- (NSInteger)indexOfItemWithIdentifier:(NSString *)inIdentifier
                                inMenu:(NSMenu *)inMenu
                             fromIndex:(NSInteger)inFrom
                   endAnchorIdentifier:(NSString *)inEndAnchorIdentifier {
  for(NSInteger i = inFrom; i < inMenu.numberOfItems; i++) {
    NSMenuItem *item = [inMenu itemAtIndex:i];
    if(item.identifier != nil && [item.identifier isEqualToString:inEndAnchorIdentifier]) {
      break;
    }
    if(item.identifier != nil && [item.identifier isEqualToString:inIdentifier]) {
      return i;
    }
  }
  return NSNotFound;
}

#pragma mark - In-place item update

// Applies desired presentation to an existing item, touching each property only
// when it actually differs so we never poke the UI needlessly.
- (void)applyDescriptor:(ACMenuRowDescriptor *)inDescriptor toItem:(NSMenuItem *)inItem {
  // Separators carry no presentation to update.
  if(inDescriptor.isSeparator) {
    return;
  }

  if(![inItem.title isEqualToString:inDescriptor.title]) {
    inItem.title = inDescriptor.title;
  }

  if(inItem.action != inDescriptor.action) {
    inItem.action = inDescriptor.action;
    inItem.target = (inDescriptor.action != NULL) ? self.actionTarget : nil;
  }

  if(inItem.state != inDescriptor.state) {
    inItem.state = inDescriptor.state;
  }

  if(inItem.enabled != inDescriptor.isEnabled) {
    inItem.enabled = inDescriptor.isEnabled;
  }

  // representedObject is identity-ish; only reset if changed.
  if(inItem.representedObject != inDescriptor.representedObject &&
     ![inItem.representedObject isEqual:inDescriptor.representedObject]) {
    inItem.representedObject = inDescriptor.representedObject;
  }
}

- (NSMenuItem *)makeItemForDescriptor:(ACMenuRowDescriptor *)inDescriptor {
  if(inDescriptor.isSeparator) {
    NSMenuItem *sep = [NSMenuItem separatorItem];
    sep.identifier = inDescriptor.key;
    return sep;
  }

  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:inDescriptor.title
                                                action:inDescriptor.action
                                         keyEquivalent:@""];
  item.identifier = inDescriptor.key;
  item.representedObject = inDescriptor.representedObject;
  item.state = inDescriptor.state;
  item.enabled = inDescriptor.isEnabled;
  item.target = (inDescriptor.action != NULL) ? self.actionTarget : nil;
  return item;
}

#pragma mark - Reconciliation

- (void)reconcileMenu:(NSMenu *)inMenu
  beginAnchorIdentifier:(NSString *)inBeginAnchorIdentifier
    endAnchorIdentifier:(NSString *)inEndAnchorIdentifier
            descriptors:(NSArray<ACMenuRowDescriptor *> *)inDescriptors {
  NSInteger beginIndex = [self indexOfItemWithIdentifier:inBeginAnchorIdentifier inMenu:inMenu];
  if(beginIndex == NSNotFound) {
    // Nothing we can do without the anchor; fail safe by doing nothing.
    return;
  }

  NSInteger cursor = beginIndex + 1;

  for(ACMenuRowDescriptor *descriptor in inDescriptors) {
    NSString *key = descriptor.key;

    // Is the desired item already exactly at the cursor?
    NSMenuItem *itemAtCursor = (cursor < inMenu.numberOfItems) ? [inMenu itemAtIndex:cursor] : nil;
    if(itemAtCursor != nil && itemAtCursor.identifier != nil && [itemAtCursor.identifier isEqualToString:key]) {
      [self applyDescriptor:descriptor toItem:itemAtCursor];
      cursor++;
      continue;
    }

    // Does it exist later in the region (reordered)? If so, move it.
    NSInteger existingIndex = [self indexOfItemWithIdentifier:key
                                                       inMenu:inMenu
                                                    fromIndex:cursor
                                          endAnchorIdentifier:inEndAnchorIdentifier];
    if(existingIndex != NSNotFound) {
      NSMenuItem *existing = [inMenu itemAtIndex:existingIndex];
      [inMenu removeItemAtIndex:existingIndex];
      [inMenu insertItem:existing atIndex:cursor];
      [self applyDescriptor:descriptor toItem:existing];
      cursor++;
      continue;
    }

    // New row — insert a freshly-made item.
    NSMenuItem *item = [self makeItemForDescriptor:descriptor];
    [inMenu insertItem:item atIndex:cursor];
    cursor++;
  }

  // Remove any stale items left in the region (keys no longer desired), up to
  // the end anchor.
  while(cursor < inMenu.numberOfItems) {
    NSMenuItem *item = [inMenu itemAtIndex:cursor];
    if(item.identifier != nil && [item.identifier isEqualToString:inEndAnchorIdentifier]) {
      break;
    }
    [inMenu removeItemAtIndex:cursor];
  }
}

@end
