//
//  ACLocationManager.m
//  VPNApp
//
//  Created by Alexandre Colucci on 30.09.2023.
//  Copyright © 2023 Timac. All rights reserved.
//

#import "ACLocationManager.h"

#import <os/log.h>

NSString *const kACLocationManagerAuthorizationDidChange = @"kACLocationManagerAuthorizationDidChange";

@interface ACLocationManager () <CLLocationManagerDelegate>
@property (strong, nonatomic) CLLocationManager *locationManager;
@end

@implementation ACLocationManager

+ (ACLocationManager *)sharedLocationManager {
  static ACLocationManager *sLocationManager = nil;
  if(sLocationManager == nil) {
    sLocationManager = [[ACLocationManager alloc] init];
  }

  return sLocationManager;
}

- (id)init {
  self = [super init];
  if(self) {
    _locationManager = [[CLLocationManager alloc] init];
    _locationManager.delegate = self;
    _locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    _locationManager.distanceFilter = kCLDistanceFilterNone;
    _locationManager.activityType = CLActivityTypeOther;
  }

  return self;
}

- (CLAuthorizationStatus)authorizationStatus {
  return self.locationManager.authorizationStatus;
}

- (void)requestAlwaysAuthorizationIfNeeded {
  switch(self.authorizationStatus) {
  case kCLAuthorizationStatusNotDetermined:
    [self.locationManager requestAlwaysAuthorization];
    break;

  case kCLAuthorizationStatusRestricted:
  case kCLAuthorizationStatusDenied:
    os_log(OS_LOG_DEFAULT, "Location Services access is not authorized");
    break;

  case kCLAuthorizationStatusAuthorizedAlways:
    // Already authorized
    break;
  }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
  os_log_info(OS_LOG_DEFAULT, "locationManagerDidChangeAuthorization %d", manager.authorizationStatus);

  // Post a notification to refresh the UI
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:kACLocationManagerAuthorizationDidChange object:nil];
  });
}

@end
