#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

@class ACNEService;

NS_ASSUME_NONNULL_BEGIN

@interface ACAutoConnectPolicy : NSObject

@property (strong) NSMutableSet<NSString *> *armedServiceIdentifiers;

+ (ACAutoConnectPolicy *)sharedPolicy;

- (void)requestConnectService:(ACNEService *)inService;
- (void)requestDisconnectService:(ACNEService *)inService;
- (void)requestCancelService:(ACNEService *)inService;
- (void)requestDisconnectServices:(NSArray<ACNEService *> *)inServices;

- (void)armServiceIdentifier:(NSString *)inServiceIdentifier;
- (void)disarmServiceIdentifier:(NSString *)inServiceIdentifier;
- (BOOL)isArmedServiceIdentifier:(NSString *)inServiceIdentifier;

- (void)handleState:(SCNetworkConnectionStatus)inState forService:(ACNEService *)inService;

@end

NS_ASSUME_NONNULL_END
