#import "SettingsViewController.h"
#import "NDConfig.h"
#import "NDTheme.h"
#import "CatalogPickerViewController.h"

typedef NS_ENUM(NSInteger, NDSettingRow) {
    NDSettingFakeModel = 0,
    NDSettingFakeSystem,
    NDSettingFakeCarrier,
    NDSettingSpoofLocation,
    NDSettingRandomLocation,
    NDSettingSmartOffset,
    NDSettingSmartAirplane,
    NDSettingAllowIPad,
    NDSettingClearPasteboard,
    NDSettingJBBasic,
    NDSettingJBDeep,
    NDSettingHolo,
    NDSettingCount
};

@implementation SettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = [NDTheme canvas];
    self.tableView.backgroundColor = [NDTheme canvas];
    self.tableView.separatorColor = [NDTheme hairline];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [[NDConfig shared] reload];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"功能开关";
    if (section == 1) return @"随机池";
    return @"说明";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return NDSettingCount;
    if (section == 1) return 2;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.font = [NDTheme headlineFont];
        cell.textLabel.text = @"使用提示";
        cell.detailTextLabel.font = [NDTheme bodyFont];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = @"深度防越狱可能闪退。\nAPI：http://127.0.0.1:8080/cmd?fun=newRecord\n额外：prevRecord / clearAppData / getRecordCount";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.font = [NDTheme headlineFont];
        cell.detailTextLabel.font = [NDTheme captionFont];
        cell.detailTextLabel.textColor = [NDTheme accent];
        NDConfig *c = [NDConfig shared];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"机型池";
            cell.imageView.image = [UIImage systemImageNamed:@"iphone"];
            cell.detailTextLabel.text = c.preferredModels.count ? [NSString stringWithFormat:@"%lu 项", (unsigned long)c.preferredModels.count] : @"全部";
        } else {
            cell.textLabel.text = @"系统版本池";
            cell.imageView.image = [UIImage systemImageNamed:@"gear"];
            cell.detailTextLabel.text = c.preferredSystems.count ? [NSString stringWithFormat:@"%lu 项", (unsigned long)c.preferredSystems.count] : @"全部";
        }
        cell.imageView.tintColor = [NDTheme accent];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"s"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [UISwitch new];
    sw.onTintColor = [NDTheme accent];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    NDConfig *c = [NDConfig shared];
    NSArray *titles = @[
        @"伪装设备机型", @"伪装系统版本", @"伪装运营商", @"伪装定位", @"随机位置",
        @"智能偏移位置", @"智能飞行模式", @"允许伪装 iPad", @"切换时清空剪贴板",
        @"基础防越狱检测", @"深度防越狱检测", @"全息备份"
    ];
    NSArray *subs = @[
        @"ProductType / 分辨率 / 内存", @"UIDevice systemVersion", @"运营商 / ISO us", @"CLLocation + 时区", @"一键新机随机美国城市",
        @"在基准点附近微调", @"切换身份时开关飞行", @"随机池包含 iPad（默认关）", @"一键新机/切换记录时清空",
        @"隐藏路径 + URL Scheme", @"dyld / getenv / fork", @"按记录备份目标 App 数据"
    ];
    NSArray *values = @[
        @(c.fakeDeviceModel), @(c.fakeSystemVer), @(c.fakeCarrier), @(c.spoofLocation), @(c.randomLocation),
        @(c.smartLocationOffset), @(c.smartAirplane), @(c.allowIPadSpoof), @(c.clearPasteboardOnSwitch),
        @(c.jailbreakHideBasic), @(c.jailbreakHideDeep), @(c.holographicBackup)
    ];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.textLabel.text = titles[indexPath.row];
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = subs[indexPath.row];
    sw.on = [values[indexPath.row] boolValue];
    cell.accessoryView = sw;
    return cell;
}

- (void)toggle:(UISwitch *)sw {
    NDConfig *c = [NDConfig shared];
    switch ((NDSettingRow)sw.tag) {
        case NDSettingFakeModel: c.fakeDeviceModel = sw.on; break;
        case NDSettingFakeSystem: c.fakeSystemVer = sw.on; break;
        case NDSettingFakeCarrier: c.fakeCarrier = sw.on; break;
        case NDSettingSpoofLocation: c.spoofLocation = sw.on; break;
        case NDSettingRandomLocation: c.randomLocation = sw.on; break;
        case NDSettingSmartOffset: c.smartLocationOffset = sw.on; break;
        case NDSettingSmartAirplane: c.smartAirplane = sw.on; break;
        case NDSettingAllowIPad: c.allowIPadSpoof = sw.on; break;
        case NDSettingClearPasteboard: c.clearPasteboardOnSwitch = sw.on; break;
        case NDSettingJBBasic: c.jailbreakHideBasic = sw.on; break;
        case NDSettingJBDeep: c.jailbreakHideDeep = sw.on; break;
        case NDSettingHolo: c.holographicBackup = sw.on; break;
        default: break;
    }
    [c save];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NDCatalogPickerKind kind = indexPath.row == 0 ? NDCatalogPickerModels : NDCatalogPickerSystems;
    [self.navigationController pushViewController:[[CatalogPickerViewController alloc] initWithKind:kind] animated:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NDConfig shared] reload];
    [self.tableView reloadData];
}

@end
