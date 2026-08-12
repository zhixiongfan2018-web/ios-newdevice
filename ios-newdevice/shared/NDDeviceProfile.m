#import "NDDeviceProfile.h"
#import "NDDeviceCatalog.h"
#import "NDDeviceCatalog+Metrics.h"
#import "NDConfig.h"

static NSString *NDRandomHex(NSUInteger length) {
    static const char *hex = "0123456789abcdef";
    NSMutableString *s = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [s appendFormat:@"%c", hex[arc4random_uniform(16)]];
    }
    return s;
}

static NSString *NDRandomUUID(void) {
    return [[NSUUID UUID] UUIDString];
}

/// Apple-assigned OUI prefixes commonly seen on iPhone Wi‑Fi / BT interfaces.
static NSArray<NSString *> *NDAppleOUIs(void) {
    static NSArray<NSString *> *ouis;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ouis = @[
            @"00:1E:C2", @"00:25:00", @"04:0C:CE", @"04:15:52", @"04:26:65",
            @"04:48:9A", @"04:54:53", @"04:DB:56", @"04:E5:36", @"08:66:98",
            @"08:70:45", @"0C:74:C2", @"0C:BC:9F", @"10:1C:0C", @"10:94:BB",
            @"14:10:9F", @"14:20:5E", @"14:7D:DA", @"18:65:90", @"1C:1A:C0",
            @"1C:36:BB", @"20:78:F0", @"24:A0:74", @"24:F0:94", @"28:37:37",
            @"28:6A:BA", @"28:CF:E9", @"2C:1F:23", @"30:90:AB", @"34:15:9E",
            @"34:A3:95", @"38:89:2C", @"3C:07:54", @"40:30:04", @"40:33:1A",
            @"40:A6:D9", @"44:2A:60", @"48:43:7C", @"4C:74:BF", @"50:32:37",
            @"54:26:96", @"54:72:4F", @"58:55:CA", @"5C:8D:4E", @"5C:95:AE",
            @"60:33:4B", @"60:92:17", @"64:A3:CB", @"64:B0:A6", @"68:09:27",
            @"68:96:7B", @"68:D9:3C", @"6C:40:08", @"6C:70:9F", @"6C:72:E7",
            @"70:3E:AC", @"70:48:0F", @"70:DE:E2", @"74:1B:B2", @"78:4F:43",
            @"78:7E:61", @"7C:01:91", @"7C:04:D0", @"7C:11:BE", @"7C:50:49",
            @"80:BE:05", @"80:E6:50", @"84:38:35", @"84:89:AD", @"84:A1:34",
            @"88:63:DF", @"88:66:A5", @"8C:29:37", @"8C:85:90", @"90:27:E4",
            @"90:B0:ED", @"94:BF:2D", @"98:01:A7", @"98:10:E8", @"9C:04:EB",
            @"9C:84:BF", @"9C:F3:87", @"A4:83:E7", @"A4:B1:97", @"A8:60:B6",
            @"A8:BB:CF", @"AC:1F:74", @"AC:87:A3", @"AC:BC:32", @"B0:65:BD",
            @"B4:F0:AB", @"B8:17:C2", @"B8:53:AC", @"B8:63:4D", @"B8:C1:11",
            @"BC:52:B7", @"BC:67:78", @"BC:92:6B", @"C0:A5:3E", @"C8:69:CD",
            @"C8:B5:B7", @"CC:08:E0", @"CC:25:EF", @"D0:03:4B", @"D0:23:DB",
            @"D0:4F:7E", @"D4:61:9D", @"D8:1C:79", @"D8:A2:5E", @"DC:2B:2A",
            @"DC:37:14", @"DC:56:E7", @"E0:33:8E", @"E0:B9:BA", @"E4:CE:8F",
            @"E8:04:0B", @"E8:80:2E", @"EC:35:86", @"F0:18:98", @"F0:99:BF",
            @"F0:DB:E2", @"F4:0F:24", @"F4:F1:5A", @"F8:1E:DF", @"F8:4D:89",
            @"FC:25:3F", @"FC:E9:98",
        ];
    });
    return ouis;
}

