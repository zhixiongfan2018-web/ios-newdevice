#import "EnvSelectViewController.h"
#import "NDTheme.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"

@interface EnvSelectViewController ()
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic, copy, nullable) NSString *picked; // nil = 新建; @"" = none yet; else record name
@property (nonatomic, assign) BOOL createNew;
@end

@implementation EnvSelectViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *n in [[NDRecordStore shared] allRecordNames]) {
            if ([n isEqualToString:@"原始机器"]) continue;
            [names addObject:n];
        }
        _names = names;
        _createNew = YES; // default: 新建
        _picked = nil;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择环境";
    self.view.backgroundColor = [NDTheme canvas];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"一键新机" style:UIBarButtonItemStyleDone target:self action:@selector(confirm)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirm {
    if (!self.createNew && !self.picked.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"请先选中一个环境"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    void (^cb)(NSString *) = self.onPick;
    NSString *name = self.createNew ? nil : self.picked;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(name);
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.names.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"新建" : (self.names.count ? @"已有环境（选中后刷新身份）" : nil);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"必须选中「新建」或某一个已有环境，再点右上角一键新机。已有环境会保留备注与名称，重新生成参数并清目标 App。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    cell.tintColor = [NDTheme accent];

    if (indexPath.section == 0) {
        cell.textLabel.text = @"新建环境";
        cell.detailTextLabel.text = @"生成全新记录并自动选中";
        cell.accessoryType = self.createNew ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    NSString *name = self.names[indexPath.row];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    cell.textLabel.text = p.remark.length ? p.remark : name;
    cell.detailTextLabel.text = p.remark.length
        ? [NSString stringWithFormat:@"%@ · iOS %@", name, p.SystemVer ?: @"-"]
        : [NSString stringWithFormat:@"%@ · iOS %@", p.Model ?: @"-", p.SystemVer ?: @"-"];
    BOOL on = !self.createNew && [self.picked isEqualToString:name];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        self.createNew = YES;
        self.picked = nil;
    } else {
        self.createNew = NO;
        self.picked = self.names[indexPath.row];
    }
    [tableView reloadData];
}

@end
