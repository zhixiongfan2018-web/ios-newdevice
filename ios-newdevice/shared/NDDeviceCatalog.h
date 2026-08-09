#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog : NSObject
/// Model / ProductType / HardwareMachine / HardwareModel(board id)
+ (NSArray<NSDictionary *> *)deviceModels;
+ (NSArray<NSString *> *)systemVersions;
/// Real Apple build id for a marketing system version (best-effort).
+ (nullable NSString *)buildForSystemVersion:(NSString *)systemVer;
+ (NSArray<NSDictionary *> *)carriers; // Carrier, MCC, MNC
+ (NSArray<NSString *> *)radioAccessTypes;
+ (NSDictionary *)randomChinaCoordinate; // lat, lon
/// Resolve catalog row by Model or ProductType (AMG Set_Device_Model style).
+ (nullable NSDictionary *)deviceEntryMatching:(NSString *)modelOrProductType;
@end

NS_ASSUME_NONNULL_END
