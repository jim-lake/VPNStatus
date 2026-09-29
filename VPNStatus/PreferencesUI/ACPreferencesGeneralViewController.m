//
//  ACPreferencesGeneralViewController.m
//
//  Created by Alexandre Colucci on 06.04.2024.
//  Copyright © 2024 Alexandre Colucci. All rights reserved.

#import "ACPreferencesGeneralViewController.h"

#import "ACPreferences.h"

@interface ACPreferencesGeneralViewController ()

@property (weak) IBOutlet NSTextField *minReconnectField;
@property (weak) IBOutlet NSTextField *maxReconnectField;
@property (weak) IBOutlet NSPopUpButton *menuBarImagePopUpButton;

@end


@implementation ACPreferencesGeneralViewController

- (instancetype)initViewController {
  self = [super initWithNibName:@"ACPreferencesGeneralView" bundle:nil];
  if(self) {
  }

  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  [self.minReconnectField setIntegerValue:[[ACPreferences sharedPreferences] minReconnect]];
  [self.maxReconnectField setIntegerValue:[[ACPreferences sharedPreferences] maxReconnect]];

  NSMenu *theMenu = self.menuBarImagePopUpButton.menu;
  for(NSInteger menuItemIndex = 0; menuItemIndex < theMenu.numberOfItems; menuItemIndex++) {
    NSMenuItem *menuItem = [theMenu itemAtIndex:menuItemIndex];
    [menuItem setImage:[ACPreferences menuBarImageForState:MenuBarImageState_On andType:menuItemIndex]];
  }

  NSInteger selectedMenuBarItem = [[ACPreferences sharedPreferences] menuBarImageType];
  [self.menuBarImagePopUpButton selectItemAtIndex:selectedMenuBarItem];
}

- (void)viewWillDisappear {
  [super viewWillDisappear];

  // Save when closing the window
  [self saveReconnectBounds];
}

// Persist the min/max reconnect fields, keeping min <= max, and reflect any
// clamping back into the fields.
- (void)saveReconnectBounds {
  NSInteger minReconnect = [self.minReconnectField integerValue];
  NSInteger maxReconnect = [self.maxReconnectField integerValue];

  if(minReconnect < 0) {
    minReconnect = 0;
  }
  if(maxReconnect < 0) {
    maxReconnect = 0;
  }
  if(minReconnect > maxReconnect) {
    minReconnect = maxReconnect;
  }

  [[ACPreferences sharedPreferences] setMinReconnect:minReconnect];
  [[ACPreferences sharedPreferences] setMaxReconnect:maxReconnect];

  [self.minReconnectField setIntegerValue:minReconnect];
  [self.maxReconnectField setIntegerValue:maxReconnect];
}

- (NSString *)identifier {
  return [[self title] lowercaseString];
}

- (NSString *)title {
  return @"General";
}

- (IBAction)minReconnectDidChange:(id)sender {
  [self saveReconnectBounds];
}

- (IBAction)maxReconnectDidChange:(id)sender {
  [self saveReconnectBounds];
}

- (IBAction)doChangeMenuBarImage:(id)sender {
  NSInteger menuBarImageType = [sender indexOfSelectedItem];
  [[ACPreferences sharedPreferences] setMenuBarImageType:menuBarImageType];
}

@end
