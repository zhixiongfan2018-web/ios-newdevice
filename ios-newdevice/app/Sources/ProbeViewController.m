#import "ProbeViewController.h"
#import <AdSupport/AdSupport.h>
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/sysctl.h>

@implementation ProbeViewController {
    NSArray<NSArray<NSString *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本机探测";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
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
    CTCarrier *carrier = info.serviceSubscriberCellularProviders.allValues.firstObject ?: info.subscriberCellularProvider;
    _rows = @[
        @[@"name", dev.name ?: @""],
        @[@"model", dev.model ?: @""],
        @[@"systemVersion", dev.systemVersion ?: @""],
        @[@"IDFA", idfa],
        @[@"IDFV", idfv],
        @[@"hw.machine", [NSString stringWithUTF8String:machine] ?: @""],
        @[@"carrier", carrier.carrierName ?: @""],
        @[@"MCC/MNC", [NSString stringWithFormat:@"%@/%@", carrier.mobileCountryCode ?: @"-", carrier.mobileNetworkCode ?: @"-"]],
        @[@"radio", info.currentRadioAccessTechnology ?: @"-"],
    ];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _rows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.text = _rows[indexPath.row][0];
    cell.detailTextLabel.text = _rows[indexPath.row][1];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
