#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog : NSObject
+ (NSArray<NSDictionary *> *)deviceModels; // Model, ProductType, HardwareMachine
/// Official public iOS/iPadOS versions offered to users / 一键新机 (iOS 18+ only).
+ (NSArray<NSString *> *)systemVersions;
/// Major from "18.5" style string (unknown → 0).
+ (NSInteger)majorSystemVersion:(NSString *)systemVer;
/// Official Build for a SystemVer (empty if unknown).
+ (NSString *)buildForSystemVersion:(NSString *)systemVer;
/// Full map SystemVer → Build (source of truth for spoof + UI).
+ (NSDictionary<NSString *, NSString *> *)officialSystemBuilds;
+ (NSArray<NSDictionary *> *)carriers; // Carrier, MCC, MNC (US)
/// YES when Carrier looks like a real CTCarrier name (not an ISP/POI string).
+ (BOOL)isPlausibleCarrierName:(NSString *)name;
/// Pick a US carrier row (optionally matching MCC/MNC). Deterministic via seed.
+ (NSDictionary *)carrierForSeed:(uint32_t)seed preferMCC:(nullable NSString *)mcc preferMNC:(nullable NSString *)mnc;
+ (NSArray<NSString *> *)radioAccessTypes;
+ (NSArray<NSDictionary *> *)usCityCoordinates;
+ (NSDictionary *)randomUSCoordinate; // lat, lon, city, country, timezone
/// Contiguous US + AK/HI bounding check (spoof storyline is US-locale).
+ (BOOL)isCoordinateInUS:(double)lat longitude:(double)lon;
/// Nearest US city; returns nil if farther than maxDeg (degrees² threshold unused — use maxDeg as max |dlat|/|dlon| approx).
+ (nullable NSDictionary *)nearestUSCityToLatitude:(double)lat longitude:(double)lon maxDegrees:(double)maxDeg;
/// Seeded US city (+ small jitter) for stable align fixes.
+ (NSDictionary *)usCoordinateForSeed:(uint32_t)seed;
+ (NSArray<NSString *> *)wifiSSIDs;
+ (NSDictionary *)randomWiFiNetwork; // SSID, BSSID
/// Factory colors plausible for ProductType (no Titanium on SE / non-Pro).
+ (NSArray<NSString *> *)deviceColorsForProductType:(NSString *)productType;
/// Mainstream iOS 18 builds for 一键新机 / align (excludes device-specific emergency patches).
+ (NSArray<NSString *> *)preferredSystemVersions;
/// YES for XR/XS-only maintenance builds that should not appear on SE3/14+.
+ (BOOL)isLimitedSupportSystemVersion:(NSString *)systemVer;
/// Modern USB UDID (00008xxx-…) for A12+; empty if unknown family.
+ (NSString *)modernUDIDPrefixForProductType:(NSString *)productType;
/// @deprecated Use usCityCoordinates / randomUSCoordinate (US locale pools).
+ (NSArray<NSDictionary *> *)chinaCityCoordinates;
+ (NSDictionary *)randomChinaCoordinate;
@end

NS_ASSUME_NONNULL_END
