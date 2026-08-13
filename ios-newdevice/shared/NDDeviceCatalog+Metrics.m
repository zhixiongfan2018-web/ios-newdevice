#import "NDDeviceCatalog+Metrics.h"

@implementation NDDeviceCatalog (Metrics)

+ (NSDictionary *)displayMetricsForProductType:(NSString *)productType {
    if (!productType.length) return nil;
    // width/height in points, scale
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            // SE / mini
            @"iPhone12,8": @{@"w": @375, @"h": @667, @"scale": @2}, // SE2
            @"iPhone14,6": @{@"w": @375, @"h": @667, @"scale": @2}, // SE3
            @"iPhone13,1": @{@"w": @360, @"h": @780, @"scale": @3}, // 12 mini
            @"iPhone14,4": @{@"w": @375, @"h": @812, @"scale": @3}, // 13 mini
            // standard
            @"iPhone12,1": @{@"w": @414, @"h": @896, @"scale": @2}, // 11
            @"iPhone13,2": @{@"w": @390, @"h": @844, @"scale": @3}, // 12
            @"iPhone14,5": @{@"w": @390, @"h": @844, @"scale": @3}, // 13
            @"iPhone14,7": @{@"w": @390, @"h": @844, @"scale": @3}, // 14
            @"iPhone15,4": @{@"w": @393, @"h": @852, @"scale": @3}, // 15
            @"iPhone17,3": @{@"w": @393, @"h": @852, @"scale": @3}, // 16
            @"iPhone17,5": @{@"w": @390, @"h": @844, @"scale": @3}, // 16e
            // Plus
            @"iPhone14,8": @{@"w": @428, @"h": @926, @"scale": @3}, // 14 Plus
            @"iPhone15,5": @{@"w": @430, @"h": @932, @"scale": @3}, // 15 Plus
            @"iPhone17,4": @{@"w": @430, @"h": @932, @"scale": @3}, // 16 Plus
            // Pro
            @"iPhone12,3": @{@"w": @375, @"h": @812, @"scale": @3}, // 11 Pro
            @"iPhone13,3": @{@"w": @390, @"h": @844, @"scale": @3}, // 12 Pro
            @"iPhone14,2": @{@"w": @390, @"h": @844, @"scale": @3}, // 13 Pro
            @"iPhone15,2": @{@"w": @393, @"h": @852, @"scale": @3}, // 14 Pro
            @"iPhone16,1": @{@"w": @393, @"h": @852, @"scale": @3}, // 15 Pro
            @"iPhone17,1": @{@"w": @402, @"h": @874, @"scale": @3}, // 16 Pro
            // Pro Max
            @"iPhone12,5": @{@"w": @414, @"h": @896, @"scale": @3}, // 11 Pro Max
            @"iPhone13,4": @{@"w": @428, @"h": @926, @"scale": @3}, // 12 Pro Max
            @"iPhone14,3": @{@"w": @428, @"h": @926, @"scale": @3}, // 13 Pro Max
            @"iPhone15,3": @{@"w": @430, @"h": @932, @"scale": @3}, // 14 Pro Max
            @"iPhone16,2": @{@"w": @430, @"h": @932, @"scale": @3}, // 15 Pro Max
            @"iPhone17,2": @{@"w": @440, @"h": @956, @"scale": @3}, // 16 Pro Max
            // iPad
            @"iPad16,3": @{@"w": @834, @"h": @1194, @"scale": @2},
            @"iPad16,4": @{@"w": @1024, @"h": @1366, @"scale": @2},
            @"iPad14,8": @{@"w": @820, @"h": @1180, @"scale": @2},
            @"iPad14,10": @{@"w": @1024, @"h": @1366, @"scale": @2},
            @"iPad13,18": @{@"w": @820, @"h": @1180, @"scale": @2},
            @"iPad14,1": @{@"w": @744, @"h": @1133, @"scale": @2},
        };
    });
    return map[productType];
}

+ (uint64_t)memoryBytesForProductType:(NSString *)productType {
    if (!productType.length) return 6ULL * 1024 * 1024 * 1024;
    // Rough retail RAM
    if ([productType hasPrefix:@"iPad16,"] || [productType hasPrefix:@"iPad14,8"] || [productType hasPrefix:@"iPad14,10"]) {
        return 8ULL * 1024 * 1024 * 1024;
    }
    if ([productType isEqualToString:@"iPhone16,1"] || [productType isEqualToString:@"iPhone16,2"] ||
        [productType isEqualToString:@"iPhone17,1"] || [productType isEqualToString:@"iPhone17,2"]) {
        return 8ULL * 1024 * 1024 * 1024;
    }
    if ([productType hasPrefix:@"iPhone15,2"] || [productType hasPrefix:@"iPhone15,3"] ||
        [productType hasPrefix:@"iPhone14,2"] || [productType hasPrefix:@"iPhone14,3"]) {
        return 6ULL * 1024 * 1024 * 1024;
    }
    if ([productType isEqualToString:@"iPhone14,6"] || [productType isEqualToString:@"iPhone12,8"]) {
        return 4ULL * 1024 * 1024 * 1024;
    }
    return 6ULL * 1024 * 1024 * 1024;
}

+ (uint64_t)diskBytesForProductType:(NSString *)productType {
    (void)productType;
    // Common retail capacities weighted toward 128/256
    static uint64_t options[] = {
        128ULL * 1000 * 1000 * 1000,
        256ULL * 1000 * 1000 * 1000,
        256ULL * 1000 * 1000 * 1000,
        512ULL * 1000 * 1000 * 1000,
    };
    return options[arc4random_uniform(4)];
}

@end
