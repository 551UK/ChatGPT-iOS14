#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static IMP CGOriginalSettingsFooter = NULL;
static IMP CGOriginalSettingsCell = NULL;

static NSString *CGSettingsFooter(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (section == 0) return @"The API key is only used by the optional Native Chat section. ChatGPT Web is the default and uses your normal ChatGPT account through Gecko with no API key.";
    if (section == 3) return @"ChatGPT Web uses the bundled Gecko engine instead of iOS 14 WebKit. Native API chats are stored locally on this device.";
    if (CGOriginalSettingsFooter) return ((NSString *(*)(id, SEL, UITableView *, NSInteger))CGOriginalSettingsFooter)(self, _cmd, tableView, section);
    return nil;
}

static UITableViewCell *CGSettingsCell(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = CGOriginalSettingsCell ? ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))CGOriginalSettingsCell)(self, _cmd, tableView, indexPath) : nil;
    if (indexPath.section == 3 && indexPath.row == 2) cell.detailTextLabel.text = @"Gecko Web + Native API";
    return cell;
}

__attribute__((constructor))
static void CGInstallSettingsPatch(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.551.chatgpt14"]) return;
        Class cls = NSClassFromString(@"CGSettingsViewController");
        if (!cls) return;

        SEL footerSel = @selector(tableView:titleForFooterInSection:);
        Method footer = class_getInstanceMethod(cls, footerSel);
        if (footer) {
            CGOriginalSettingsFooter = method_getImplementation(footer);
            method_setImplementation(footer, (IMP)CGSettingsFooter);
        }

        SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
        Method cell = class_getInstanceMethod(cls, cellSel);
        if (cell) {
            CGOriginalSettingsCell = method_getImplementation(cell);
            method_setImplementation(cell, (IMP)CGSettingsCell);
        }
    }
}
