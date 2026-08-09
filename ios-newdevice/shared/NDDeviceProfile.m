#import "NDDeviceProfile.h"
#import "NDDeviceCatalog.h"

static NSString *NDRandomHex(NSUInteger length) {
    static const char *hex = "0123456789ABCDEF";
    NSMutableString *s = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [s appendFormat:@"%c", hex[arc4random_uniform(16)]];
    }
    return s;
}

static NSString *NDRandomUUID(void) {
    return [[NSUUID UUID] UUIDString];
}

static NSString *NDRandomMAC(void) {
    // Locally administered, unicast
    uint8_t bytes[6];
    for (int i = 0; i < 6; i++) bytes[i] = (uint8_t)arc4random_uniform(256);
    bytes[0] = (bytes[0] & 0xFE) | 0x02;
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
}

static NSString *NDRandomSerial(void) {
    static NSString *alphabet = @"CDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity:12];
    for (int i = 0; i < 12; i++) {
        NSUInteger idx = arc4random_uniform((uint32_t)alphabet.length);
        [s appendFormat:@"%C", [alphabet characterAtIndex:idx]];
    }
    return s;
}

static NSString *NDRandomBuild(NSString *systemVer) {
    NSArray *parts = [systemVer componentsSeparatedByString:@"."];
    NSInteger major = parts.count ? [parts[0] integerValue] : 16;
    return [NSString stringWithFormat:@"%ldA%d", (long)(major + 100), arc4random_uniform(900) + 100];
}

@implementation NDDeviceProfile

+ (instancetype)originalProfile {
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = @"原始机器";
    p.enabled = YES;
    p.createdAt = [NSDate date];
    p.IDFA = @"";
    p.IDFV = @"";
    p.UUID = @"";
    p.Serial = @"";
    p.UDID = @"";
    p.WiFiMAC = @"";
    p.BTMAC = @"";
    p.DeviceToken = @"";
    p.Model = @"";
    p.ProductType = @"";
    p.HardwareMachine = @"";
    p.SystemVer = @"";
    p.Build = @"";
    p.Carrier = @"";
    p.MCC = @"";
    p.MNC = @"";
    p.RadioAccess = @"";
    p.Latitude = 0;
    p.Longitude = 0;
    p.Altitude = 10;
    return p;
}

+ (instancetype)randomProfileWithName:(NSString *)name
                       preferredModel:(NSString *)model
                      preferredSystem:(NSString *)systemVer {
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = name;
    p.enabled = YES;
    p.createdAt = [NSDate date];

    NSDictionary *dev = nil;
    NSArray *models = [NDDeviceCatalog deviceModels];
    if (model.length) {
        for (NSDictionary *m in models) {
            if ([m[@"Model"] isEqualToString:model] || [m[@"ProductType"] isEqualToString:model]) {
                dev = m;
                break;
            }
        }
    }
    if (!dev) {
        dev = models[arc4random_uniform((uint32_t)models.count)];
    }

    NSString *sys = systemVer.length ? systemVer : [NDDeviceCatalog systemVersions][arc4random_uniform((uint32_t)[NDDeviceCatalog systemVersions].count)];
    NSDictionary *carrier = [NDDeviceCatalog carriers][arc4random_uniform((uint32_t)[NDDeviceCatalog carriers].count)];
    NSDictionary *coord = [NDDeviceCatalog randomChinaCoordinate];

    p.IDFA = NDRandomUUID();
    p.IDFV = NDRandomUUID();
    p.UUID = NDRandomUUID();
    p.Serial = NDRandomSerial();
    p.UDID = [NDRandomHex(40) lowercaseString];
    p.WiFiMAC = NDRandomMAC();
    p.BTMAC = NDRandomMAC();
    p.DeviceToken = NDRandomHex(64);

    p.Model = dev[@"Model"];
    p.ProductType = dev[@"ProductType"];
    p.HardwareMachine = dev[@"HardwareMachine"];
    p.SystemVer = sys;
    p.Build = NDRandomBuild(sys);

    p.Carrier = carrier[@"Carrier"];
    p.MCC = carrier[@"MCC"];
    p.MNC = carrier[@"MNC"];
    p.RadioAccess = [NDDeviceCatalog radioAccessTypes][arc4random_uniform((uint32_t)[NDDeviceCatalog radioAccessTypes].count)];

    p.Latitude = [coord[@"lat"] doubleValue];
    p.Longitude = [coord[@"lon"] doubleValue];
    p.Altitude = 5.0 + arc4random_uniform(80);
    return p;
}

