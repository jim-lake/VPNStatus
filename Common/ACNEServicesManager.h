#import <Foundation/Foundation.h>

@class ACNEService;
@class NEConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface ACNEServicesManager : NSObject

@property (strong, nonnull) NSMutableArray<ACNEService *> *neServices;
@property (readonly, nonatomic, nonnull) dispatch_queue_t neServiceQueue;

+ (nonnull ACNEServicesManager *)sharedNEServicesManager;

- (void)loadConfigurationsWithHandler:(void (^)(NSError *_Nullable error))handler;

// Rebuilds -neServices from the loaded NEConfigurations, dropping non-VPN
// configurations (nil -VPN), ignored names, and internal com.apple.preferences.*
// entries.
- (void)processConfigurations:(NSArray<NEConfiguration *> *)inConfigurations;

@end

NS_ASSUME_NONNULL_END
