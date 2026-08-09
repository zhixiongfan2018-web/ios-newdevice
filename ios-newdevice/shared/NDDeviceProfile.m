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
    // Apple-like 12-char serial alphabet (no ambiguous A/B/I/O).
    static NSString *alphabet = @"CDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity:12];
    for (int i = 0; i < 12; i++) {
        NSUInteger idx = arc4random_uniform((uint32_t)alphabet.length);
        [s appendFormat:@"%C", [alphabet characterAtIndex:idx]];
    }
    return s;
}

static NSString *NDStringFromDict(NSDictionary *dict, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = dict[key];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    }
    return @"";
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
    p.HardwareModel = @"";
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

    // AMG-compatible random pool: preferred model/system if set, else catalog random.
    NSDictionary *dev = [NDDeviceCatalog deviceEntryMatching:model];
    if (!dev) {
        NSArray *models = [NDDeviceCatalog deviceModels];
        dev = models[arc4random_uniform((uint32_t)models.count)];
    }

    NSString *sys = systemVer.length ? systemVer : [NDDeviceCatalog systemVersions][arc4random_uniform((uint32_t)[NDDeviceCatalog systemVersions].count)];
    NSDictionary *carrier = [NDDeviceCatalog carriers][arc4random_uniform((uint32_t)[NDDeviceCatalog carriers].count)];
    NSDictionary *coord = [NDDeviceCatalog randomChinaCoordinate];

    // Identity — same key names AMG scripts read/write (IDFA/IDFV/Serial/UDID/…).
    p.IDFA = NDRandomUUID();
    p.IDFV = NDRandomUUID();
    p.UUID = NDRandomUUID();
    p.Serial = NDRandomSerial();
    p.UDID = [NDRandomHex(40) lowercaseString];
    p.WiFiMAC = NDRandomMAC();
    p.BTMAC = NDRandomMAC();
    p.DeviceToken = NDRandomHex(64);

    p.Model = dev[@"Model"] ?: @"";
    p.ProductType = dev[@"ProductType"] ?: @"";
    p.HardwareMachine = dev[@"HardwareMachine"] ?: p.ProductType;
    p.HardwareModel = dev[@"HardwareModel"] ?: @"";
    p.SystemVer = sys;
    p.Build = [NDDeviceCatalog buildForSystemVersion:sys] ?: @"";

    p.Carrier = carrier[@"Carrier"];
    p.MCC = carrier[@"MCC"];
    p.MNC = carrier[@"MNC"];
    p.RadioAccess = [NDDeviceCatalog radioAccessTypes][arc4random_uniform((uint32_t)[NDDeviceCatalog radioAccessTypes].count)];

    p.Latitude = [coord[@"lat"] doubleValue];
    p.Longitude = [coord[@"lon"] doubleValue];
    p.Altitude = 5.0 + arc4random_uniform(80);
    return p;
}

- (void)syncIdentityFromCatalog {
    // Prefer marketing Model (AMG Set_Device_Model writes only this key).
    NSString *key = self.Model.length ? self.Model : self.ProductType;
    NSDictionary *dev = [NDDeviceCatalog deviceEntryMatching:key];
    if (dev) {
        if (!self.Model.length) self.Model = dev[@"Model"] ?: @"";
        // If Model matches catalog row, always align ProductType / board ids.
        if ([dev[@"Model"] isEqualToString:self.Model] || !self.ProductType.length) {
            self.ProductType = dev[@"ProductType"] ?: self.ProductType;
            self.HardwareMachine = dev[@"HardwareMachine"] ?: self.HardwareMachine;
            self.HardwareModel = dev[@"HardwareModel"] ?: self.HardwareModel;
        } else {
            if (!self.HardwareMachine.length) self.HardwareMachine = dev[@"HardwareMachine"] ?: @"";
            if (!self.HardwareModel.length) self.HardwareModel = dev[@"HardwareModel"] ?: @"";
        }
    }
    if (self.SystemVer.length && !self.Build.length) {
        self.Build = [NDDeviceCatalog buildForSystemVersion:self.SystemVer] ?: self.Build;
    }
}

+ (instancetype)profileFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NDDeviceProfile *p = [NDDeviceProfile new];
    p.name = NDStringFromDict(dict, @[@"name", @"Name"]) ?: @"unnamed";
    if (!p.name.length) p.name = @"unnamed";
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

    // Accept AMG key names + a few common aliases from other tools.
    p.IDFA = NDStringFromDict(dict, @[@"IDFA"]);
    p.IDFV = NDStringFromDict(dict, @[@"IDFV"]);
    p.UUID = NDStringFromDict(dict, @[@"UUID"]);
    p.Serial = NDStringFromDict(dict, @[@"Serial", @"SerialNumber", @"SerialNum"]);
    p.UDID = NDStringFromDict(dict, @[@"UDID"]);
    p.WiFiMAC = NDStringFromDict(dict, @[@"WiFiMAC", @"WifiAddress", @"MAC"]);
    p.BTMAC = NDStringFromDict(dict, @[@"BTMAC", @"BluetoothAddress"]);
    p.DeviceToken = NDStringFromDict(dict, @[@"DeviceToken"]);

    p.Model = NDStringFromDict(dict, @[@"Model", @"DeviceName"]);
    p.ProductType = NDStringFromDict(dict, @[@"ProductType"]);
    p.HardwareMachine = NDStringFromDict(dict, @[@"HardwareMachine"]);
    p.HardwareModel = NDStringFromDict(dict, @[@"HardwareModel"]);
    p.SystemVer = NDStringFromDict(dict, @[@"SystemVer", @"SystemVersion", @"ProductVersion"]);
    p.Build = NDStringFromDict(dict, @[@"Build", @"BuildVersion"]);

    p.Carrier = NDStringFromDict(dict, @[@"Carrier"]);
    p.MCC = NDStringFromDict(dict, @[@"MCC"]);
    p.MNC = NDStringFromDict(dict, @[@"MNC"]);
    p.RadioAccess = NDStringFromDict(dict, @[@"RadioAccess"]);

    id lat = dict[@"Latitude"] ?: dict[@"latitude"];
    id lon = dict[@"Longitude"] ?: dict[@"longitude"];
    id alt = dict[@"Altitude"] ?: dict[@"altitude"];
    p.Latitude = [lat respondsToSelector:@selector(doubleValue)] ? [lat doubleValue] : 0;
    p.Longitude = [lon respondsToSelector:@selector(doubleValue)] ? [lon doubleValue] : 0;
    p.Altitude = alt ? [alt doubleValue] : 10;

    // AMG Set_Device_Model only writes Model — fill ProductType/board ids.
    [p syncIdentityFromCatalog];
    if (p.SystemVer.length && !p.Build.length) {
        p.Build = [NDDeviceCatalog buildForSystemVersion:p.SystemVer] ?: @"";
    }
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
        @"HardwareModel": self.HardwareModel ?: @"",
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
