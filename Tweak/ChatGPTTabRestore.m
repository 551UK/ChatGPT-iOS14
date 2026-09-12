#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <sqlite3.h>

UIViewController *CGCurrentWebRoot(void);

#pragma mark - Persisted Gecko tab lookup

static NSString *CGTRTabDatabasePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [support stringByAppendingPathComponent:@"AppData/TabManagement/TabManagement"];
}

static sqlite3 *CGTROpenDatabase(void) {
    NSString *path = CGTRTabDatabasePath();
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return NULL;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, 500);
    return db;
}

static NSString *CGTRSQLiteString(sqlite3_stmt *stmt, int column) {
    const unsigned char *text = sqlite3_column_text(stmt, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

static BOOL CGTRTabLocation(NSString *tabID, NSInteger *indexOut, BOOL *privateOut) {
    if (!tabID.length) return NO;
    sqlite3 *db = CGTROpenDatabase();
    if (!db) return NO;
    BOOL found = NO;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT position, is_private FROM tabs WHERE id = ? LIMIT 1;", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, tabID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            if (indexOut) *indexOut = (NSInteger)sqlite3_column_int64(stmt, 0);
            if (privateOut) *privateOut = sqlite3_column_int64(stmt, 1) != 0;
            found = YES;
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return found;
}

static NSString *CGTRSelectedRegularTabID(void) {
    sqlite3 *db = CGTROpenDatabase();
    if (!db) return nil;
    NSString *selectedID = nil;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT selected_regular_tab_id FROM tab_state WHERE id = 1 LIMIT 1;", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        selectedID = CGTRSQLiteString(stmt, 0);
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return selectedID;
}

#pragma mark - Hidden Reynard tab overview bridge

static UIButton *CGTRFindButtonForAction(UIView *root, NSString *needle) {
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
        UIButton *found = CGTRFindButtonForAction(subview, needle);
        if (found) return found;
    }
    return nil;
}

static UICollectionView *CGTRFindRegularTabCollection(UIView *root, NSInteger targetIndex) {
    if (!root) return nil;
    if ([root isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)root;
        id delegate = collection.delegate;
        NSString *delegateClass = delegate ? NSStringFromClass([delegate class]) : @"";
        if ([delegateClass rangeOfString:@"TabOverviewCollection" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [collection reloadData];
            [collection layoutIfNeeded];
            NSInteger count = [collection numberOfItemsInSection:0];
            if (collection.userInteractionEnabled && targetIndex >= 0 && targetIndex < count) return collection;
        }
    }
    for (UIView *subview in root.subviews) {
        UICollectionView *found = CGTRFindRegularTabCollection(subview, targetIndex);
        if (found) return found;
    }
    return nil;
}

static void CGTRSelectOverviewItem(UIViewController *root, NSInteger index, NSUInteger attempt) {
    if (!root || attempt >= 24) return;
    UICollectionView *collection = CGTRFindRegularTabCollection(root.view, index);
    id delegate = collection.delegate;
    SEL selector = NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:");
    if (collection && delegate && [delegate respondsToSelector:selector]) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index inSection:0];
        ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))objc_msgSend)(delegate, selector, collection, indexPath);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGTRSelectOverviewItem(root, index, attempt + 1);
    });
}

BOOL CGRestoreWebRecentTab(NSDictionary *item) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSString *tabID = [item[@"tab_id"] isKindOfClass:NSString.class] ? item[@"tab_id"] : nil;
    if (!tabID.length) return NO;
    NSInteger index = NSNotFound;
    BOOL isPrivate = NO;
    if (!CGTRTabLocation(tabID, &index, &isPrivate) || isPrivate || index == NSNotFound) return NO;
    NSString *selectedID = CGTRSelectedRegularTabID();
    if (selectedID.length && [selectedID isEqualToString:tabID]) return YES;
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded) return NO;
    UIButton *overviewButton = CGTRFindButtonForAction(root.view, @"tabOverviewTapped");
    if (!overviewButton) return NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [overviewButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGTRSelectOverviewItem(root, index, 0);
        });
    });
    return YES;
}

#pragma mark - Empty composer microphone handoff

static NSString *CGMBAXText(id e) {
    NSMutableArray *p = [NSMutableArray array];
    for (NSString *s in @[[e accessibilityLabel] ?: @"", [e accessibilityValue] ?: @"", [e accessibilityHint] ?: @"", [e accessibilityIdentifier] ?: @""]) if (s.length) [p addObject:s];
    return [[p componentsJoinedByString:@" "] lowercaseString];
}

static id CGMBFind(id node, BOOL (^match)(id), NSMutableSet *seen, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    if (match(node)) return node;
    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) for (id child in elements) { id f = CGMBFind(child, match, seen, depth + 1); if (f) return f; }
    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) for (NSInteger i = 0; i < count; i++) { id f = CGMBFind([node accessibilityElementAtIndex:i], match, seen, depth + 1); if (f) return f; }
    if ([node isKindOfClass:UIView.class]) for (UIView *v in [(UIView *)node subviews]) { id f = CGMBFind(v, match, seen, depth + 1); if (f) return f; }
    return nil;
}

