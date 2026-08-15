#import "CatalogPickerViewController.h"
#import "NDConfig.h"
#import "NDDeviceCatalog.h"
#import "NDTheme.h"

@interface CatalogPickerViewController ()
@property (nonatomic, assign) NDCatalogPickerKind kind;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@end

@implementation CatalogPickerViewController

- (instancetype)initWithKind:(NDCatalogPickerKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _kind = kind;
        self.title = kind == NDCatalogPickerModels ? @"随机机型池" : @"随机系统池";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [[NDConfig shared] reload];
    if (self.kind == NDCatalogPickerModels) {
        NSMutableArray *opts = [NSMutableArray array];
        for (NSDictionary *m in [NDDeviceCatalog deviceModels]) {
            [opts addObject:m[@"Model"]];
        }
        self.options = opts;
        self.selected = [NSMutableSet setWithArray:[NDConfig shared].preferredModels ?: @[]];
    } else {
        self.options = [NDDeviceCatalog systemVersions];
        self.selected = [NSMutableSet setWithArray:[NDConfig shared].preferredSystems ?: @[]];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
}

- (void)save {
    if (self.kind == NDCatalogPickerModels) {
        [NDConfig shared].preferredModels = self.selected.allObjects;
    } else {
        [NDConfig shared].preferredSystems = self.selected.allObjects;
    }
    [[NDConfig shared] save];
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.options.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"不选则从全部官方版本随机。多选时一键新机从池中抽；版本与 Build 已对齐。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *opt = self.options[indexPath.row];
    BOOL on = [self.selected containsObject:opt];
    cell.textLabel.font = [NDTheme bodyFont];
    cell.textLabel.text = opt;
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (self.kind == NDCatalogPickerSystems) {
        NSString *build = [NDDeviceCatalog buildForSystemVersion:opt];
        cell.detailTextLabel.text = build.length ? [NSString stringWithFormat:@"Build %@", build] : @"官方版本";
    } else {
        cell.detailTextLabel.text = nil;
    }
    cell.imageView.image = [UIImage systemImageNamed:on ? @"checkmark.circle.fill" : @"circle"];
    cell.imageView.tintColor = on ? [NDTheme accent] : [UIColor tertiaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *opt = self.options[indexPath.row];
    if ([self.selected containsObject:opt]) [self.selected removeObject:opt];
    else [self.selected addObject:opt];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
