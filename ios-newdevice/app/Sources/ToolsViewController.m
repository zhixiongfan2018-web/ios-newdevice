#import "ToolsViewController.h"
#import "NDTheme.h"
#import "NDConfig.h"
#import "NDRecordStore.h"
#import "NDRecordStore+ImportExport.h"
#import "NDAppDataManager.h"
#import "NDOperationService.h"
#import "NDAMGParamClient.h"
#import "NDDeviceProfile.h"
#import "NDPaths.h"
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
    [NDPaths ensureDirectories];

    // Keychain always imports with holographic data — no UI toggle.
    NDConfig *c = [NDConfig shared];
    if (!c.importKeychainWithData) {
        c.importKeychainWithData = YES;
        [c save];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"本机数据（爱思）";
    if (section == 1) return @"导入";
    return @"维护";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"导入时自动带上 Keychain。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return 3;
    return 3;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NDConfig *c = [NDConfig shared];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [NDTheme headlineFont];
    cell.detailTextLabel.font = [NDTheme captionFont];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.tintColor = [NDTheme accent];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"导出本机数据";
            cell.detailTextLabel.text = [NSString stringWithFormat:@".tar → %@", [NDPaths mediaExportDir]];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up.on.square"];
        } else {
            cell.textLabel.text = @"导入本机数据";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"从 %@ 读 .tar", [NDPaths mediaImportDir]];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"导入 AMG";
            cell.detailTextLabel.text = @"经典包 → /var/mobile/AMG";
            cell.imageView.image = [UIImage systemImageNamed:@"tray.and.arrow.down"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"导入其他数据";
            cell.detailTextLabel.text = [NDRecordStore iGrimaceImportPath];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
        } else {
            cell.textLabel.text = @"导入 AWZ";
            cell.detailTextLabel.text = [NDRecordStore awzImportPath];
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"];
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"拉取 AMG 明文参数";
            cell.detailTextLabel.text = @"密文 faker 时用：getRecordParam → faker_plaintext.plist";
            cell.imageView.image = [UIImage systemImageNamed:@"key.horizontal"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"瘦身（清除图片、视频）";
            cell.detailTextLabel.text = c.slimExportStripMedia
                ? @"导出时自动瘦身：开（点击立刻瘦身，长按关闭）"
                : @"点击立刻瘦身当前记录；长按开启导出自动清除";
            cell.imageView.image = [UIImage systemImageNamed:@"internaldrive"];
        } else {
            cell.textLabel.text = @"注销桌面";
            cell.detailTextLabel.text = @"killall SpringBoard";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
        }
    }
    return cell;
}

- (void)onLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:p];
    if (!ip || ip.section != 2 || ip.row != 1) return;
    NDConfig *c = [NDConfig shared];
    c.slimExportStripMedia = !c.slimExportStripMedia;
    [c save];
    [self.tableView reloadData];
    [self alert:@"导出自动瘦身" message:c.slimExportStripMedia ? @"已开启：导出时清除图片/视频" : @"已关闭"];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runImportKind:(NSString *)kind path:(NSString *)path {
    // Always import Keychain with holographic data.
    BOOL isAMG = [kind.lowercaseString containsString:@"amg"] || [kind.lowercaseString containsString:@"media"];
    NSString *fun = isAMG ? @"importAMGRecords" : ([kind.lowercaseString containsString:@"awz"] ? @"importAWZ" : @"importIGrimace");
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"正在导入" message:@"请稍候…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:^{
        [[NDOperationService shared] runAsync:fun query:@{@"dir": path ?: @"", @"keychain": @"1"} completion:^(NSString *body, NSInteger code) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [wait dismissViewControllerAnimated:YES completion:^{
                    NSUInteger okN = [NDRecordStore shared].lastImportSuccessCount;
                    NSUInteger failN = [NDRecordStore shared].lastImportFailCount;
                    NSUInteger skipN = [NDRecordStore shared].lastImportSkipCount;
                    NSString *msg = (code == 200 || okN > 0 || skipN > 0)
                        ? [NSString stringWithFormat:@"成功 %lu 个，失败 %lu 个%@",
                           (unsigned long)okN, (unsigned long)failN,
                           skipN ? [NSString stringWithFormat:@"，跳过 %lu 个", (unsigned long)skipN] : @""]
                        : (body.length ? body : @"未找到可导入数据");
                    [self alert:@"导入完成" message:msg];
                }];
            });
        }];
    }];
}

