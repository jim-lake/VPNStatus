//
//  main.m
//  vpnutil
//
//  Created by Alexandre Colucci on 07.07.2018.
//  Copyright © 2018 Timac. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <os/log.h>

#import "ACDefines.h"
#import "ACNEService.h"
#import "ACNEServicesManager.h"

static void PrintUsage(void) {
  fprintf(stderr, "Usage: vpnutil [start|stop|list|status] [VPN name]\n");
  fprintf(stderr, "Examples:\n");
  fprintf(stderr, "\t To start the VPN called 'MyVPN':\n");
  fprintf(stderr, "\t vpnutil start MyVPN\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "\t To stop the VPN called 'MyVPN':\n");
  fprintf(stderr, "\t vpnutil stop MyVPN\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "\t To list all available VPNs and their state:\n");
  fprintf(stderr, "\t vpnutil list\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "\t To get the status of the VPN called 'MyVPN':\n");
  fprintf(stderr, "\t vpnutil status MyVPN\n");
  fprintf(stderr, "\n");
  fprintf(stderr, "Copyright © 2018-2024 Alexandre Colucci\nblog.timac.org\n");
  fprintf(stderr, "\n");

  exit(1);
}


static NSString *GetDescriptionForSCNetworkConnectionStatus(SCNetworkConnectionStatus inStatus) {
  switch(inStatus) {
  case kSCNetworkConnectionInvalid: {
    return @"Invalid";
  } break;

  case kSCNetworkConnectionDisconnected: {
    return @"Disconnected";
  } break;

  case kSCNetworkConnectionConnecting: {
    return @"Connecting";
  } break;

  case kSCNetworkConnectionConnected: {
    return @"Connected";
  } break;

  case kSCNetworkConnectionDisconnecting: {
    return @"Disconnecting";
  } break;

  default: {
    return @"Unknown";
  } break;
  }

  return @"Unknown";
};

int main(int argc, const char *argv[]) {
  @autoreleasepool {

    // Do we want to start or stop the service?
    BOOL shouldStartService = YES;
    BOOL statusService = NO;
    BOOL needServiceName = NO;
    BOOL listService = NO;
    int numArgs = 0;

    if(argc <= 1) {
      PrintUsage();
    }

    NSString *parameter1 = [NSString stringWithUTF8String:argv[1]];
    if([parameter1 isEqualToString:@"start"]) {
      shouldStartService = YES;
      needServiceName = YES;
      numArgs = 3;
    } else if([parameter1 isEqualToString:@"stop"]) {
      shouldStartService = NO;
      needServiceName = YES;
      numArgs = 3;
    } else if([parameter1 isEqualToString:@"list"]) {
      needServiceName = NO;
      shouldStartService = NO;
      listService = YES;
      numArgs = 2;
    } else if([parameter1 isEqualToString:@"status"]) {
      statusService = YES;
      needServiceName = YES;
      shouldStartService = NO;
      listService = NO;
      numArgs = 3;
    } else {
      PrintUsage();
    }

    if(argc != numArgs) {
      PrintUsage();
    }

    // Get the VPN name?
    __block NSString *vpnName;
    if(needServiceName) {
      vpnName = [NSString stringWithUTF8String:argv[2]];
      if([vpnName length] <= 0) {
        PrintUsage();
      }
    }

    // Since this is a command line tool, we manually run an NSRunLoop
    __block ACNEService *foundNEService = NULL;
    __block BOOL keepRunning = YES;
    __block NSArray<ACNEService *> *neServices = NULL;

    // Make sure that the ACNEServicesManager singleton is created and load the configurations
    [[ACNEServicesManager sharedNEServicesManager] loadConfigurationsWithHandler:^(NSError *error) {
      if(error != nil) {
        os_log_error(OS_LOG_DEFAULT, "Failed to load the configurations - %{public}@", error);
      }

      neServices = [[ACNEServicesManager sharedNEServicesManager] neServices];
      if([neServices count] <= 0) {
        os_log(OS_LOG_DEFAULT, "Could not find any VPN");
      }

      for(ACNEService *neService in neServices) {
        if([neService.name isEqualToString:vpnName]) {
          foundNEService = neService;
          break;
        }
      }

      if(needServiceName && !foundNEService) {
        // Stop running the NSRunLoop
        keepRunning = NO;
      }
    }];

    CFAbsoluteTime startWaiting = CFAbsoluteTimeGetCurrent();

    //
    // Wait:
    //	- until we receive the list of NEServices
    //	- until we get the session status of the NEService
    //	- at least 1s to ensure that the session status is valid
    //
    // Stop waiting:
    //	- after a timeout of 10s
    //	- if the list of NEServices doesn't contain the expected service
    //
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while(keepRunning && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:timeoutDate]) {
      timeoutDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
      os_log_debug(OS_LOG_DEFAULT, "Waiting...");

      // Timeout after 10s
      if(startWaiting + 10.0 < CFAbsoluteTimeGetCurrent()) {
        os_log_debug(OS_LOG_DEFAULT, "Timeout...");
        keepRunning = NO;
      }

      // Ensure we wait at least 1s
      if(startWaiting + 1.0 < CFAbsoluteTimeGetCurrent()) {
        if(needServiceName) {
          if(foundNEService != nil && (foundNEService.gotInitialSessionStatus)) {
            os_log_debug(OS_LOG_DEFAULT, "Found NEService and session state");
            keepRunning = NO;
          }
        } else {
          // go through all services and keep running if we don't have a state for each service
          keepRunning = NO;
          for(ACNEService *neService in neServices) {
            if(!neService.gotInitialSessionStatus) {
              keepRunning = YES;
            }
          }
        }
      } else {
        os_log_debug(OS_LOG_DEFAULT, "Need to wait more...");
      }
    }

    if(listService) {
      /*
       Output a json like this:
       {
        "VPNs": [
          {
            "name": "VPN1",
            "status": "Connected"
          },
           {
             "name": "VPN2",
             "status": "Disconnected"
           },
           {
             "name": "VPN3",
             "status": "Disconnected"
           }
        ]
       }
       */
      NSMutableArray *vpnsArray = [[NSMutableArray alloc] init];
      for(ACNEService *neService in neServices) {
        NSDictionary *vpnDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                                neService.name, @"name",
                                                GetDescriptionForSCNetworkConnectionStatus(neService.state), @"status",
                                                nil];

        [vpnsArray addObject:vpnDict];
      }

      NSMutableDictionary *jsonDictionary = [[NSMutableDictionary alloc] init];
      if([vpnsArray count] > 0) {
        [jsonDictionary setObject:vpnsArray forKey:@"VPNs"];
      }

      NSError *jsonError = nil;
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:NSJSONWritingPrettyPrinted error:&jsonError];
      if(jsonData != nil) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        printf("%s\n", [jsonString UTF8String]);
      } else {
        printf("An error occurred: %s\n", [[jsonError localizedDescription] UTF8String]);
      }
    } else if(foundNEService) {
      SCNetworkConnectionStatus currentState = foundNEService.state;
      os_log_debug(OS_LOG_DEFAULT, "Got status %{public}@", GetDescriptionForSCNetworkConnectionStatus(currentState));
      if(statusService) {
        printf("%s %s\n", [foundNEService.name UTF8String], [GetDescriptionForSCNetworkConnectionStatus(foundNEService.state) UTF8String]);
      } else if(shouldStartService) {
        if(currentState == kSCNetworkConnectionDisconnected) {
          // Connect
          [foundNEService connect];
          os_log_info(OS_LOG_DEFAULT, "%{public}@ has been started", vpnName);
        } else {
          os_log(OS_LOG_DEFAULT, "%{public}@ was not started because it was in the state '%{public}@'", vpnName, GetDescriptionForSCNetworkConnectionStatus(currentState));
        }
      } else {
        if(currentState == kSCNetworkConnectionConnected) {
          // Disconnect
          [foundNEService disconnect];
          os_log_info(OS_LOG_DEFAULT, "%{public}@ has been stopped", vpnName);
        } else {
          os_log(OS_LOG_DEFAULT, "%{public}@ was not stopped because it was in the state '%{public}@'", vpnName, GetDescriptionForSCNetworkConnectionStatus(currentState));
        }
      }
    } else {
      os_log(OS_LOG_DEFAULT, "Could not find %{public}@", vpnName);
    }
  }

  return 0;
}
