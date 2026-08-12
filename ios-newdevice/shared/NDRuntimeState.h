#import <Foundation/Foundation.h>
#import "NDConfig.h"
#import "NDDeviceProfile.h"

NS_ASSUME_NONNULL_BEGIN

/// Publishes a world-readable snapshot so sandboxed target apps can apply spoof.
@interface NDRuntimeState : NSObject
+ (void)publishWithConfig:(NDConfig *)config
                  profile:(nullable NDDeviceProfile *)profile
              currentName:(nullable NSString *)currentName;
+ (nullable NSDictionary *)dictionary;
+ (nullable NDDeviceProfile *)profileFromDictionary:(NSDictionary *)dict;
@end

NS_ASSUME_NONNULL_END