+ (instancetype)profileFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = dict[@"name"] ?: dict[@"Name"] ?: @"unnamed";
    p.enabled = dict[@"enabled"] ? [dict[@"enabled"] boolValue] : YES;
    id created = dict[@"createdAt"];
    if ([created isKindOfClass:[NSDate class]]) {
        p.createdAt = created;
    } else if ([created isKindOfClass:[NSString class]]) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
        p.createdAt = [f dateFromString:created] ?: [NSDate date];
    } else {
        p.createdAt = [NSDate date];
    }

    p.IDFA = dict[@"IDFA"] ?: @"";
    p.IDFV = dict[@"IDFV"] ?: @"";
    p.UUID = dict[@"UUID"] ?: @"";
    p.Serial = dict[@"Serial"] ?: @"";
    p.UDID = dict[@"UDID"] ?: @"";
    p.WiFiMAC = dict[@"WiFiMAC"] ?: @"";
    p.BTMAC = dict[@"BTMAC"] ?: @"";
    p.DeviceToken = dict[@"DeviceToken"] ?: @"";

    p.Model = dict[@"Model"] ?: @"";
    p.ProductType = dict[@"ProductType"] ?: @"";
    p.HardwareMachine = dict[@"HardwareMachine"] ?: @"";
    p.SystemVer = dict[@"SystemVer"] ?: @"";
    p.Build = dict[@"Build"] ?: @"";

    p.Carrier = dict[@"Carrier"] ?: @"";
    p.MCC = dict[@"MCC"] ?: @"";
    p.MNC = dict[@"MNC"] ?: @"";
    p.RadioAccess = dict[@"RadioAccess"] ?: @"";

    p.Latitude = [dict[@"Latitude"] doubleValue];
    p.Longitude = [dict[@"Longitude"] doubleValue];
    p.Altitude = dict[@"Altitude"] ? [dict[@"Altitude"] doubleValue] : 10;
    return p;
}

+ (instancetype)profileAtPath:(NSString *)path {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return [self profileFromDictionary:dict];
}

- (NSDictionary *)toDictionary {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    return @{
        @"name": self.name ?: @"",
        @"enabled": @(self.enabled),
        @"createdAt": [f stringFromDate:self.createdAt ?: [NSDate date]],
        @"IDFA": self.IDFA ?: @"",
        @"IDFV": self.IDFV ?: @"",
        @"UUID": self.UUID ?: @"",
        @"Serial": self.Serial ?: @"",
        @"UDID": self.UDID ?: @"",
        @"WiFiMAC": self.WiFiMAC ?: @"",
        @"BTMAC": self.BTMAC ?: @"",
        @"DeviceToken": self.DeviceToken ?: @"",
        @"Model": self.Model ?: @"",
        @"ProductType": self.ProductType ?: @"",
        @"HardwareMachine": self.HardwareMachine ?: @"",
        @"SystemVer": self.SystemVer ?: @"",
        @"Build": self.Build ?: @"",
        @"Carrier": self.Carrier ?: @"",
        @"MCC": self.MCC ?: @"",
        @"MNC": self.MNC ?: @"",
        @"RadioAccess": self.RadioAccess ?: @"",
        @"Latitude": @(self.Latitude),
        @"Longitude": @(self.Longitude),
        @"Altitude": @(self.Altitude),
    };
}

- (BOOL)writeToPath:(NSString *)path error:(NSError **)error {
    NSDictionary *dict = [self toDictionary];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
            return NO;
        }
    }
    if (![dict writeToFile:path atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"NDDeviceProfile" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write profile plist"}];
        }
        return NO;
    }
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    return [NDDeviceProfile profileFromDictionary:[self toDictionary]];
}

@end
