#import "ProfileDetailViewController.h"
#import "NDRecordStore.h"
#import "NDTheme.h"

@interface ProfileDetailViewController ()
@property (nonatomic, strong) NDDeviceProfile *profile;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *rows;
@end

@implementation ProfileDetailViewController

- (instancetype)initWithProfile:(NDDeviceProfile *)profile {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _profile = profile;
        self.title = profile.name;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [NDTheme canvas];
    self.tableView.backgroundColor = [NDTheme canvas];
    self.tableView.separatorColor = [NDTheme hairline];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [self rebuild];
}

- (void)rebuild {
    NSDictionary *d = [self.profile toDictionary];
    NSArray *keys = @[@"IDFA",@"IDFV",@"UUID",@"Serial",@"UDID",@"WiFiMAC",@"BTMAC",@"DeviceToken",@"Model",@"ProductType",@"HardwareMachine",@"SystemVer",@"Build",@"Carrier",@"MCC",@"MNC",@"RadioAccess",@"Latitude",@"Longitude",@"Altitude"];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *k in keys) {
        [rows addObject:@[k, [NSString stringWithFormat:@"%@", d[k] ?: @""]]];
    }
    self.rows = rows;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"点按任意字段可编辑，完成后点右上角保存。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.font = [NDTheme captionFont];
    cell.textLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.text = self.rows[indexPath.row][0];
    cell.detailTextLabel.font = [NDTheme monoFont:14];
    cell.detailTextLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = self.rows[indexPath.row][1];
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.rows[indexPath.row][0];
    NSString *val = self.rows[indexPath.row][1];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:key message:@"修改参数" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = val; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newVal = a.textFields.firstObject.text ?: @"";
        NSMutableDictionary *d = [[self.profile toDictionary] mutableCopy];
        if ([@[@"Latitude",@"Longitude",@"Altitude"] containsObject:key]) {
            d[key] = @([newVal doubleValue]);
        } else {
            d[key] = newVal;
        }
        self.profile = [NDDeviceProfile profileFromDictionary:d];
        [self rebuild];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)save {
    NSError *err = nil;
    if ([[NDRecordStore shared] saveProfile:self.profile error:&err]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已保存" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end
