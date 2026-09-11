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
                if ([action rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    return button;
                }
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

            // The overview marks only the active regular/private collection as
            // interactive. ChatGPT Web always uses normal (non-private) tabs.
            if (collection.userInteractionEnabled && targetIndex >= 0 && targetIndex < count) {
                return collection;
            }
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
    if (selectedID.length && [selectedID isEqualToString:tabID]) {
        return YES;
    }

    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded) return NO;

    UIButton *overviewButton = CGTRFindButtonForAction(root.view, @"tabOverviewTapped");
    if (!overviewButton) return NO;

    // The ChatGPT shell keeps Reynard's overview visually hidden, but its
    // UICollectionView/delegate still provide a safe path into Reynard's own
    // selectTab(at:mode:) logic. Present the hidden overview, then invoke the
    // normal collection-selection callback for the saved tab's persisted index.
    // That switches the existing GeckoSession itself, preserving the whole chat
    // even on builds where ChatGPT's SPA never exposes a /c/... URL to us.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [overviewButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGTRSelectOverviewItem(root, index, 0);
        });
    });
    return YES;
}
