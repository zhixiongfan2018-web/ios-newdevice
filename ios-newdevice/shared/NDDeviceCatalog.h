#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog : NSObject
+ (NSArray<NSDictionary *> *)deviceModels; // Model, ProductType, HardwareMachine
/// Official public iOS/iPadOS versions (aligned with Apple release builds).
+ (NSArray<NSString *> *)systemVersions;
/// Official Build for a SystemVer (empty if unknown).
+ (NSString *)buildForSystemVersion:(NSString *)systemVer;
/// Full map SystemVer → Build (source of truth for spoof + UI).
+ (NSDictionary<NSString *, NSString *> *)officialSystemBuilds;
+ (NSArray<NSDictionary *> *)carriers; // Carrier, MCC, MNC (US)
+ (NSArray<NSString *> *)radioAccessTypes;
+ (NSArray<NSDictionary *> *)usCityCoordinates;
+ (NSDictionary *)randomUSCoordinate; // lat, lon, city, country, timezone
+ (NSArray<NSString *> *)wifiSSIDs;
+ (NSDictionary *)randomWiFiNetwork; // SSID, BSSID
/// @deprecated Use usCityCoordinates / randomUSCoordinate (US locale pools).
+ (NSArray<NSDictionary *> *)chinaCityCoordinates;
+ (NSDictionary *)randomChinaCoordinate;
@end

NS_ASSUME_NONNULL_END
