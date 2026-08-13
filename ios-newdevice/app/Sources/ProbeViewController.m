#import "ProbeViewController.h"
#import "NDTheme.h"
#import <AdSupport/AdSupport.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>

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
    self.tableView.backgroundColor = [NDTheme canvas];
    self.tableView.separatorColor = [NDTheme hairline];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    [self reload];
}

- (void)reload {
    UIDevice *dev = UIDevice.currentDevice;
    NSString *idfa = ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString ?: @"--";
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"--";
    char machine[256] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
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
    _rows = @[
        @[@"设备名", dev.name ?: @""],
        @[@"Model", dev.model ?: @""],
        @[@"系统版本", dev.systemVersion ?: @""],
        @[@"IDFA", idfa],
        @[@"IDFV", idfv],
        @[@"hw.machine", [NSString stringWithUTF8String:machine] ?: @""],
        @[@"运营商", carrier.carrierName ?: @""],
        @[@"MCC / MNC", [NSString stringWithFormat:@"%@ / %@", carrier.mobileCountryCode ?: @"-", carrier.mobileNetworkCode ?: @"-"]],
        @[@"无线接入", info.currentRadioAccessTechnology ?: @"-"],
    ];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"读取到的实际值（含 Hook 后结果）";
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
