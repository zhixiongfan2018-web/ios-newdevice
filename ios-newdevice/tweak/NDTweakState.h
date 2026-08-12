#import <Foundation/Foundation.h>
#import "NDDeviceProfile.h"
#import "NDConfig.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDTweakState : NSObject
@property (nonatomic, strong, nullable) NDDeviceProfile *profile;
@property (nonatomic, strong) NDConfig *config;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, assign) BOOL active; // target app and not original empty profile
@property (nonatomic, assign) BOOL identityHost; // CommCenter / telephony hosts

+ (instancetype)shared;
- (void)reload;
/// Target-app sandbox spoof (location, SSID, disk, …).
- (BOOL)shouldSpoof;
/// Identity spoof including telephony hosts (IMEI / Gestalt in CommCenter).
- (BOOL)shouldSpoofIdentity;
@end

NS_ASSUME_NONNULL_END