static NSString *NDRandomMAC(void) {
    NSString *oui = NDAppleOUIs()[arc4random_uniform((uint32_t)NDAppleOUIs().count)];
    // Globally administered (clear multicast + local bits) — matches real Apple NICs
    uint8_t b3 = (uint8_t)arc4random_uniform(256);
    uint8_t b4 = (uint8_t)arc4random_uniform(256);
    uint8_t b5 = (uint8_t)arc4random_uniform(256);
    return [NSString stringWithFormat:@"%@:%02X:%02X:%02X", oui, b3, b4, b5];
}

/// Modern iPhone serials are typically 10 chars (newer) or 12 chars (legacy).
static NSString *NDRandomSerial(void) {
    static NSString *alpha = @"CDEFGHJKLMNPQRSTUVWXYZ";
    static NSString *alnum = @"CDEFGHJKLMNPQRSTUVWXYZ0123456789";
    NSUInteger len = (arc4random_uniform(100) < 65) ? 10 : 12;
    NSMutableString *s = [NSMutableString stringWithCapacity:len];
    // First char often a letter plant/code hint
    [s appendFormat:@"%C", [alpha characterAtIndex:arc4random_uniform((uint32_t)alpha.length)]];
    for (NSUInteger i = 1; i < len; i++) {
        [s appendFormat:@"%C", [alnum characterAtIndex:arc4random_uniform((uint32_t)alnum.length)]];
    }
    return s;
}

static NSString *NDLuhnCheckDigit(NSString *digits) {
    NSInteger sum = 0;
    BOOL dbl = YES;
    for (NSInteger i = (NSInteger)digits.length - 1; i >= 0; i--) {
        NSInteger d = [digits characterAtIndex:(NSUInteger)i] - '0';
        if (dbl) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
        dbl = !dbl;
    }
    return [NSString stringWithFormat:@"%ld", (long)((10 - (sum % 10)) % 10)];
}

/// Userland IMEI string (15 digits). Not baseband-level; for apps reading Gestalt / CT.
static NSString *NDRandomIMEI(void) {
    static NSArray<NSString *> *tacs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Publicly documented / commonly observed Apple TAC prefixes (8 digits)
        tacs = @[
            @"35391808", @"35433810", @"35693803", @"35326005", @"35929806",
            @"35328509", @"35407110", @"35838708", @"35332210", @"35728009",
            @"35316711", @"35499910", @"35875508", @"35307909", @"35940508",
        ];
    });
    NSString *tac = tacs[arc4random_uniform((uint32_t)tacs.count)];
    NSString *snr = [NSString stringWithFormat:@"%06u", arc4random_uniform(1000000)];
    NSString *body = [tac stringByAppendingString:snr];
    return [body stringByAppendingString:NDLuhnCheckDigit(body)];
}

static NSString *NDRandomOpenUDID(void) {
    return NDRandomHex(40);
}

static NSTimeInterval NDRandomBootTime(void) {
    // Boot sometime in the last 1–14 days
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval ago = 3600.0 + arc4random_uniform(14 * 24 * 3600);
    return now - ago;
}

