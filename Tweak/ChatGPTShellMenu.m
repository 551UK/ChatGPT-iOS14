#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "ChatGPTTabRestore.m"

UIViewController *CGCurrentWebRoot(void);
void CGCaptureWebRecents(void);
NSArray<NSDictionary *> *CGWebRecentItems(void);
BOOL CGOpenWebRecentItem(NSDictionary *item);
void CGClearWebRecents(void);

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

@interface CGUnifiedMenuController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, weak) UIViewController *webRoot;
@property (nonatomic, weak) CGChatViewController *nativeChat;
@property (nonatomic, assign) BOOL nativeMode;
@property (nonatomic, copy) NSArray<NSDictionary *> *allWebRecents;
@property (nonatomic, copy) NSArray<NSDictionary *> *webRecents;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation CGUnifiedMenuController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChatGPT";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"] style:UIBarButtonItemStylePlain target:self action:@selector(searchTapped)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Search chats";
    self.definesPresentationContext = YES;

    [self reloadWebRecents];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadWebRecents];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)searchTapped {
    if (!self.navigationItem.searchController) {
        self.navigationItem.searchController = self.searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
    }
    self.searchController.active = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchController.searchBar becomeFirstResponder];
    });
}

- (void)reloadWebRecents {
    CGCaptureWebRecents();
    self.allWebRecents = CGWebRecentItems();
    [self applyRecentSearch:self.searchController.searchBar.text ?: @""];
}

- (void)applyRecentSearch:(NSString *)query {
    NSString *needle = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!needle.length) {
        self.webRecents = self.allWebRecents ?: @[];
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
            NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
            return [title rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.webRecents = [self.allWebRecents filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyRecentSearch:searchController.searchBar.text ?: @""];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return self.webRecents.count + (self.allWebRecents.count ? 1 : 0);
    return CGStore.shared.conversations.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return @"Recents";
    if (section == 2 && CGStore.shared.conversations.count) return @"Native chats";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"ChatGPT Web uses your normal ChatGPT account through the bundled Gecko engine. Native Chat is optional and uses an OpenAI API key.";
    if (section == 1 && self.allWebRecents.count == 0) return @"The first prompt you send in a web chat is saved locally here.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
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

    if (ip.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        if (ip.row == self.webRecents.count && self.allWebRecents.count) {
            cell.textLabel.text = @"Clear Recents";
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            return cell;
        }

        NSDictionary *item = self.webRecents[ip.row];
        NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"Recent chat";
        cell.textLabel.text = title.length ? title : @"Recent chat";
        cell.textLabel.numberOfLines = 1;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
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

- (void)showRecentUnavailableAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Chat unavailable"
                                                                   message:@"The Gecko tab for this Recent is no longer available and ChatGPT did not expose a reusable conversation link for it."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openRecentAtIndex:(NSUInteger)index {
    if (index >= self.webRecents.count) return;
    NSDictionary *item = self.webRecents[index];

    // Preferred path: reopen the exact persisted Gecko tab. This restores the
    // actual live/restored GeckoSession and therefore the complete conversation;
    // it does not depend on ChatGPT exposing a /c/... URL to the browser shell.
    BOOL restoringSavedTab = CGRestoreWebRecentTab(item);

    // Fallback for an old Recent whose original Gecko tab has gone away but for
    // which we did manage to save an exact ChatGPT conversation URL.
    if (!restoringSavedTab && !CGOpenWebRecentItem(item)) {
        [self showRecentUnavailableAlert];
        return;
    }

    BOOL nativeMode = self.nativeMode;
    UIViewController *web = self.webRoot ?: CGCurrentWebRoot();
    UINavigationController *menuNav = self.navigationController;
    [menuNav dismissViewControllerAnimated:YES completion:^{
        if (nativeMode && web.presentedViewController) {
            [web dismissViewControllerAnimated:YES completion:nil];
        }
    }];
}

- (void)confirmClearRecents {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Recents?"
                                                                   message:@"This only clears the locally saved Recents list in this app. It does not delete conversations from your ChatGPT account."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        CGClearWebRecents();
        [weakSelf reloadWebRecents];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (ip.row == 0) [self showWebChat];
        else if (ip.row == 1) [self showNativeChat:nil];
        else [self showSettings];
        return;
    }
    if (ip.section == 1) {
        if (ip.row == self.webRecents.count && self.allWebRecents.count) [self confirmClearRecents];
        else [self openRecentAtIndex:ip.row];
        return;
    }
    if (ip.row < CGStore.shared.conversations.count) [self showNativeChat:CGStore.shared.conversations[ip.row]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 2;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 2 || ip.row >= CGStore.shared.conversations.count) return;
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
