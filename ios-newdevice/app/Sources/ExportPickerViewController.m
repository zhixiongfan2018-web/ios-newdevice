#import "ExportPickerViewController.h"
#import "NDTheme.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"

@interface ExportPickerViewController ()
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@end

@implementation ExportPickerViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *n in [[NDRecordStore shared] allRecordNames]) {
            if ([n isEqualToString:@"原始机器"]) continue;
            [names addObject:n];
        }
        _names = names;
        _selected = [NSMutableSet setWithArray:names];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择环境";
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStyleDone target:self action:@selector(doExport)];
    UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
    UIBarButtonItem *none = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(selectNone)];
    self.toolbarItems = @[all, [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], none];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)selectAll {
    [self.selected addObjectsFromArray:self.names];
    [self.tableView reloadData];
}

- (void)selectNone {
    [self.selected removeAllObjects];
    [self.tableView reloadData];
}

- (void)doExport {
    if (!self.selected.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"请先勾选环境" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSMutableArray *picked = [NSMutableArray array];
    for (NSString *n in self.names) {
        if ([self.selected containsObject:n]) [picked addObject:n];
    }
    void (^cb)(NSArray *) = self.onExport;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(picked);
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.names.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"导出 NewDevice 环境（含 AMG 导入后的 App 沙盒与参数）。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *name = self.names[indexPath.row];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.textLabel.text = p.remark.length ? p.remark : name;
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    NSUInteger apps = [[NDRecordStore shared] appBundleIdsForRecord:name].count;
    if (p.remark.length) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@ · apps:%lu", name, p.Model ?: @"-", (unsigned long)apps];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · iOS %@ · apps:%lu", p.Model ?: @"-", p.SystemVer ?: @"-", (unsigned long)apps];
    }
    cell.accessoryType = [self.selected containsObject:name] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [NDTheme accent];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = self.names[indexPath.row];
    if ([self.selected containsObject:name]) [self.selected removeObject:name];
    else [self.selected addObject:name];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
