#import "ProfileDetailViewController.h"
#import "NDRecordStore.h"
#import "NDTheme.h"
#import "NDDeviceCatalog.h"
#import "SystemVersionPickerViewController.h"

@interface ProfileDetailViewController ()
@property (nonatomic, strong) NDDeviceProfile *profile;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *rows;
@end

@implementation ProfileDetailViewController

- (instancetype)initWithProfile:(NDDeviceProfile *)profile {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _profile = profile;
        self.title = profile.remark.length ? profile.remark : profile.name;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [self rebuild];
}

- (void)rebuild {
    NSDictionary *d = [self.profile toDictionary];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@[ @"备注", self.profile.remark.length ? self.profile.remark : @"" ]];
    NSString *sysDisplay = self.profile.SystemVer ?: @"";
    NSString *officialBuild = [NDDeviceCatalog buildForSystemVersion:sysDisplay];
    if (sysDisplay.length && officialBuild.length) {
        sysDisplay = [NSString stringWithFormat:@"%@ · %@", sysDisplay, officialBuild];
    }
    [rows addObject:@[ @"SystemVer", sysDisplay ]];
    NSArray *keys = @[@"IDFA",@"IDFV",@"UUID",@"IMEI",@"IMEI2",@"ICCID",@"Serial",@"UDID",@"OpenUDID",@"WiFiMAC",@"BTMAC",@"SSID",@"BSSID",@"DeviceToken",@"DeviceColor",@"DiskCapacity",@"PhysicalMemory",@"Brightness",@"BatteryLevel",@"AdvertisingTrackingEnabled",@"Model",@"DeviceName",@"ProductType",@"HardwareMachine",@"Build",@"Carrier",@"MCC",@"MNC",@"RadioAccess",@"TimeZone",@"BootTime",@"Latitude",@"Longitude",@"Altitude"];
    for (NSString *k in keys) {
        [rows addObject:@[k, [NSString stringWithFormat:@"%@", d[k] ?: @""]]];
    }
    self.rows = rows;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"「SystemVer」从官方版本列表选择（自动对齐 Build）。改完点右上角保存。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.font = [NDTheme captionFont];
    cell.textLabel.textColor = [UIColor secondaryLabelColor];
    NSString *key = self.rows[indexPath.row][0];
    cell.textLabel.text = [key isEqualToString:@"SystemVer"] ? @"系统版本" : key;
    cell.detailTextLabel.font = [NDTheme monoFont:14];
    cell.detailTextLabel.textColor = [UIColor labelColor];
    NSString *val = self.rows[indexPath.row][1];
    cell.detailTextLabel.text = val.length ? val : @"（未填写）";
    if (!val.length && ([key isEqualToString:@"备注"] || [key isEqualToString:@"SystemVer"])) {
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        if ([key isEqualToString:@"SystemVer"]) cell.detailTextLabel.text = @"点按选择官方版本";
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.rows[indexPath.row][0];
    NSString *val = self.rows[indexPath.row][1];

    if ([key isEqualToString:@"SystemVer"]) {
        SystemVersionPickerViewController *picker =
            [[SystemVersionPickerViewController alloc] initWithCurrentVersion:self.profile.SystemVer];
        __weak typeof(self) weakSelf = self;
        picker.onPick = ^(NSString *systemVer, NSString *build) {
            weakSelf.profile.SystemVer = systemVer;
            if (build.length) weakSelf.profile.Build = build;
            [weakSelf.profile alignConsistency];
            [weakSelf rebuild];
        };
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }

    BOOL isRemark = [key isEqualToString:@"备注"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:isRemark ? @"备注" : key
                                                               message:isRemark ? @"例如：主号 / 测试号 / 客户名" : @"修改参数"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = isRemark ? (self.profile.remark ?: @"") : ([key isEqualToString:@"SystemVer"] ? self.profile.SystemVer : val);
        if (isRemark) {
            tf.placeholder = @"环境备注";
            tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        }
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newVal = a.textFields.firstObject.text ?: @"";
        if (isRemark) {
            self.profile.remark = newVal;
            [self rebuild];
            return;
        }
        NSMutableDictionary *d = [[self.profile toDictionary] mutableCopy];
        if ([@[@"Latitude",@"Longitude",@"Altitude",@"BootTime",@"DiskCapacity",@"PhysicalMemory",@"Brightness",@"BatteryLevel"] containsObject:key]) {
            d[key] = @([newVal doubleValue]);
        } else if ([key isEqualToString:@"AdvertisingTrackingEnabled"]) {
            d[key] = @([newVal boolValue] || [newVal isEqualToString:@"1"] || [newVal.lowercaseString isEqualToString:@"yes"] || [newVal.lowercaseString isEqualToString:@"true"]);
        } else {
            d[key] = newVal;
        }
        NSString *keptRemark = self.profile.remark ?: @"";
        self.profile = [NDDeviceProfile profileFromDictionary:d];
        self.profile.remark = keptRemark;
        if ([key isEqualToString:@"Build"] || [key isEqualToString:@"SystemVer"]) {
            [self.profile alignConsistency];
        }
        [self rebuild];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)save {
    [self.profile alignConsistency];
    NSError *err = nil;
    if ([[NDRecordStore shared] saveProfile:self.profile error:&err]) {
        [[NDRecordStore shared] notifyReload];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已保存" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end
