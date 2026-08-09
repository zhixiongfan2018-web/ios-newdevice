#import "ProbeViewController.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDConfig.h"
#import "NDPaths.h"
#import <AdSupport/AdSupport.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreLocation/CoreLocation.h>
#import <sys/sysctl.h>
#import <dlfcn.h>

typedef CFTypeRef (*NDMGCopyAnswerFunc)(CFStringRef);

@interface NDProbeRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *live;
@property (nonatomic, copy) NSString *expected;
@property (nonatomic, copy) NSString *status; // 生效 / 未生效 / 原始机器 / 跳过
@end
@implementation NDProbeRow
@end

@interface ProbeViewController () <CLLocationManagerDelegate>
@property (nonatomic, copy) NSArray<NDProbeRow *> *rows;
@property (nonatomic, strong) CLLocationManager *locManager;
@property (nonatomic, strong) UILabel *summaryLabel;
@end

@implementation ProbeViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"生效探测";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];

    self.summaryLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 72)];
    self.summaryLabel.numberOfLines = 0;
    self.summaryLabel.textAlignment = NSTextAlignmentCenter;
    self.summaryLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.tableView.tableHeaderView = self.summaryLabel;

    self.locManager = [CLLocationManager new];
    self.locManager.delegate = self;
    if ([self.locManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
        [self.locManager requestWhenInUseAuthorization];
    }
    [self reload];
    [self.locManager requestLocation];
}

- (NSString *)mgString:(NSString *)key {
    static NDMGCopyAnswerFunc fn;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (!gestalt) gestalt = dlopen("/var/jb/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (gestalt) fn = (NDMGCopyAnswerFunc)dlsym(gestalt, "MGCopyAnswer");
    });
    if (!fn) return @"--";
    CFTypeRef ref = fn((__bridge CFStringRef)key);
    if (!ref) return @"--";
    NSString *out = @"--";
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        out = [(__bridge NSString *)ref copy];
    } else if (CFGetTypeID(ref) == CFDataGetTypeID()) {
        NSData *data = (__bridge NSData *)ref;
        const unsigned char *bytes = data.bytes;
        NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
        for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
        out = hex;
    }
    CFRelease(ref);
    return out.length ? out : @"--";
}

- (NDProbeRow *)row:(NSString *)title live:(NSString *)live expected:(NSString *)expected required:(BOOL)required {
    NDProbeRow *r = [NDProbeRow new];
    r.title = title;
    r.live = live.length ? live : @"--";
    r.expected = expected.length ? expected : @"--";
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    BOOL isOriginal = [p.name isEqualToString:@"原始机器"] || p.IDFA.length == 0;
    if (isOriginal) {
        r.status = @"原始机器";
    } else if (!required || !expected.length) {
        r.status = @"跳过";
    } else if ([r.live caseInsensitiveCompare:expected] == NSOrderedSame) {
        r.status = @"生效";
    } else {
        // Allow minor GPS float formatting differences via prefix / numeric compare done by caller.
        r.status = @"未生效";
    }
    return r;
}

