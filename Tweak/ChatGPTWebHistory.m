#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sqlite3.h>

UIViewController *CGCurrentWebRoot(void);

@interface CGWebHistoryItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSDate *date;
@end
@implementation CGWebHistoryItem
@end

static UIButton *CGHistoryFindButtonForAction(UIView *root, NSString *needle) {
    if (!root) return nil;
    if ([root isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)root;
        for (id target in button.allTargets) {
            for (NSString *action in [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
                if ([action rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return button;
            }
        }
    }
    for (UIView *subview in root.subviews) {
        UIButton *found = CGHistoryFindButtonForAction(subview, needle);
        if (found) return found;
    }
    return nil;
}

static void CGOpenWebHistoryURL(NSURL *url) {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !url) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:url.absoluteString forKey:@"default.NewTabSettings.customNewTabURL"];
    [defaults synchronize];

    UIButton *button = CGHistoryFindButtonForAction(root.view, @"newTabTapped");
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
        [defaults synchronize];
    });
}

static NSString *CGHistoryDatabasePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [[support stringByAppendingPathComponent:@"AppData/History"] stringByAppendingPathComponent:@"History"];
}

static BOOL CGIsChatConversationURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!([host isEqualToString:@"chatgpt.com"] || [host isEqualToString:@"www.chatgpt.com"])) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path hasPrefix:@"/c/"] || [path containsString:@"/c/"];
}

static NSString *CGCleanHistoryTitle(NSString *title) {
    NSString *value = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return @"ChatGPT conversation";

    NSArray<NSString *> *suffixes = @[@" | ChatGPT", @" - ChatGPT", @" — ChatGPT"];
    for (NSString *suffix in suffixes) {
        if ([value.lowercaseString hasSuffix:suffix.lowercaseString] && value.length > suffix.length) {
            value = [value substringToIndex:value.length - suffix.length];
            value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    if (!value.length || [value caseInsensitiveCompare:@"ChatGPT"] == NSOrderedSame) return @"ChatGPT conversation";
    return value;
}

static NSArray<CGWebHistoryItem *> *CGLoadWebHistory(void) {
    NSString *path = CGHistoryDatabasePath();
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return @[];

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return @[];
    }
    sqlite3_busy_timeout(db, 1200);

    const char *sql = "SELECT title, url, updated_at FROM history ORDER BY updated_at DESC LIMIT 500;";
    sqlite3_stmt *stmt = NULL;
    NSMutableArray<CGWebHistoryItem *> *items = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *titleText = sqlite3_column_text(stmt, 0);
            const unsigned char *urlText = sqlite3_column_text(stmt, 1);
            if (!urlText) continue;

            NSString *urlString = [NSString stringWithUTF8String:(const char *)urlText];
            NSURL *url = [NSURL URLWithString:urlString];
            if (!url || !CGIsChatConversationURL(url)) continue;

            NSString *title = titleText ? [NSString stringWithUTF8String:(const char *)titleText] : @"";
            CGWebHistoryItem *item = [CGWebHistoryItem new];
            item.title = CGCleanHistoryTitle(title);
            item.url = url;
            item.date = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_double(stmt, 2)];
            [items addObject:item];
        }
    }

    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return items;
}

@interface CGWebHistoryController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, weak) UIViewController *webRoot;
@property (nonatomic, assign) BOOL nativeMode;
@property (nonatomic, copy) NSArray<CGWebHistoryItem *> *allItems;
@property (nonatomic, copy) NSArray<CGWebHistoryItem *> *visibleItems;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation CGWebHistoryController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"History";

    self.dateFormatter = [NSDateFormatter new];
    self.dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;
    self.dateFormatter.doesRelativeDateFormatting = YES;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Search chats";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self reloadHistory];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadHistory];
}

- (void)reloadHistory {
    self.allItems = CGLoadWebHistory();
    [self applySearch:self.searchController.searchBar.text ?: @""];
}

- (void)applySearch:(NSString *)query {
    NSString *needle = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!needle.length) {
        self.visibleItems = self.allItems;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(CGWebHistoryItem *item, NSDictionary *bindings) {
            return [item.title rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [item.url.absoluteString rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.visibleItems = [self.allItems filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];

    if (self.visibleItems.count == 0) {
        UILabel *empty = [UILabel new];
        empty.text = self.allItems.count ? @"No matching chats" : @"No web chat history yet\n\nChats you open in this app will appear here using the title ChatGPT gives them.";
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        empty.textColor = UIColor.secondaryLabelColor;
        empty.font = [UIFont systemFontOfSize:15];
        self.tableView.backgroundView = empty;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applySearch:searchController.searchBar.text ?: @""];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    CGWebHistoryItem *item = self.visibleItems[ip.row];
    cell.textLabel.text = item.title;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [self.dateFormatter stringFromDate:item.date];
    cell.imageView.image = [UIImage systemImageNamed:@"message"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= self.visibleItems.count) return;

    NSURL *url = self.visibleItems[ip.row].url;
    UIViewController *web = self.webRoot ?: CGCurrentWebRoot();
    BOOL nativeMode = self.nativeMode;
    UINavigationController *menuNav = self.navigationController;

    [menuNav dismissViewControllerAnimated:YES completion:^{
        if (nativeMode && web.presentedViewController) {
            [web dismissViewControllerAnimated:YES completion:^{
                CGOpenWebHistoryURL(url);
            }];
        } else {
            CGOpenWebHistoryURL(url);
        }
    }];
}

@end

void CGPushWebHistory(UINavigationController *navigationController, BOOL nativeMode, UIViewController *webRoot) {
    if (!navigationController) return;
    CGWebHistoryController *history = [CGWebHistoryController new];
    history.nativeMode = nativeMode;
    history.webRoot = webRoot ?: CGCurrentWebRoot();
    [navigationController pushViewController:history animated:YES];
}
