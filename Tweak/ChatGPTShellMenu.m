#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

UIViewController *CGCurrentWebRoot(void);

@class CGConversation;
@interface CGStore : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) NSMutableArray<CGConversation *> *conversations;
@property (nonatomic, copy) NSString *currentConversationID;
- (CGConversation *)newConversation;
- (void)deleteConversation:(CGConversation *)conversation;
- (void)save;
@end

@interface CGConversation : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@end

@interface CGChatViewController : UIViewController
- (void)reloadConversation;
@end

@interface CGSettingsViewController : UITableViewController
@end

@interface CGUnifiedMenuController : UITableViewController
@property (nonatomic, weak) UIViewController *webRoot;
@property (nonatomic, weak) CGChatViewController *nativeChat;
@property (nonatomic, assign) BOOL nativeMode;
@end

@implementation CGUnifiedMenuController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChatGPT";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : CGStore.shared.conversations.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"Native chats" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"ChatGPT Web is the default and uses the bundled Gecko engine with your normal ChatGPT account. Native Chat is optional and uses an OpenAI API key.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 0) {
        NSArray *names = @[@"ChatGPT Web", @"Native Chat", @"Settings"];
        NSArray *icons = @[@"globe", @"message", @"gearshape"];
        cell.textLabel.text = names[ip.row];
        cell.imageView.image = [UIImage systemImageNamed:icons[ip.row]];
        if (ip.row == 0) {
            cell.detailTextLabel.text = @"Normal ChatGPT account • Gecko";
            cell.accessoryType = self.nativeMode ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryCheckmark;
        } else if (ip.row == 1) {
            cell.detailTextLabel.text = @"Optional API chat";
            cell.accessoryType = self.nativeMode ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    CGConversation *conversation = CGStore.shared.conversations[ip.row];
    cell.textLabel.text = conversation.title ?: @"New chat";
    cell.imageView.image = [UIImage systemImageNamed:@"message"];
    if ([conversation.identifier isEqualToString:CGStore.shared.currentConversationID]) cell.detailTextLabel.text = @"Current native chat";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)showNativeChat:(CGConversation *)conversation {
    if (conversation) {
        CGStore.shared.currentConversationID = conversation.identifier;
        [CGStore.shared save];
    }

    if (self.nativeMode && self.nativeChat) {
        [self.nativeChat reloadConversation];
        [self done];
        return;
    }

    UIViewController *web = self.webRoot ?: CGCurrentWebRoot();
    CGChatViewController *chat = [CGChatViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:chat];
    nav.navigationBar.prefersLargeTitles = NO;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self dismissViewControllerAnimated:YES completion:^{
        [web presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)showWebChat {
    if (!self.nativeMode) {
        [self done];
        return;
    }
    UIViewController *web = self.webRoot ?: CGCurrentWebRoot();
    [self dismissViewControllerAnimated:YES completion:^{
        [web dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)showSettings {
    CGSettingsViewController *settings = [CGSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (ip.row == 0) [self showWebChat];
        else if (ip.row == 1) [self showNativeChat:nil];
        else [self showSettings];
        return;
    }
    if (ip.row < CGStore.shared.conversations.count) [self showNativeChat:CGStore.shared.conversations[ip.row]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 1 || ip.row >= CGStore.shared.conversations.count) return;
    [CGStore.shared deleteConversation:CGStore.shared.conversations[ip.row]];
    [tableView reloadData];
    [self.nativeChat reloadConversation];
}

@end

void CGPresentUnifiedMenu(UIViewController *presenter, BOOL nativeMode, id nativeChatController) {
    if (!presenter) return;
    CGUnifiedMenuController *menu = [CGUnifiedMenuController new];
    menu.webRoot = CGCurrentWebRoot();
    menu.nativeMode = nativeMode;
    menu.nativeChat = nativeChatController;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
    [presenter presentViewController:nav animated:YES completion:nil];
}

static void CGNativeOpenSidebar(id self, SEL _cmd) {
    CGPresentUnifiedMenu((UIViewController *)self, YES, self);
}

__attribute__((constructor))
static void CGInstallNativeMenuHook(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.551.chatgpt14"]) return;
        Class chatClass = NSClassFromString(@"CGChatViewController");
        Method method = chatClass ? class_getInstanceMethod(chatClass, NSSelectorFromString(@"openSidebar")) : NULL;
        if (method) method_setImplementation(method, (IMP)CGNativeOpenSidebar);
    }
}