static id CGMBComposer(UIView *root) {
    return CGMBFind(root, ^BOOL(id e) { NSString *t = CGMBAXText(e); return [t containsString:@"ask chatgpt"] || [t containsString:@"ask anything"] || [t containsString:@"message chatgpt"] || [t containsString:@"prompt chatgpt"]; }, [NSMutableSet set], 0);
}

static BOOL CGMBEmpty(id c) {
    NSString *v = [[c accessibilityValue] lowercaseString];
    return !v.length || [v isEqualToString:@"ask chatgpt"] || [v isEqualToString:@"ask anything"] || [v isEqualToString:@"message chatgpt"] || [v isEqualToString:@"prompt chatgpt"];
}

static id CGMBWebMic(UIView *root) {
    return CGMBFind(root, ^BOOL(id e) { NSString *t = CGMBAXText(e); return ![t containsString:@"chatgptmicbridge"] && ([t containsString:@"microphone"] || [t containsString:@"dictat"] || [t containsString:@"voice input"]); }, [NSMutableSet set], 0);
}

static id CGMBSend(UIView *root) {
    return CGMBFind(root, ^BOOL(id e) { NSString *t = CGMBAXText(e); return [t isEqualToString:@"send"] || [t containsString:@"send message"]; }, [NSMutableSet set], 0);
}

static UIView *CGMBResponder(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *v in root.subviews) { UIView *f = CGMBResponder(v); if (f) return f; }
    return nil;
}

@interface CGMicBridgeController : NSObject
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,assign) BOOL handingOff;
@end

@implementation CGMicBridgeController

- (instancetype)init {
    if ((self = [super init])) {
        _timer = [NSTimer timerWithTimeInterval:0.35 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)ensureButton:(UIViewController *)root {
    if (self.button.superview == root.view) return;
    [self.button removeFromSuperview];
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(0, 0, 44, 44);
    self.button.tintColor = UIColor.labelColor;
    [self.button setImage:[UIImage systemImageNamed:@"mic"] forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"Voice input";
    self.button.accessibilityIdentifier = @"ChatGPTMicBridge";
    [self.button addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:self.button];
}

- (void)refresh {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded || !root.view.window || self.handingOff) { self.button.hidden = YES; return; }
    id composer = CGMBComposer(root.view);
    if (!composer || !CGMBEmpty(composer) || CGMBWebMic(root.view)) { self.button.hidden = YES; return; }
    [self ensureButton:root];
    id send = CGMBSend(root.view);
    CGRect sf = [send accessibilityFrame];
    CGRect cf = [composer accessibilityFrame];
    if (send && !CGRectIsEmpty(sf)) {
        sf = [root.view convertRect:sf fromView:nil];
        self.button.center = CGPointMake(CGRectGetMinX(sf) - 28, CGRectGetMidY(sf));
    } else if (!CGRectIsEmpty(cf)) {
        cf = [root.view convertRect:cf fromView:nil];
        self.button.center = CGPointMake(CGRectGetMaxX(cf) - 88, CGRectGetMidY(cf));
    }
    self.button.hidden = NO;
    [root.view bringSubviewToFront:self.button];
}

- (void)start {
    UIViewController *root = CGCurrentWebRoot();
    id composer = root ? CGMBComposer(root.view) : nil;
    if (!root || !composer || !CGMBEmpty(composer)) return;
    self.handingOff = YES;
    self.button.hidden = YES;
    if (![composer accessibilityActivate]) { self.handingOff = NO; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50000000), dispatch_get_main_queue(), ^{
        UIView *responder = CGMBResponder(root.view);
        if (!responder || ![responder conformsToProtocol:@protocol(UIKeyInput)]) { self.handingOff = NO; return; }
        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        [input insertText:@"."];
        [self waitForMic:root input:input responder:responder attempt:0];
    });
}

- (void)waitForMic:(UIViewController *)root input:(id<UIKeyInput>)input responder:(UIView *)responder attempt:(NSInteger)attempt {
    id mic = CGMBWebMic(root.view);
    if (mic) {
        [mic accessibilityActivate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30000000), dispatch_get_main_queue(), ^{ [input deleteBackward]; [responder resignFirstResponder]; self.handingOff = NO; });
        return;
    }
    if (attempt >= 12) { [input deleteBackward]; [responder resignFirstResponder]; self.handingOff = NO; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50000000), dispatch_get_main_queue(), ^{ [self waitForMic:root input:input responder:responder attempt:attempt + 1]; });
}

@end

__attribute__((constructor)) static void CGMBInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ static CGMicBridgeController *bridge; bridge = [CGMicBridgeController new]; });
}
