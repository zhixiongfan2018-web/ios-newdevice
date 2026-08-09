#import "CatalogPickerViewController.h"
#import "NDConfig.h"
#import "NDDeviceCatalog.h"

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
    return @"不选则从全部列表随机。多选时一键新机从池中随机。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    NSString *opt = self.options[indexPath.row];
    cell.textLabel.text = opt;
    cell.accessoryType = [self.selected containsObject:opt] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
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
