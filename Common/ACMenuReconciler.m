//
//  ACMenuReconciler.m
//  VPN
//

#import "ACMenuReconciler.h"

#pragma mark - ACMenuItemTrailingTextView

// Standard macOS menu metrics, measured against AppKit's default item on
// macOS 15 by rendering a plain item next to this view and comparing the title
// left edges pixel-for-pixel: a plain item's title starts 16pt from the view's
// leading edge. Keep this in sync if the OS menu metrics change.
static const CGFloat kMenuLeadingInset = 16.0;   // left edge → title (no checkmark in menu)
static const CGFloat kMenuTrailingInset = 16.0;  // trailing text → right edge
static const CGFloat kMenuVerticalPadding = 3.5; // top/bottom padding (row height matches AppKit's 24pt)
static const CGFloat kMenuInterItemGap = 5.0;    // minimum gap between title and trailing text (cancel always has >=5pt to its left)
static const CGFloat kMenuHighlightInset = 5.0;  // side inset of the rounded highlight
static const CGFloat kMenuHighlightRadius = 4.0;
static const CGFloat kMenuCheckmarkGutter = 12.0; // extra left inset when any item is checked

@interface ACMenuItemTrailingTextView ()
@property (weak) NSMenuItem *menuItem;
@property (strong) NSTextField *titleLabel;
@property (strong) NSTextField *trailingLabel;
@property (strong) NSLayoutConstraint *leadingConstraint;
@end

@implementation ACMenuItemTrailingTextView

- (instancetype)initWithMenuItem:(NSMenuItem *)menuItem {
  self = [super initWithFrame:NSZeroRect];
  if(self) {
    _menuItem = menuItem;
    // Width-sizable so AppKit can stretch the row to the final menu width; the
    // Auto Layout spacer inside then keeps the trailing text flush right.
    self.autoresizingMask = NSViewWidthSizable;
    [self buildSubviews];
    self.frame = (NSRect){NSZeroPoint, self.intrinsicContentSize};
  }
  return self;
}

- (NSFont *)menuFont {
  return [NSFont menuFontOfSize:0];
}

// A menu label: no background/border/editing, uses the menu font. The row is
// always sized to fit the full text, so the label never needs a line-break or
// truncation mode.
- (NSTextField *)makeLabel {
  NSTextField *label = [NSTextField labelWithString:@""];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  label.font = [self menuFont];
  return label;
}

// Lays the row out as: [leadingInset][title]<<flexible>>[>=gap][trailing][trailingInset]
// using Auto Layout, so the two texts share the row without ever overlapping and
// without us measuring string widths or positioning anything by hand.
- (void)buildSubviews {
  self.titleLabel = [self makeLabel];
  self.trailingLabel = [self makeLabel];
  self.titleLabel.stringValue = [self title];
  self.trailingLabel.stringValue = self.trailingText ?: @"";
  // Stable accessibility identifiers so UI tests can read each label's rendered
  // contents by identifier and assert the full text is shown (not truncated).
  self.titleLabel.accessibilityIdentifier = @"menuitem.primary";
  self.trailingLabel.accessibilityIdentifier = @"menuitem.secondary";
  [self addSubview:self.titleLabel];
  [self addSubview:self.trailingLabel];

  // Both texts are required to keep their full width and must never be
  // compressed/truncated; the row grows to fit them (see -intrinsicContentSize).
  [self.titleLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.titleLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.trailingLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.trailingLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

  self.leadingConstraint = [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:[self leadingInset]];

  [NSLayoutConstraint activateConstraints:@[
    self.leadingConstraint,
    [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [self.trailingLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [self.trailingLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                      constant:-kMenuTrailingInset],
    // The gap the user asked for: trailing text always has >= this margin to its
    // left, so it can never touch or overlap the title. This is the flex point.
    [self.trailingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabel.trailingAnchor
                                                                  constant:kMenuInterItemGap],
    [self.heightAnchor constraintEqualToConstant:[self naturalHeight]],
  ]];
}

- (CGFloat)naturalHeight {
  return ceil([self menuFont].boundingRectForFont.size.height) + 2 * kMenuVerticalPadding;
}

// AppKit sizes a custom menu-item view from its intrinsic/fitting size (a pure
// Auto Layout view with none collapses to zero). We derive width from the two
// labels' own fitting widths — not by measuring strings by hand — plus the row
// insets and the minimum gap. AppKit then makes the menu at least this wide and
// only ever stretches it wider, so the title never truncates.
- (NSSize)intrinsicContentSize {
  CGFloat titleW = self.titleLabel.fittingSize.width;
  CGFloat trailingW = self.trailingLabel.fittingSize.width;
  CGFloat width = [self leadingInset] + ceil(titleW) + kMenuInterItemGap + ceil(trailingW) + kMenuTrailingInset;
  return NSMakeSize(width, [self naturalHeight]);
}

// Leading inset for the title. When the enclosing menu has any checked item,
// AppKit indents all titles by the checkmark gutter; mirror that so our title
// lines up with the plain rows.
- (CGFloat)leadingInset {
  NSMenu *menu = self.menuItem.menu;
  for(NSMenuItem *item in menu.itemArray) {
    if(item.state != NSControlStateValueOff) {
      return kMenuLeadingInset + kMenuCheckmarkGutter;
    }
  }
  return kMenuLeadingInset;
}

- (NSString *)title {
  return self.menuItem.title ?: @"";
}

- (BOOL)isHighlightedRow {
  return self.menuItem.isHighlighted && self.menuItem.isEnabled;
}

// A custom NSMenuItem.view is not automatically redrawn/updated when the row's
// highlight changes, so track mouse enter/exit and refresh text colors and the
// highlight background.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for(NSTrackingArea *area in [self.trackingAreas copy]) {
    [self removeTrackingArea:area];
  }
  NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                      options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                        owner:self
                                                     userInfo:nil];
  [self addTrackingArea:area];
}

