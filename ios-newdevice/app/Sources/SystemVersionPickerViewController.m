#import "SystemVersionPickerViewController.h"
#import "NDDeviceCatalog.h"
#import "NDTheme.h"

@interface SystemVersionPickerViewController ()
@property (nonatomic, copy) NSString *current;
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *sections;
@end

@implementation SystemVersionPickerViewController

- (instancetype)initWithCurrentVersion:(NSString *)current {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _current = current ?: @"";
        self.title = @"选择系统版本";
        [self rebuildSections];
    }
    return self;
}

- (void)rebuildSections {
    NSMutableDictionary<NSString *, NSMutableArray *> *buckets = [NSMutableDictionary dictionary];
    for (NSString *ver in [NDDeviceCatalog systemVersions]) {
        NSString *major = [[ver componentsSeparatedByString:@"."] firstObject] ?: @"?";
        NSString *title = [NSString stringWithFormat:@"iOS %@", major];
        if (!buckets[title]) buckets[title] = [NSMutableArray array];
        [buckets[title] addObject:ver];
    }
    NSArray *titles = [buckets.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a options:NSNumericSearch]; // 18 → 17 → 16
    }];
    NSMutableArray *secs = [NSMutableArray array];
    for (NSString *t in titles) {
        NSArray *vers = [buckets[t] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a compare:b options:NSNumericSearch];
        }];
        [secs addObject:vers];
    }
    self.sectionTitles = titles;
    self.sections = secs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section + 1 == self.sections.count) {
        return @"版本号与 Build 对齐官方公开发布。选定后自动写入 SystemVer + Build。";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"c"];
    NSString *ver = self.sections[indexPath.section][indexPath.row];
    NSString *build = [NDDeviceCatalog buildForSystemVersion:ver];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.textLabel.text = ver;
    cell.detailTextLabel.font = [NDTheme monoFont:13];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = build.length ? build : @"—";
    BOOL on = [ver isEqualToString:self.current];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *ver = self.sections[indexPath.section][indexPath.row];
    NSString *build = [NDDeviceCatalog buildForSystemVersion:ver] ?: @"";
    void (^cb)(NSString *, NSString *) = self.onPick;
    if (cb) cb(ver, build);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
