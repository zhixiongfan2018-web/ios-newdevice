#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog : NSObject
+ (NSArray<NSDictionary *> *)deviceModels; // Model, ProductType, HardwareMachine
+ (NSArray<NSString *> *)systemVersions;
+ (NSArray<NSDictionary *> *)carriers; // Carrier, MCC, MNC
+ (NSArray<NSString *> *)radioAccessTypes;
+ (NSArray<NSDictionary *> *)chinaCityCoordinates; // city, lat, lon
+ (NSDictionary *)randomChinaCoordinate; // lat, lon, city
@end

NS_ASSUME_NONNULL_END
