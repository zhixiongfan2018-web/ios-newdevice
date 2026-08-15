#import "ProbeViewController.h"
#import "NDTheme.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDPaths.h"
#import "NDIfaddrsFingerprint.h"
#import <AdSupport/AdSupport.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <dlfcn.h>

@implementation ProbeViewController {
    NSArray<NSArray<NSString *> *> *_rows;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本机探测";
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    [self reload];
}

- (NSString *)en0IPv4 {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return @"-";
    NSString *ip = @"-";
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || strcmp(ifa->ifa_name, "en0") != 0) continue;
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, buf, sizeof(buf));
        ip = @(buf);
        break;
    }
    freeifaddrs(list);
    return ip;
}

- (NSString *)gestaltString:(NSString *)key {
    void *g = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!g) return @"-";
    CFTypeRef (*MGCopyAnswer)(CFStringRef) = dlsym(g, "MGCopyAnswer");
    if (!MGCopyAnswer || !key.length) return @"-";
    CFTypeRef v = MGCopyAnswer((__bridge CFStringRef)key);
    if (!v) return @"-";
    NSString *s = [(__bridge id)v description];
    CFRelease(v);
    return s ?: @"-";
}

- (void)reload {
    UIDevice *dev = UIDevice.currentDevice;
    NSString *idfa = ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString ?: @"--";
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"--";
    char machine[256] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    struct timeval boot = {0};
    size_t bootLen = sizeof(boot);
    sysctlbyname("kern.boottime", &boot, &bootLen, NULL, 0);

    CTTelephonyNetworkInfo *info = [CTTelephonyNetworkInfo new];
    CTCarrier *carrier = nil;
    if (@available(iOS 12.0, *)) {
        carrier = info.serviceSubscriberCellularProviders.allValues.firstObject;
    }
    if (!carrier) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        carrier = info.subscriberCellularProvider;
#pragma clang diagnostic pop
    }

    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    NSDictionary *ifa = [NDIfaddrsFingerprint loadForRecord:p.name];
    NSArray *dns = [ifa[@"dns"] isKindOfClass:[NSArray class]] ? ifa[@"dns"] : @[];

    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    uint64_t disk = [fs[NSFileSystemSize] unsignedLongLongValue];
    uint64_t mem = 0;
    size_t memLen = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &memLen, NULL, 0);

    // NewDevice.app is RejectListed — ASIdentifierManager here is the REAL device IDFA.
    // Show environment IDFA from the active profile as the source of truth for spoof.
    NSString *envIDFA = p.IDFA.length ? p.IDFA : @"—";
    NSString *envIDFV = p.IDFV.length ? p.IDFV : @"—";
    BOOL zeroLive = [idfa hasPrefix:@"00000000-0000-0000-0000"];

    _rows = @[
        @[@"记录", p.name ?: @"-"],
        @[@"设备名", dev.name ?: @""],
        @[@"Model", dev.model ?: @""],
        @[@"系统版本", dev.systemVersion ?: @""],
        @[@"Locale", [NSLocale currentLocale].localeIdentifier ?: @"-"],
        @[@"语言", [[NSLocale preferredLanguages] componentsJoinedByString:@", "] ?: @"-"],
        @[@"时区", [NSTimeZone localTimeZone].name ?: @"-"],
        @[@"IDFA(环境)", envIDFA],
        @[@"IDFV(环境)", envIDFV],
        @[@"IDFA(本机未注入)", zeroLive ? [NSString stringWithFormat:@"%@ (ATT关/零)", idfa] : idfa],
        @[@"IDFV(本机未注入)", idfv],
        @[@"UUID(profile)", p.UUID ?: @"-"],
        @[@"OpenUDID(profile)", p.OpenUDID ?: @"-"],
        @[@"DeviceToken(profile)", p.DeviceToken.length ? p.DeviceToken : @"-"],
        @[@"Serial(MG)", [self gestaltString:@"SerialNumber"]],
        @[@"UDID(MG)", [self gestaltString:@"UniqueDeviceID"]],
        @[@"IMEI(MG)", [self gestaltString:@"InternationalMobileEquipmentIdentity"]],
        @[@"WifiAddress(MG)", [self gestaltString:@"WifiAddress"]],
        @[@"hw.machine", [NSString stringWithUTF8String:machine] ?: @""],
        @[@"kern.boottime", [NSString stringWithFormat:@"%ld", (long)boot.tv_sec]],
        @[@"运营商", carrier.carrierName ?: @""],
        @[@"MCC / MNC", [NSString stringWithFormat:@"%@ / %@", carrier.mobileCountryCode ?: @"-", carrier.mobileNetworkCode ?: @"-"]],
        @[@"无线接入", info.currentRadioAccessTechnology ?: @"-"],
        @[@"en0 IPv4", [self en0IPv4]],
        @[@"DNS(record)", dns.count ? [dns componentsJoinedByString:@", "] : @"-"],
        @[@"磁盘(NSFileSystem)", [NSString stringWithFormat:@"%llu", (unsigned long long)disk]],
        @[@"内存(hw.memsize)", [NSString stringWithFormat:@"%llu", (unsigned long long)mem]],
        @[@"亮度", [NSString stringWithFormat:@"%.2f", UIScreen.mainScreen.brightness]],
        @[@"SSID(profile)", p.SSID ?: @"-"],
        @[@"GPS(profile)", [NSString stringWithFormat:@"%.5f, %.5f", p.Latitude, p.Longitude]],
    ];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"环境参数来自当前记录；「本机未注入」= NewDevice App 本身不加载 Tweak";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _rows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.font = [NDTheme captionFont];
    cell.textLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.text = _rows[indexPath.row][0];
    cell.detailTextLabel.font = [NDTheme monoFont:14];
    cell.detailTextLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = _rows[indexPath.row][1];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
