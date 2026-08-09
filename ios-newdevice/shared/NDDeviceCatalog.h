#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog : NSObject
+ (NSArray<NSDictionary *> *)deviceModels; // Model, ProductType, HardwareMachine
+ (NSArray<NSString *> *)systemVersions;
+ (NSArray<NSDictionary *> *)carriers; // Carrier, MCC, MNC
+ (NSArray<NSString *> *)radioAccessTypes;
+ (NSDictionary *)randomChinaCoordinate; // lat, lon
@end

NS_ASSUME_NONNULL_END
