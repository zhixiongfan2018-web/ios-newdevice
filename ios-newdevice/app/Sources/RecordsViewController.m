#import "RecordsViewController.h"
#import "NDRecordStore.h"
#import "NDDeviceProfile.h"
#import "NDAPIClient.h"
#import "ProfileDetailViewController.h"

@interface RecordsViewController ()
@property (nonatomic, copy) NSArray<NSString *> *names;
@end

@implementation RecordsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"记录";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.names = [[NDRecordStore shared] allRecordNames];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.names.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *name = self.names[indexPath.row];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    BOOL current = [name isEqualToString:[[NDRecordStore shared] currentRecordName]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@%@%@", current ? @"✓ " : @"", name, p.enabled ? @"" : @" (禁用)"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ | %@", p.Model, p.SystemVer];
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = self.names[indexPath.row];
    [[NDAPIClient shared] call:@"setRecord" query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
        [self reload];
        if (!ok) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"切换失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    }];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:self.names[indexPath.row]];
    [self.navigationController pushViewController:[[ProfileDetailViewController alloc] initWithProfile:p] animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.names[indexPath.row];
    if ([name isEqualToString:@"原始机器"]) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        [[NDAPIClient shared] call:@"deleteRecord" query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
            [self reload];
            completionHandler(YES);
        }];
    }];
    NDDeviceProfile *p = [[NDRecordStore shared] profileNamed:name];
    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:p.enabled ? @"禁用" : @"启用" handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        NSString *fun = p.enabled ? @"disableRecord" : @"enableRecord";
        [[NDAPIClient shared] call:fun query:@{@"recordName": name} completion:^(BOOL ok, NSString *body, NSError *error) {
            [self reload];
            completionHandler(YES);
        }];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, toggle]];
}

@end
