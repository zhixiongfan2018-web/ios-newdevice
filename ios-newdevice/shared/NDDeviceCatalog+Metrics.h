#import "NDDeviceCatalog.h"

NS_ASSUME_NONNULL_BEGIN

@interface NDDeviceCatalog (Metrics)
/// Logical points size + scale for a ProductType. Returns nil if unknown.
+ (nullable NSDictionary *)displayMetricsForProductType:(NSString *)productType;
/// Physical memory bytes for ProductType.
+ (uint64_t)memoryBytesForProductType:(NSString *)productType;
/// Approximate total disk capacity bytes.
+ (uint64_t)diskBytesForProductType:(NSString *)productType;
@end

NS_ASSUME_NONNULL_END
