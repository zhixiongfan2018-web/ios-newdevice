#import "ToolsViewController.h"
#import "NDTheme.h"
#import "NDConfig.h"
#import "NDRecordStore.h"
#import "NDRecordStore+ImportExport.h"
#import "NDAppDataManager.h"
#import "NDPaths.h"
#import "ProbeViewController.h"
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@implementation ToolsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"工具";
    self.view.backgroundColor = [NDTheme canvas];
    self.tableView.backgroundColor = [NDTheme canvas];
    self.tableView.separatorColor = [NDTheme hairline];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.tableView addGestureRecognizer:lp];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"其他数据导入";
    if (section == 1) return @"AMG 数据导入与导出";
    return @"实用工具";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return 3;
    return 4;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NDConfig *c = [NDConfig shared];
    if (indexPath.section == 0 && indexPath.row == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.font = [NDTheme headlineFont];
        cell.textLabel.text = @"同时导入 Keychain";
        cell.detailTextLabel.font = [NDTheme captionFont];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = @"导入时暂存钥匙串；切换记录时再写入系统 Keychain";
        UISwitch *sw = [UISwitch new];
        sw.onTintColor = [NDTheme accent];
        sw.on = c.importKeychainWithData;
        [sw addTarget:self action:@selector(toggleKeychain:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.tintColor = [NDTheme accent];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"导入其他数据";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"路径: %@", [NDRecordStore iGrimaceImportPath]];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
        } else {
            cell.textLabel.text = @"导入 AWZ 数据";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"路径: %@", [NDRecordStore awzImportPath]];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"导入 AMG 数据";
            cell.detailTextLabel.text = @"放 .tar 到 /var/mobile/Media/AMG/import（或 AMG_tar）";
            cell.imageView.image = [UIImage systemImageNamed:@"tray.and.arrow.down"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"导出 AMG 数据";
            cell.detailTextLabel.text = @"导出为 .tar → Media/AMG/export 与 AMG_tar";
            cell.imageView.image = [UIImage systemImageNamed:@"tray.and.arrow.up"];
        } else {
            cell.textLabel.text = @"瘦身（清除图片、视频）";
            cell.detailTextLabel.text = c.slimExportStripMedia
                ? @"导出时自动瘦身：开（点击立刻瘦身，长按关闭）"
                : @"点击立刻瘦身当前记录；长按开启导出自动清除";
            cell.imageView.image = [UIImage systemImageNamed:@"internaldrive"];
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"修复不能输入中文";
            cell.detailTextLabel.text = @"清理键盘缓存后注销桌面";
            cell.imageView.image = [UIImage systemImageNamed:@"keyboard"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"修复国行机源不能联网";
            cell.detailTextLabel.text = @"Dopamine/Sileo：无线局域网与蜂窝数据 / 还原网络设置";
            cell.imageView.image = [UIImage systemImageNamed:@"wifi.exclamationmark"];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"注销（重启桌面）";
            cell.detailTextLabel.text = @"killall SpringBoard";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
        } else {
            cell.textLabel.text = @"脚本和使用说明";
            cell.detailTextLabel.text = @"打开探针 / API 说明";
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
        }
    }
    return cell;
}

- (void)toggleKeychain:(UISwitch *)sw {
    [NDConfig shared].importKeychainWithData = sw.on;
    [[NDConfig shared] save];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:p];
    if (!ip || ip.section != 1 || ip.row != 2) return;
    NDConfig *c = [NDConfig shared];
    c.slimExportStripMedia = !c.slimExportStripMedia;
    [c save];
    [self.tableView reloadData];
    [self alert:@"导出自动瘦身" message:c.slimExportStripMedia ? @"已开启：导出 AMG 时清除图片/视频" : @"已关闭"];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runImportKind:(NSString *)kind path:(NSString *)path {
    NSError *err = nil;
    BOOL kc = [NDConfig shared].importKeychainWithData;
    NSUInteger n = [[NDRecordStore shared] importForeignRecordsFromDirectory:path kind:kind importKeychain:kc error:&err];
    NSString *msg = n
        ? [NSString stringWithFormat:@"已导入 %lu 条（Keychain：%@）\n%@", (unsigned long)n, kc ? @"开" : @"关", path]
        : (err.localizedDescription ?: @"未找到可导入数据");
    [self alert:n ? @"导入完成" : @"导入结果" message:msg];
}

- (void)respring {
    pid_t pid = 0;
    char *argv[] = { "/var/jb/usr/bin/killall", "-9", "SpringBoard", NULL };
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) {
        char *argv2[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
        posix_spawn(&pid, argv2[0], NULL, NULL, argv2, environ);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

- (void)fixChineseInput {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/var/mobile/Library/Keyboard",
        @"/var/mobile/Library/Preferences/com.apple.keyboard.plist",
        @"/var/mobile/Library/Preferences/com.apple.TextInput.plist",
    ];
    for (NSString *p in paths) {
        if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
    }
    [self alert:@"已清理键盘缓存" message:@"即将注销桌面，请稍后重试中文输入"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self respring];
    });
}

- (void)fixRepoNetwork {
    [self alert:@"国行联网提示" message:@"1. 设置 → 蜂窝网络 → 打开 Sileo/NewDevice 的无线局域网与蜂窝数据\n2. 若仍失败：设置 → 通用 → 传输或还原 iPhone → 还原 → 还原网络设置\n3. 本环境为 Dopamine，无需 Cydia 专项补丁"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 2) return;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [self runImportKind:@"iGrimace" path:[NDRecordStore iGrimaceImportPath]];
        } else {
            [self runImportKind:@"AWZ" path:[NDRecordStore awzImportPath]];
        }
        return;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            [self runImportKind:@"AMG" path:[NDRecordStore resolvedAMGImportPath]];
        } else if (indexPath.row == 1) {
            NSError *err = nil;
            BOOL slim = [NDConfig shared].slimExportStripMedia;
            NSString *outDir = [NDRecordStore amgTarPath];
            NSUInteger n = [[NDRecordStore shared] exportAMGRecordsToDirectory:outDir slim:slim error:&err];
            [self alert:n ? @"导出完成" : @"导出结果"
                message:n ? [NSString stringWithFormat:@"已导出 %lu 条 .tar\n%@\n兼复制到\n%@\n瘦身：%@", (unsigned long)n, outDir, [NDRecordStore amgMediaExportPath], slim ? @"开" : @"关"]
                         : (err.localizedDescription ?: @"没有可导出的记录")];
        } else {
            NSString *name = [[NDRecordStore shared] currentRecordName];
            if (!name.length || [name isEqualToString:@"原始机器"]) {
                [self alert:@"无法瘦身" message:@"请先切换到非「原始机器」记录"];
                return;
            }
            NSUInteger n = [[NDAppDataManager shared] slimMediaInRecord:name];
            [self alert:@"瘦身完成" message:[NSString stringWithFormat:@"已从「%@」清除 %lu 个图片/视频文件", name, (unsigned long)n]];
        }
        return;
    }

    if (indexPath.row == 0) [self fixChineseInput];
    else if (indexPath.row == 1) [self fixRepoNetwork];
    else if (indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销桌面" message:@"将重启 SpringBoard，是否继续？" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self respring];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.navigationController pushViewController:[ProbeViewController new] animated:YES];
    }
}

@end