static NSString *NDRandomBuild(NSString *systemVer) {
    static NSDictionary<NSString *, NSString *> *known;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        known = @{
            // iOS 16
            @"16.0": @"20A362",
            @"16.0.2": @"20A380",
            @"16.1": @"20B82",
            @"16.1.1": @"20B101",
            @"16.1.2": @"20B110",
            @"16.2": @"20C65",
            @"16.3": @"20D47",
            @"16.3.1": @"20D67",
            @"16.4": @"20E247",
            @"16.4.1": @"20E252",
            @"16.5": @"20F66",
            @"16.5.1": @"20F75",
            @"16.6": @"20G75",
            @"16.6.1": @"20G81",
            @"16.7": @"20H19",
            @"16.7.1": @"20H30",
            @"16.7.2": @"20H115",
            @"16.7.5": @"20H307",
            @"16.7.8": @"20H343",
            @"16.7.10": @"20H350",
            // iOS 17
            @"17.0": @"21A329",
            @"17.0.1": @"21A340",
            @"17.0.2": @"21A351",
            @"17.0.3": @"21A360",
            @"17.1": @"21B74",
            @"17.1.1": @"21B91",
            @"17.1.2": @"21B101",
            @"17.2": @"21C62",
            @"17.2.1": @"21C66",
            @"17.3": @"21D50",
            @"17.3.1": @"21D61",
            @"17.4": @"21E219",
            @"17.4.1": @"21E236",
            @"17.5": @"21F79",
            @"17.5.1": @"21F90",
            @"17.6": @"21G80",
            @"17.6.1": @"21G93",
            @"17.7": @"21H16",
            @"17.7.1": @"21H216",
            @"17.7.2": @"21H221",
            // iOS 18
            @"18.0": @"22A3354",
            @"18.0.1": @"22A3370",
            @"18.1": @"22B83",
            @"18.1.1": @"22B91",
            @"18.2": @"22C152",
            @"18.2.1": @"22C161",
            @"18.3": @"22D63",
            @"18.3.1": @"22D72",
            @"18.3.2": @"22D82",
            @"18.4": @"22E240",
            @"18.4.1": @"22E252",
            @"18.5": @"22F76",
        };
    });
    NSString *hit = known[systemVer ?: @""];
    if (hit.length) return hit;

    NSArray *parts = [systemVer componentsSeparatedByString:@"."];
    NSInteger major = parts.count ? [parts[0] integerValue] : 18;
    // iOS N → (N+4)Axxx  (15→19A, 16→20A, 17→21A, 18→22A)
    NSInteger train = major + 4;
    if (train < 19) train = 19;
    return [NSString stringWithFormat:@"%ldA%u", (long)train, 100u + arc4random_uniform(800)];
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
    p.IMEI = @"";
    p.IMEI2 = @"";
    p.SSID = @"";
    p.BSSID = @"";
    p.OpenUDID = @"";
    p.TimeZone = @"";
    p.BootTime = 0;
    p.DeviceColor = @"";
    p.DiskCapacity = 0;
    p.AdvertisingTrackingEnabled = YES;
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
    NSArray *allModels = [NDDeviceCatalog deviceModels];
    BOOL allowPad = [NDConfig shared].allowIPadSpoof;
    NSMutableArray *models = [NSMutableArray array];
    for (NSDictionary *m in allModels) {
        NSString *pt = m[@"ProductType"] ?: @"";
        if (!allowPad && [pt hasPrefix:@"iPad"]) continue;
        [models addObject:m];
    }
    if (!models.count) models = [allModels mutableCopy];

    if (model.length) {
        for (NSDictionary *m in allModels) {
            if ([m[@"Model"] isEqualToString:model] || [m[@"ProductType"] isEqualToString:model]) {
                dev = m;
                break;
            }
        }
    }
    if (!dev) {
        // Bias toward recent devices (14+) without excluding older ones
        NSUInteger biasStart = 0;
        for (NSUInteger i = 0; i < models.count; i++) {
            NSString *pt = models[i][@"ProductType"];
            if ([pt hasPrefix:@"iPhone14,"] || [pt hasPrefix:@"iPhone15,"] ||
                [pt hasPrefix:@"iPhone16,"] || [pt hasPrefix:@"iPhone17,"]) {
                biasStart = i;
                break;
            }
        }
        if (biasStart > 0 && arc4random_uniform(100) < 70) {
            NSUInteger span = models.count - biasStart;
            dev = models[biasStart + arc4random_uniform((uint32_t)span)];
        } else {
            dev = models[arc4random_uniform((uint32_t)models.count)];
        }
    }

    NSArray *systems = [NDDeviceCatalog systemVersions];
    NSString *sys = systemVer;
    if (!sys.length) {
        // Bias toward iOS 17/18 for modern app compatibility
        NSMutableArray *modern = [NSMutableArray array];
        for (NSString *v in systems) {
            if ([v hasPrefix:@"17."] || [v hasPrefix:@"18."]) [modern addObject:v];
        }
        if (modern.count && arc4random_uniform(100) < 75) {
            sys = modern[arc4random_uniform((uint32_t)modern.count)];
        } else {
            sys = systems[arc4random_uniform((uint32_t)systems.count)];
        }
    }
    NSDictionary *carrier = [NDDeviceCatalog carriers][arc4random_uniform((uint32_t)[NDDeviceCatalog carriers].count)];
    NSDictionary *coord = [NDDeviceCatalog randomUSCoordinate];

    p.IDFA = NDRandomUUID();
    p.IDFV = NDRandomUUID();
    p.UUID = NDRandomUUID();
    p.Serial = NDRandomSerial();
    p.UDID = NDRandomHex(40); // lowercase 40-hex, matches Apple UDID style
    p.WiFiMAC = NDRandomMAC();
    p.BTMAC = NDRandomMAC();
    p.DeviceToken = NDRandomHex(64);
    p.IMEI = NDRandomIMEI();
    p.IMEI2 = NDRandomIMEI();
    NSDictionary *wifi = [NDDeviceCatalog randomWiFiNetwork];
    p.SSID = wifi[@"SSID"] ?: @"HomeWiFi";
    p.BSSID = wifi[@"BSSID"] ?: @"00:00:00:00:00:00";
    p.OpenUDID = NDRandomOpenUDID();
    p.BootTime = NDRandomBootTime();
    static NSArray<NSString *> *colors;
    static dispatch_once_t colorOnce;
    dispatch_once(&colorOnce, ^{
        colors = @[@"Black", @"White", @"Blue", @"Pink", @"Yellow", @"Green", @"Purple", @"NaturalTitanium", @"BlueTitanium", @"WhiteTitanium", @"BlackTitanium"];
    });
    p.DeviceColor = colors[arc4random_uniform((uint32_t)colors.count)];
    p.DiskCapacity = [NDDeviceCatalog diskBytesForProductType:dev[@"ProductType"]];
    p.AdvertisingTrackingEnabled = YES;

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
    p.TimeZone = coord[@"timezone"] ?: @"America/New_York";
    // Urban altitude: mostly low buildings / street level
    p.Altitude = 8.0 + (double)arc4random_uniform(120) + ((double)arc4random_uniform(100) / 100.0);
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
    p.IMEI = dict[@"IMEI"] ?: @"";
    p.IMEI2 = dict[@"IMEI2"] ?: @"";
    p.SSID = dict[@"SSID"] ?: @"";
    p.BSSID = dict[@"BSSID"] ?: @"";
    p.OpenUDID = dict[@"OpenUDID"] ?: @"";
    p.TimeZone = dict[@"TimeZone"] ?: @"";
    p.BootTime = dict[@"BootTime"] ? [dict[@"BootTime"] doubleValue] : 0;
    p.DeviceColor = dict[@"DeviceColor"] ?: @"";
    p.DiskCapacity = dict[@"DiskCapacity"] ? [dict[@"DiskCapacity"] unsignedLongLongValue] : 0;
    p.AdvertisingTrackingEnabled = dict[@"AdvertisingTrackingEnabled"] ? [dict[@"AdvertisingTrackingEnabled"] boolValue] : YES;

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
        @"IMEI": self.IMEI ?: @"",
        @"IMEI2": self.IMEI2 ?: @"",
        @"SSID": self.SSID ?: @"",
        @"BSSID": self.BSSID ?: @"",
        @"OpenUDID": self.OpenUDID ?: @"",
        @"TimeZone": self.TimeZone ?: @"",
        @"BootTime": @(self.BootTime),
        @"DeviceColor": self.DeviceColor ?: @"",
        @"DiskCapacity": @(self.DiskCapacity),
        @"AdvertisingTrackingEnabled": @(self.AdvertisingTrackingEnabled),
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