- (void)exportOwnData {
    [NDPaths ensureDirectories];
    NSError *err = nil;
    BOOL slim = [NDConfig shared].slimExportStripMedia;
    NSString *outDir = [NDPaths mediaExportDir];
    NSUInteger n = [[NDRecordStore shared] exportAMGRecordsToDirectory:outDir slim:slim error:&err];
    [self alert:n ? @"导出完成" : @"导出结果"
        message:n ? [NSString stringWithFormat:@"已导出 %lu 条本机数据（.tar）\n\n爱思可见路径：\n%@\n\n另有副本：\n%@", (unsigned long)n, outDir, [NDRecordStore amgMediaExportPath]]
                 : (err.localizedDescription ?: @"没有可导出的记录（请先一键新机生成记录）")];
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

- (void)NDFinishPullWait:(UIAlertController *)wait title:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [wait dismissViewControllerAnimated:YES completion:^{
            [self alert:title message:msg];
        }];
    });
}

- (void)NDRunPullAMGPlaintextNamed:(NSString *)name wait:(UIAlertController *)wait {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dir = [NDRecordStore resolvedAMGImportPath];
        NSString *amgRoot = @"/var/mobile/AMG";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *targetDir = dir;
        if (name.length && [fm fileExistsAtPath:amgRoot]) {
            NSString *direct = [amgRoot stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:direct]) {
                targetDir = direct;
            } else {
                for (NSString *e in [fm contentsOfDirectoryAtPath:amgRoot error:nil] ?: @[]) {
                    if ([e isEqualToString:name] || [e containsString:name] || [name containsString:e]) {
                        targetDir = [amgRoot stringByAppendingPathComponent:e];
                        break;
                    }
                }
            }
        }
        [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *note = nil;
        NSDictionary *plain = [NDAMGParamClient resolvePlaintextParamForAMGRecordDir:targetDir
                                                                        recordTitle:name
                                                                         sourceNote:&note];
        NSString *outPath = [targetDir stringByAppendingPathComponent:@"faker_plaintext.plist"];
        if (plain.count) {
            [plain writeToFile:outPath atomically:YES];
            NDDeviceProfile *p = [NDDeviceProfile profileFromDictionary:plain];
            if (p) {
                NSString *cur = [[NDRecordStore shared] currentRecordName];
                if (cur.length && ![cur isEqualToString:@"原始机器"]) p.name = cur;
                else if (name.length) p.name = name;
                p.spoofDeviceIdentity = YES;
                p.enabled = YES;
                [[NDRecordStore shared] saveProfile:p error:nil];
            }
            NSString *msg = [NSString stringWithFormat:@"已写入明文：\n%@\n来源：%@\n键数：%lu\n\n请再执行「导入 AMG」。",
                             outPath, note ?: @"-", (unsigned long)plain.count];
            [self NDFinishPullWait:wait title:@"拉取完成" message:msg];
        } else {
            NSString *msg = [NSString stringWithFormat:@"未拿到明文。\n%@\n\n做法：AMG 前台选中该记录，用 Get_Param/getRecordParam 写出 plist，保存为该记录目录下 faker_plaintext.plist 后再导入。",
                             note ?: @"-"];
            [self NDFinishPullWait:wait title:@"拉取失败" message:msg];
        }
    });
}

- (void)pullAMGPlaintextParam {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"拉取 AMG 明文参数"
                                                               message:@"调用本机 8080 getRecordParam。需 AMG 前台解密；记录名与 AMG 一致。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"recordName";
        NSString *cur = [[NDRecordStore shared] currentRecordName];
        if (cur.length && ![cur isEqualToString:@"原始机器"]) tf.text = cur;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"拉取" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        __strong typeof(weakSelf) vc = weakSelf;
        if (!vc) return;
        NSString *name = a.textFields.firstObject.text ?: @"";
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"正在拉取" message:@"getRecordParam" preferredStyle:UIAlertControllerStyleAlert];
        [vc presentViewController:wait animated:YES completion:^{
            [vc NDRunPullAMGPlaintextNamed:name wait:wait];
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self exportOwnData];
        else [self runImportKind:@"AMG" path:[NDPaths mediaImportDir]];
        return;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self runImportKind:@"AMG" path:[NDRecordStore resolvedAMGImportPath]];
        else if (indexPath.row == 1) [self runImportKind:@"iGrimace" path:[NDRecordStore iGrimaceImportPath]];
        else [self runImportKind:@"AWZ" path:[NDRecordStore awzImportPath]];
        return;
    }

    if (indexPath.row == 0) {
        [self pullAMGPlaintextParam];
    } else if (indexPath.row == 1) {
        NSString *name = [[NDRecordStore shared] currentRecordName];
        if (!name.length || [name isEqualToString:@"原始机器"]) {
            [self alert:@"无法瘦身" message:@"请先切换到非「原始机器」记录"];
            return;
        }
        NSUInteger n = [[NDAppDataManager shared] slimMediaInRecord:name];
        [self alert:@"瘦身完成" message:[NSString stringWithFormat:@"已从「%@」清除 %lu 个图片/视频文件", name, (unsigned long)n]];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销桌面" message:@"将重启 SpringBoard，是否继续？" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self respring];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
