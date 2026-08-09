#import <Foundation/Foundation.h>
#import "NDDeviceProfile.h"
#import "NDConfig.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDTweakState : NSObject
@property (nonatomic, strong, nullable) NDDeviceProfile *profile;
@property (nonatomic, strong) NDConfig *config;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, assign) BOOL active; // target app and not original empty profile

+ (instancetype)shared;
- (void)reload;
- (BOOL)shouldSpoof;
@end

NS_ASSUME_NONNULL_END