- (void)reload {
    [[NDConfig shared] reload];
    NDDeviceProfile *p = [[NDRecordStore shared] currentProfile];
    NDConfig *cfg = [NDConfig shared];
    BOOL isOriginal = [p.name isEqualToString:@"原始机器"] || p.IDFA.length == 0;
    // Same gate as tweak NDTweakState (NewDevice bundle is always a target).
    BOOL spoofing = [cfg isTargetApp:NDBundleID] && !isOriginal && p.enabled;

    UIDevice *dev = UIDevice.currentDevice;
    NSString *idfa = ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString ?: @"--";
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"--";
    char machine[256] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *hw = [NSString stringWithUTF8String:machine] ?: @"";

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

    NSString *radioLive = info.currentRadioAccessTechnology ?: @"-";
    NSString *radioExpected = p.RadioAccess ?: @"";
    if ([radioExpected isEqualToString:@"LTE"]) radioExpected = CTRadioAccessTechnologyLTE ?: @"LTE";
    else if ([radioExpected isEqualToString:@"WCDMA"]) radioExpected = CTRadioAccessTechnologyWCDMA ?: @"WCDMA";
    else if ([radioExpected isEqualToString:@"NR"] || [radioExpected isEqualToString:@"NRNSA"]) {
        radioExpected = @"CTRadioAccessTechnologyNR";
    }

    NSMutableArray<NDProbeRow *> *rows = [NSMutableArray array];
    [rows addObject:[self row:@"IDFA" live:idfa expected:p.IDFA required:YES]];
    [rows addObject:[self row:@"IDFV" live:idfv expected:p.IDFV required:YES]];
    [rows addObject:[self row:@"name(=Model)" live:dev.name expected:cfg.fakeDeviceModel ? p.Model : @"" required:cfg.fakeDeviceModel]];
    [rows addObject:[self row:@"systemVersion" live:dev.systemVersion expected:cfg.fakeSystemVer ? p.SystemVer : @"" required:cfg.fakeSystemVer]];
    [rows addObject:[self row:@"hw.machine" live:hw expected:cfg.fakeDeviceModel ? p.HardwareMachine : @"" required:cfg.fakeDeviceModel]];
    [rows addObject:[self row:@"MG ProductType" live:[self mgString:@"ProductType"] expected:cfg.fakeDeviceModel ? p.ProductType : @"" required:cfg.fakeDeviceModel]];
    [rows addObject:[self row:@"MG HardwareModel" live:[self mgString:@"HardwareModel"] expected:cfg.fakeDeviceModel ? p.HardwareModel : @"" required:cfg.fakeDeviceModel]];
    [rows addObject:[self row:@"MG SerialNumber" live:[self mgString:@"SerialNumber"] expected:p.Serial required:YES]];
    [rows addObject:[self row:@"MG UniqueDeviceID" live:[self mgString:@"UniqueDeviceID"] expected:p.UDID required:YES]];
    [rows addObject:[self row:@"MG UniqueDeviceIDData" live:[self mgString:@"UniqueDeviceIDData"] expected:p.UDID required:YES]];
    [rows addObject:[self row:@"MG WifiAddress" live:[self mgString:@"WifiAddress"] expected:p.WiFiMAC required:YES]];
    [rows addObject:[self row:@"MG BluetoothAddress" live:[self mgString:@"BluetoothAddress"] expected:p.BTMAC required:YES]];
    [rows addObject:[self row:@"MG BuildVersion" live:[self mgString:@"BuildVersion"] expected:cfg.fakeSystemVer ? p.Build : @"" required:cfg.fakeSystemVer]];
    [rows addObject:[self row:@"carrier" live:carrier.carrierName expected:cfg.fakeCarrier ? p.Carrier : @"" required:cfg.fakeCarrier]];
    [rows addObject:[self row:@"MCC" live:carrier.mobileCountryCode expected:cfg.fakeCarrier ? p.MCC : @"" required:cfg.fakeCarrier]];
    [rows addObject:[self row:@"MNC" live:carrier.mobileNetworkCode expected:cfg.fakeCarrier ? p.MNC : @"" required:cfg.fakeCarrier]];
    [rows addObject:[self row:@"radio" live:radioLive expected:cfg.fakeCarrier ? radioExpected : @"" required:cfg.fakeCarrier]];

    CLLocation *loc = self.locManager.location;
    NSString *gpsLive = loc ? [NSString stringWithFormat:@"%.5f,%.5f", loc.coordinate.latitude, loc.coordinate.longitude] : @"--";
    NSString *gpsExpected = (cfg.spoofLocation && (p.Latitude != 0 || p.Longitude != 0))
        ? [NSString stringWithFormat:@"%.5f,%.5f", p.Latitude, p.Longitude] : @"";
    NDProbeRow *gps = [self row:@"GPS" live:gpsLive expected:gpsExpected required:cfg.spoofLocation && gpsExpected.length > 0];
    if (gpsExpected.length && loc &&
        fabs(loc.coordinate.latitude - p.Latitude) < 0.0002 &&
        fabs(loc.coordinate.longitude - p.Longitude) < 0.0002) {
        gps.status = ([p.name isEqualToString:@"原始机器"] || p.IDFA.length == 0) ? @"原始机器" : @"生效";
    }
    [rows addObject:gps];

    self.rows = rows;

    NSInteger ok = 0, bad = 0, skip = 0;
    for (NDProbeRow *r in rows) {
        if ([r.status isEqualToString:@"生效"]) ok++;
        else if ([r.status isEqualToString:@"未生效"]) bad++;
        else skip++;
    }
    NSString *gate = spoofing ? @"Tweak: 应伪装" : @"Tweak: 不伪装";
    if ([p.name isEqualToString:@"原始机器"] || p.IDFA.length == 0) {
        self.summaryLabel.text = [NSString stringWithFormat:@"当前记录：%@\n%@（预期读真实机）", p.name ?: @"--", gate];
        self.summaryLabel.textColor = [UIColor secondaryLabelColor];
    } else if (bad == 0 && ok > 0) {
        self.summaryLabel.text = [NSString stringWithFormat:@"当前记录：%@\n全部生效 %ld 项（跳过 %ld）", p.name, (long)ok, (long)skip];
        self.summaryLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.summaryLabel.text = [NSString stringWithFormat:@"当前记录：%@\n生效 %ld / 未生效 %ld / 跳过 %ld\n%@ — 未勾选目标或开关关闭会导致未生效", p.name, (long)ok, (long)bad, (long)skip, gate];
        self.summaryLabel.textColor = bad ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
    }
    [self.tableView reloadData];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    [self reload];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)error;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"对比「当前记录期望值」与「本进程实时读取」。绿=生效。若未生效：确认已一键新机、本 App/目标 App 已勾选、对应伪装开关已开，并杀进程重开。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NDProbeRow *r = self.rows[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@", r.title, r.status];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"实时: %@\n期望: %@", r.live, r.expected];
    cell.detailTextLabel.numberOfLines = 0;
    if ([r.status isEqualToString:@"生效"]) {
        cell.textLabel.textColor = [UIColor systemGreenColor];
    } else if ([r.status isEqualToString:@"未生效"]) {
        cell.textLabel.textColor = [UIColor systemRedColor];
    } else {
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
