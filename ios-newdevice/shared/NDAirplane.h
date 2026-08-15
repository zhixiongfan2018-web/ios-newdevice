#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDAirplane : NSObject
+ (BOOL)setAirplaneModeOn:(BOOL)on;
+ (BOOL)toggleAirplaneWithDelay:(NSTimeInterval)delay error:(NSError * _Nullable * _Nullable)error;
+ (void)fetchPublicIPWithCompletion:(void (^)(NSString * _Nullable ip, NSError * _Nullable error))completion;
/// Resolve public IP → lat/lon/timezone/city/countryCode/isp (nil on failure).
+ (void)fetchIPGeolocationWithCompletion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion;
/// Blocking helper (max ~2.5s). Keys: ip, lat, lon, timezone, city, countryCode, isp.
+ (nullable NSDictionary *)fetchIPGeolocationSync;
@end

NS_ASSUME_NONNULL_END
