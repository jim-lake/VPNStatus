//
//  ACNEServicesManager_Internal.h
//  VPN
//
//  Internal surface of ACNEServicesManager, factored out of the .m so the unit
//  tests can drive the configuration filtering directly with stub
//  NEConfigurations. Not part of the public API; imported by
//  ACNEServicesManager.m and the filtering unit tests only.
//

#import "ACNEServicesManager.h"

@class NEConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface ACNEServicesManager ()

// Rebuilds -neServices from the loaded NEConfigurations, dropping non-VPN
// configurations (nil -VPN), ignored names, and internal com.apple.preferences.*
// entries. Exposed for unit testing the filter.
- (void)processConfigurations:(NSArray<NEConfiguration *> *)inConfigurations;

@end

NS_ASSUME_NONNULL_END