- (void)mouseEntered:(NSEvent *)event {
  self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
  self.needsDisplay = YES;
}

// Keep content and colors current whenever we're about to draw.
- (void)viewWillDraw {
  self.leadingConstraint.constant = [self leadingInset];
  if(![self.titleLabel.stringValue isEqualToString:[self title]]) {
    self.titleLabel.stringValue = [self title];
    [self invalidateIntrinsicContentSize];
  }
  if(![self.trailingLabel.stringValue isEqualToString:(self.trailingText ?: @"")]) {
    self.trailingLabel.stringValue = self.trailingText ?: @"";
    [self invalidateIntrinsicContentSize];
  }

  BOOL highlighted = [self isHighlightedRow];
  BOOL enabled = self.menuItem.isEnabled;
  if(highlighted) {
    self.titleLabel.textColor = [NSColor selectedMenuItemTextColor];
    self.trailingLabel.textColor = [[NSColor selectedMenuItemTextColor] colorWithAlphaComponent:0.7];
  } else if(enabled) {
    self.titleLabel.textColor = [NSColor labelColor];
    self.trailingLabel.textColor = [NSColor secondaryLabelColor];
  } else {
    self.titleLabel.textColor = [NSColor disabledControlTextColor];
    self.trailingLabel.textColor = [NSColor disabledControlTextColor];
  }
  [super viewWillDraw];
}

- (void)drawRect:(NSRect)dirtyRect {
  if([self isHighlightedRow]) {
    NSRect hi = NSInsetRect(self.bounds, kMenuHighlightInset, 0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:hi xRadius:kMenuHighlightRadius yRadius:kMenuHighlightRadius];
    [[NSColor selectedContentBackgroundColor] set];
    [path fill];
  }
}

// Route mouse clicks through the item's real target/action, like a normal row.
- (void)mouseUp:(NSEvent *)event {
  NSMenuItem *item = self.menuItem;
  NSMenu *menu = item.menu;
  if(item.isEnabled && menu != nil) {
    [menu cancelTracking];
    [NSApp sendAction:item.action to:item.target from:item];
  }
}

- (void)setTrailingText:(NSString *)trailingText {
  _trailingText = [trailingText copy];
  self.trailingLabel.stringValue = _trailingText ?: @"";
  [self invalidateIntrinsicContentSize];
  self.needsDisplay = YES;
}

@end


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

  [self applyTrailingText:inDescriptor.trailingText toItem:inItem];
}

// Installs, updates, or removes the custom trailing-text view on the item,
// touching it only when the desired text actually changed.
- (void)applyTrailingText:(NSString *)inTrailingText toItem:(NSMenuItem *)inItem {
  if(inTrailingText == nil) {
    if(inItem.view != nil) {
      inItem.view = nil;
    }
    return;
  }

  ACMenuItemTrailingTextView *view = [inItem.view isKindOfClass:[ACMenuItemTrailingTextView class]] ? (ACMenuItemTrailingTextView *)inItem.view : nil;
  if(view == nil) {
    view = [[ACMenuItemTrailingTextView alloc] initWithMenuItem:inItem];
    inItem.view = view;
  }
  if(![view.trailingText isEqualToString:inTrailingText]) {
    view.trailingText = inTrailingText;
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
  [self applyTrailingText:inDescriptor.trailingText toItem:item];
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
