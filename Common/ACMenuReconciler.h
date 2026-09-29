//
//  ACMenuReconciler.h
//  VPN
//
//  Pure, UI-framework-only helper that updates a section of an NSMenu in place
//  ("delta" / reconciliation) rather than rebuilding it. Extracted from
//  AppDelegate so the diffing logic can be unit-tested without VPN hardware,
//  singletons, code signing, or a running app.
//
//  The reconciler operates on a region of an NSMenu delimited by two "anchor"
//  items (located by NSMenuItem.identifier). It matches existing items to the
//  desired list by a stable key, reusing/moving surviving items and only
//  inserting/removing items that actually appeared or disappeared.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

//
// A lightweight, value-type description of a single row the caller wants in the
// menu. Deliberately decoupled from ACNEService so tests can build these
// directly.
//
@interface ACMenuRowDescriptor : NSObject

// Stable identity for the row. Two descriptors with the same key across two
// reconciliations refer to "the same" row and must reuse the same NSMenuItem.
@property (copy) NSString *key;

// Desired presentation. These may change between reconciliations for the same
// key; the reconciler updates them in place only when they differ.
@property (copy) NSString *title;
@property (nullable) SEL action;
@property (assign) NSControlStateValue state;
@property (assign, getter=isEnabled) BOOL enabled;

// Optional value carried on the resulting NSMenuItem.representedObject so that
// action handlers can resolve the underlying model (e.g. a VPN UUID).
@property (nullable, copy) id representedObject;

// When YES, the row is rendered as a separator item (title/action/state are
// ignored). Used so a section's separators are reconciled/reused in place like
// any other row.
@property (assign, getter=isSeparator) BOOL separator;

+ (instancetype)descriptorWithKey:(NSString *)key
                            title:(NSString *)title
                           action:(nullable SEL)action
                            state:(NSControlStateValue)state
                          enabled:(BOOL)enabled
                representedObject:(nullable id)representedObject;

+ (instancetype)separatorDescriptorWithKey:(NSString *)key;

@end


@interface ACMenuReconciler : NSObject

// Target of the menu items' actions (typically the AppDelegate).
@property (nullable, weak) id actionTarget;

- (instancetype)initWithActionTarget:(nullable id)actionTarget;

//
// Reconciles the region of inMenu that lies strictly between the item with
// identifier inBeginAnchorIdentifier and the item with identifier
// inEndAnchorIdentifier so that, afterwards, exactly the rows described by
// inDescriptors exist there, in that order.
//
// Rules:
//  - A desired row whose key already exists in the region reuses the *same*
//    NSMenuItem instance (moved if necessary), and its title/action/state/
//    enabled are updated only when they differ.
//  - Desired rows with no existing match are inserted.
//  - Existing items whose key is no longer desired are removed.
//  - Item identifiers are set to the descriptor key so they can be matched
//    again next time.
//
- (void)reconcileMenu:(NSMenu *)inMenu
  beginAnchorIdentifier:(NSString *)inBeginAnchorIdentifier
    endAnchorIdentifier:(NSString *)inEndAnchorIdentifier
            descriptors:(NSArray<ACMenuRowDescriptor *> *)inDescriptors;

@end

NS_ASSUME_NONNULL_END
