//
//  ACNEServicesManager.m
//  VPN
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//

#import "ACNEServicesManager.h"
#import "ACNEServicesManager_Internal.h"

#import <os/log.h>

#import "ACDefines.h"
#import "ACNEService.h"
#import "ACPreferences.h"

@implementation ACNEServicesManager

+ (ACNEServicesManager *)sharedNEServicesManager {
  static ACNEServicesManager *sSharedNEServicesManager = nil;
  if(sSharedNEServicesManager == nil) {
    sSharedNEServicesManager = [[ACNEServicesManager alloc] init];
  }

  return sSharedNEServicesManager;
}

- (instancetype)init {
  self = [super init];
  if(self) {
    // Create the dispatch queue
    _neServiceQueue = dispatch_queue_create("Network Extension service Queue", NULL);

    // Allocate the NEServices array
    _neServices = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)loadConfigurationsWithHandler:(void (^)(NSError *error))handler {
  // Load the NEConfigurations
  [[NEConfigurationManager sharedManager] loadConfigurationsWithCompletionQueue:[self neServiceQueue]
                                                                        handler:^(NSArray<NEConfiguration *> *neConfigurations, NSError *error) {
                                                                          if(error != nil) {
                                                                            os_log_error(OS_LOG_DEFAULT, "ERROR loading configurations - %{public}@", error);
                                                                            return;
                                                                          }

                                                                          dispatch_async(dispatch_get_main_queue(), ^{
                                                                            // Process the configurations
                                                                            [self processConfigurations:neConfigurations];

                                                                            handler(error);
                                                                          });
                                                                        }];
}

- (void)processConfigurations:(NSArray<NEConfiguration *> *)inConfigurations {
  // Fill the array
  [self.neServices removeAllObjects];

  NSArray<NSString *> *ignoredVPNs = [[ACPreferences sharedPreferences] ignoredVPNs];

  for(NEConfiguration *neConfiguration in inConfigurations) {
    if(neConfiguration.VPN == nil) {
      // Not a VPN configuration: NEConfiguration also models Encrypted DNS
      // (DoH/DoT) profiles and content filters, whose payload lives in other
      // sub-objects and leaves -VPN nil. Only VPNs have a populated -VPN.
      continue;
    } else if([ignoredVPNs containsObject:neConfiguration.name]) {
      // Don't show the VPNs that should be ignored
      continue;
    } else if([neConfiguration.name hasPrefix:@"com.apple.preferences."]) {
      // Don't show internal configurations from macOS Sequoia
      // com.apple.preferences.application-firewall
      // com.apple.preferences.networkprivacy-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      continue;
    }

    ACNEService *service = [[ACNEService alloc] initWithConfiguration:neConfiguration];
    [self.neServices addObject:service];
  }

  // Sort by name
  [self.neServices sortUsingComparator:^NSComparisonResult(ACNEService *obj1, ACNEService *obj2) {
    return [obj1.name compare:obj2.name];
  }];

  // Refresh the states
  for(ACNEService *neService in self.neServices) {
    [neService refreshSession];
  }
}

@end
