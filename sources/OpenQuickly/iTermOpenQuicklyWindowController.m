#import "iTermOpenQuicklyWindowController.h"

#import "SFSymbolEnum/SFSymbolEnum.h"
#import "iTerm2SharedARC-Swift.h"
#import "ITAddressBookMgr.h"
#import "iTermApplication.h"
#import "iTermApplicationDelegate.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermController.h"
#import "iTermGlobalSearchEngine.h"
#import "iTermGlobalSearchResult.h"
#import "iTermHotKeyController.h"
#import "iTermProfileHotKey.h"
#import "iTermOpenQuicklyItem.h"
#import "iTermOpenQuicklyModel.h"
#import "iTermOpenQuicklyTableView.h"
#import "iTermOpenQuicklyTextField.h"
#import "iTermOpenQuicklyWindow.h"
#import "iTermScriptFunctionCall.h"
#import "iTermScriptsMenuController.h"
#import "iTermSessionLauncher.h"
#import "iTermSnippetsMenuController.h"
#import "iTermVariableScope+Session.h"
#import "iTermWarning.h"
#import "DebugLogging.h"
#import "NSAppearance+iTerm.h"
#import "NSObject+iTerm.h"
#import "PseudoTerminal.h"
#import "PTYSession.h"
#import "PTYSession+Scripting.h"
#import "PTYTab.h"
#import "VT100RemoteHost.h"
#import "VT100Screen.h"

#import <Carbon/Carbon.h>

// Rows 1-9 get a ⌘N shortcut.
static const NSInteger iTermOpenQuicklyMaxShortcutRow = 9;

// Buffer search: shorter queries match nearly every line of every session.
static const NSUInteger iTermOpenQuicklyMinBufferQueryLength = 3;
// Keep the list scannable: a few hits per session, and a cap overall.
static const NSInteger iTermOpenQuicklyMaxBufferHitsPerSession = 3;
static const NSInteger iTermOpenQuicklyMaxBufferHits = 30;

@interface iTermOpenQuicklyWindowController () <
    iTermOpenQuicklyTextFieldDelegate,
    iTermOpenQuicklyModelDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate,
    NSWindowDelegate>

@property(nonatomic, strong) iTermOpenQuicklyModel *model;

@end

@implementation iTermOpenQuicklyWindowController {
    // Text field where queries are entered
    iTermOpenQuicklyTextField *_textField;

    // Table that shows search results
    iTermOpenQuicklyTableView *_table;
    NSScrollView *_scrollView;
    NSLayoutConstraint *_listWidth;
    NSTextField *_noResultsLabel;

    NSButton *_clearButton;
    iTermOpenQuicklyTextView *_textView;  // custom field editor

    // Right-hand pane showing the highlighted item.
    iTermOpenQuicklyPreviewPane *_previewPane;

    // Snapshot of the session most recently previewed, so arrowing back and
    // forth or typing doesn't re-render the grid every time.
    NSString *_snapshotGuid;
    NSImage *_snapshot;

    // Case-insensitive search of every session's scrollback, run alongside the
    // model's fuzzy match. Its hits are listed after the model's items.
    iTermGlobalSearchEngine *_bufferSearch;
    NSMutableArray<id<iTermGlobalSearchResultProtocol>> *_bufferHits;
    NSMutableDictionary<NSString *, NSNumber *> *_bufferHitCounts;  // session guid -> hits kept
    BOOL _bufferSearchRunning;
}

+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    iTermOpenQuicklyWindow *window =
        [[iTermOpenQuicklyWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 560)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
    self = [super initWithWindow:window];
    if (self) {
        _model = [[iTermOpenQuicklyModel alloc] init];
        _model.delegate = self;
        [self buildWindow];
    }
    return self;
}

#pragma mark - Building the window

- (void)buildWindow {
    NSWindow *window = self.window;
    window.title = NSLocalizedStringWithDefaultValue(@"OpenQuickly.WindowTitle", nil, [NSBundle mainBundle], @"Open Quickly", @"Accessibility title of the Open Quickly palette window");
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.hasShadow = YES;
    window.releasedWhenClosed = NO;
    window.restorable = NO;
    window.delegate = self;

    iTermOpenQuicklyPaletteBackgroundView *background =
        [[iTermOpenQuicklyPaletteBackgroundView alloc] initWithFrame:window.contentView.bounds];
    window.contentView = background;
    NSView *content = background.contentView;

    // Header: loupe, query field, clear button.
    NSImageView *loupe = [[NSImageView alloc] init];
    loupe.image = [[NSImage imageWithSystemSymbolName:SFSymbolGetString(SFSymbolMagnifyingglass)
                             accessibilityDescription:NSLocalizedStringWithDefaultValue(@"OpenQuickly.SearchIconAccessibility", nil, [NSBundle mainBundle], @"Search icon", @"Accessibility description for the Open Quickly search icon")]
                   imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightMedium]];
    loupe.contentTintColor = [NSColor secondaryLabelColor];

    _textField = [[iTermOpenQuicklyTextField alloc] init];
    _textField.bezeled = NO;
    _textField.bordered = NO;
    _textField.drawsBackground = NO;
    _textField.focusRingType = NSFocusRingTypeNone;
    _textField.font = [NSFont systemFontOfSize:21 weight:NSFontWeightRegular];
    _textField.textColor = [NSColor labelColor];
    _textField.cell.scrollable = YES;
    _textField.cell.usesSingleLineMode = YES;
    _textField.cell.lineBreakMode = NSLineBreakByClipping;
    _textField.placeholderString = NSLocalizedStringWithDefaultValue(@"OpenQuickly.Placeholder", nil, [NSBundle mainBundle], @"Jump to a session, or search profiles and menus", @"Placeholder in the Open Quickly search field");
    _textField.delegate = self;
    _textField.arrowHandler = self;

    _clearButton = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:SFSymbolGetString(SFSymbolXmarkCircleFill)
                                                       accessibilityDescription:NSLocalizedStringWithDefaultValue(@"OpenQuickly.ClearSearchAccessibility", nil, [NSBundle mainBundle], @"Clear search query", @"Accessibility description for the Open Quickly clear search button")]
                                              imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]]
                                      target:self
                                      action:@selector(clearQuery:)];
    _clearButton.bordered = NO;
    _clearButton.contentTintColor = [NSColor tertiaryLabelColor];
    _clearButton.hidden = YES;

    // Results list.
    _table = [[iTermOpenQuicklyTableView alloc] init];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.style = NSTableViewStylePlain;
    _table.rowHeight = iTermOpenQuicklyPaletteMetrics.rowHeight;
    _table.intercellSpacing = NSZeroSize;
    _table.backgroundColor = [NSColor clearColor];
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.allowsEmptySelection = NO;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(doubleClick:);

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.documentView = _table;
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.contentInsets = NSEdgeInsetsMake(6, 0, 6, 0);
    _scrollView.automaticallyAdjustsContentInsets = NO;

    _noResultsLabel = [NSTextField labelWithString:NSLocalizedStringWithDefaultValue(@"OpenQuickly.NoResults", nil, [NSBundle mainBundle], @"No matches", @"Shown in Open Quickly when nothing matches the query")];
    _noResultsLabel.font = [NSFont systemFontOfSize:13];
    _noResultsLabel.textColor = [NSColor tertiaryLabelColor];
    _noResultsLabel.hidden = YES;

    _previewPane = [[iTermOpenQuicklyPreviewPane alloc] initWithFrame:NSZeroRect];

    iTermOpenQuicklySeparatorView *headerSeparator = [[iTermOpenQuicklySeparatorView alloc] initWithFrame:NSZeroRect];
    iTermOpenQuicklySeparatorView *columnSeparator = [[iTermOpenQuicklySeparatorView alloc] initWithFrame:NSZeroRect];
    iTermOpenQuicklySeparatorView *footerSeparator = [[iTermOpenQuicklySeparatorView alloc] initWithFrame:NSZeroRect];
    iTermOpenQuicklyHintBar *footer = [[iTermOpenQuicklyHintBar alloc] initWithFrame:NSZeroRect];

    for (NSView *view in @[ loupe, _textField, _clearButton, headerSeparator, _scrollView, _noResultsLabel,
                            columnSeparator, _previewPane, footerSeparator, footer ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }

    const CGFloat headerHeight = iTermOpenQuicklyPaletteMetrics.headerHeight;
    const CGFloat footerHeight = iTermOpenQuicklyPaletteMetrics.footerHeight;
    _listWidth = [_scrollView.widthAnchor constraintEqualToConstant:400];
    [NSLayoutConstraint activateConstraints:@[
        [loupe.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [loupe.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:headerHeight / 2],
        [loupe.widthAnchor constraintEqualToConstant:22],

        [_textField.leadingAnchor constraintEqualToAnchor:loupe.trailingAnchor constant:12],
        [_textField.centerYAnchor constraintEqualToAnchor:loupe.centerYAnchor],
        [_textField.trailingAnchor constraintEqualToAnchor:_clearButton.leadingAnchor constant:-10],

        [_clearButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [_clearButton.centerYAnchor constraintEqualToAnchor:loupe.centerYAnchor],
        [_clearButton.widthAnchor constraintEqualToConstant:18],

        [headerSeparator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [headerSeparator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [headerSeparator.topAnchor constraintEqualToAnchor:content.topAnchor constant:headerHeight],
        [headerSeparator.heightAnchor constraintEqualToConstant:1],

        [_scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:headerSeparator.bottomAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:footerSeparator.topAnchor],
        _listWidth,

        [_noResultsLabel.centerXAnchor constraintEqualToAnchor:_scrollView.centerXAnchor],
        [_noResultsLabel.topAnchor constraintEqualToAnchor:_scrollView.topAnchor constant:28],

        [columnSeparator.leadingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor],
        [columnSeparator.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
        [columnSeparator.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor],
        [columnSeparator.widthAnchor constraintEqualToConstant:1],

        [_previewPane.leadingAnchor constraintEqualToAnchor:columnSeparator.trailingAnchor],
        [_previewPane.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_previewPane.topAnchor constraintEqualToAnchor:_scrollView.topAnchor],
        [_previewPane.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor],

        [footerSeparator.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footerSeparator.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footerSeparator.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footerSeparator.heightAnchor constraintEqualToConstant:1],

        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:footerHeight],
    ]];
    window.initialFirstResponder = _textField;
}

#pragma mark - Presenting

- (void)presentWindow {
    if (self.window.isVisible) {
        // Pressing the shortcut again dismisses the palette.
        [self close:nil];
        return;
    }
    _snapshotGuid = nil;
    _snapshot = nil;
    _textField.stringValue = @"";
    self.window.appearance = [NSAppearance it_appearanceForCurrentTheme];
    // Mirror iTermProfileHotKey's floating-panel collection behavior. Notably:
    // (1) FullScreenAuxiliary lets the panel appear over fullscreen windows of
    // other apps, (2) Transient is omitted because transient windows "do not
    // contribute to the active state of the app", which appears to break
    // re-show as a non-activating panel on macOS 26.
    self.window.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorFullScreenAuxiliary |
                                      NSWindowCollectionBehaviorIgnoresCycle);
    // Float just below the main menu, matching the level used by iTerm2's
    // floating profile hotkey window. Higher levels (e.g. NSPopUpMenuWindowLevel)
    // are not honored for non-activating panels on macOS 26 when the app is
    // in the background, so the panel ends up hidden behind other apps on
    // subsequent shows.
    self.window.level = NSMainMenuWindowLevel - 2;
    const NSRect frame = [self frame];
    _listWidth.constant = [iTermOpenQuicklyPaletteMetrics listWidthForPaletteWidth:frame.size.width];
    [self.window setFrame:frame display:NO];
    [self update];

    // The alpha 0 -> 1 fade forces the window server to actually paint a
    // non-activating panel brought up from another app on macOS 26. When
    // iTerm2 is frontmost, a short fade just looks nice.
    self.window.alphaValue = 0;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_textField];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = MAX(0, [iTermAdvancedSettingsModel openQuicklyAnimationDuration]);
        self.window.animator.alphaValue = 1;
    }];
}

// A fixed-size palette centered horizontally, a little above the middle of
// the screen holding the key window.
- (NSRect)frame {
    NSScreen *screen = [[NSApp keyWindow] screen] ?: [NSScreen mainScreen];
    const NSRect visible = screen.visibleFrame;
    const NSSize size = [iTermOpenQuicklyPaletteMetrics paletteSizeForVisibleFrame:visible];
    const CGFloat slack = visible.size.height - size.height;
    return NSMakeRect(NSMinX(visible) + floor((visible.size.width - size.width) / 2),
                      NSMinY(visible) + floor(slack * 0.62),
                      size.width,
                      size.height);
}

// Recompute the model and redisplay.
- (void)update {
    NSString *query = _textField.stringValue;
    [self.model updateWithQuery:query];
    [self startBufferSearchForQuery:query];
    _clearButton.hidden = query.length == 0;
    [_table reloadData];
    [self updateNoResultsLabel];
    if (_table.numberOfRows > 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
    [self refreshPreview];
}

- (void)updateNoResultsLabel {
    // Don't claim “no matches” while the buffer search may still find some.
    _noResultsLabel.hidden = _table.numberOfRows > 0 || _bufferSearchRunning;
}

#pragma mark - Buffer search

- (void)stopBufferSearch {
    [_bufferSearch stop];
    _bufferSearch = nil;
    _bufferSearchRunning = NO;
    _bufferHits = [NSMutableArray array];
    _bufferHitCounts = [NSMutableDictionary dictionary];
}

- (void)startBufferSearchForQuery:(NSString *)query {
    [self stopBufferSearch];
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // A leading slash is an Open Quickly command such as /p, not text to find.
    if (trimmed.length < iTermOpenQuicklyMinBufferQueryLength || [trimmed hasPrefix:@"/"]) {
        return;
    }
    NSMutableArray<PTYSession *> *sessions = [NSMutableArray array];
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        [sessions addObjectsFromArray:term.allSessions];
    }
    _bufferSearchRunning = YES;
    __weak __typeof(self) weakSelf = self;
    // Weak: the engine owns this handler. Results arrive from the engine's
    // timer, so this is assigned before the first callback.
    __block __weak iTermGlobalSearchEngine *weakEngine = nil;
    iTermGlobalSearchEngine *engine =
        [[iTermGlobalSearchEngine alloc] initWithQuery:trimmed
                                              sessions:sessions
                                                  mode:iTermFindModeCaseInsensitiveSubstring
                                               handler:^(PTYSession *session,
                                                         NSArray<id<iTermGlobalSearchResultProtocol>> *results,
                                                         double progress) {
            [weakSelf bufferSearch:weakEngine didFindResults:results inSession:session];
        }];
    weakEngine = engine;
    _bufferSearch = engine;
}

// `session` is nil once the search has finished.
- (void)bufferSearch:(iTermGlobalSearchEngine *)engine
      didFindResults:(NSArray<id<iTermGlobalSearchResultProtocol>> *)results
           inSession:(PTYSession *)session {
    if (!engine || engine != _bufferSearch) {
        // A stale callback from a search the user has typed past.
        return;
    }
    if (!session) {
        _bufferSearchRunning = NO;
        [self updateNoResultsLabel];
        return;
    }
    NSString *guid = session.guid;
    if (!guid) {
        return;
    }
    // Not _table.numberOfRows: the table caches that until it is told about new rows.
    const NSInteger hitsBefore = _bufferHits.count;
    for (id<iTermGlobalSearchResultProtocol> result in results) {
        if (_bufferHits.count >= iTermOpenQuicklyMaxBufferHits) {
            break;
        }
        // A fold group is a container of other results; it has nothing to reveal itself.
        if ([(id)result isKindOfClass:[iTermGlobalSearchFoldGroup class]] || result.snippet.length == 0) {
            continue;
        }
        const NSInteger count = _bufferHitCounts[guid].integerValue;
        if (count >= iTermOpenQuicklyMaxBufferHitsPerSession) {
            break;
        }
        _bufferHitCounts[guid] = @(count + 1);
        [_bufferHits addObject:result];
    }
    const NSInteger added = (NSInteger)_bufferHits.count - hitsBefore;
    if (added > 0) {
        // Appending leaves the existing rows, and so the selection, untouched.
        const NSInteger firstNewRow = (NSInteger)self.model.items.count + hitsBefore;
        [_table insertRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(firstNewRow, added)]
                      withAnimation:NSTableViewAnimationEffectNone];
        if (_table.selectedRow < 0) {
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        }
        [self updateNoResultsLabel];
    }
    if (_bufferHits.count >= iTermOpenQuicklyMaxBufferHits) {
        [_bufferSearch stop];
        _bufferSearchRunning = NO;
        [self updateNoResultsLabel];
    }
}

// Returns the buffer hit shown in `row`, or nil if the row holds a model item.
- (id<iTermGlobalSearchResultProtocol>)bufferHitForRow:(NSInteger)row {
    const NSInteger index = row - (NSInteger)self.model.items.count;
    if (index < 0 || index >= (NSInteger)_bufferHits.count) {
        return nil;
    }
    return _bufferHits[index];
}

- (void)revealBufferHit:(id<iTermGlobalSearchResultProtocol>)hit {
    PTYSession *session = hit.session;
    if (!session) {
        return;
    }
    [session reveal];
    // Scrolling to a hit on the other screen (e.g. scrollback behind a running
    // vim) would flip the session's display, and nothing would flip it back
    // once the palette closes. Just bring the session forward in that case.
    iTermGlobalSearchResult *textHit = [iTermGlobalSearchResult castFrom:hit];
    if (textHit && textHit.onMainScreen == session.screen.showingAlternateScreen) {
        return;
    }
    [hit revealWithState:[NSMutableDictionary dictionary] completion:^(NSRect hull) {}];
}

- (IBAction)clearQuery:(id)sender {
    _textField.stringValue = @"";
    [self.window makeFirstResponder:_textField];
    [self update];
}

#pragma mark - Describing sessions

- (PTYSession *)sessionForRow:(NSInteger)row {
    id<iTermGlobalSearchResultProtocol> hit = [self bufferHitForRow:row];
    if (hit) {
        return hit.session;
    }
    if (row < 0 || row >= (NSInteger)self.model.items.count) {
        return nil;
    }
    id obj = [self.model objectAtIndex:row];
    if ([obj isKindOfClass:[PTYSession class]]) {
        return obj;
    }
    if ([obj isKindOfClass:[PseudoTerminal class]]) {
        return ((PseudoTerminal *)obj).currentSession;
    }
    if ([obj isKindOfClass:[iTermOpenQuicklyNamedMarkItem class]]) {
        return ((iTermOpenQuicklyNamedMarkItem *)obj).session;
    }
    return nil;
}

- (NSString *)directoryForSession:(PTYSession *)session {
    NSString *path = session.variablesScope.path;
    if (path.length == 0) {
        return nil;
    }
    id<VT100RemoteHostReading> host = session.currentHost;
    if (host && !host.isLocalhost) {
        return path;
    }
    return [path stringByAbbreviatingWithTildeInPath];
}

// “Window 2 · Tab 3 · Pane 2 of 3”
- (NSString *)locationForSession:(PTYSession *)session {
    PTYTab *tab = [PTYTab castFrom:session.delegate];
    PseudoTerminal *term = [PseudoTerminal castFrom:tab.realParentWindow];
    if (!tab || !term) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"OpenQuickly.WindowNumber", nil, [NSBundle mainBundle], @"Window %d", @"Open Quickly location of a session; %d is the window number"), term.number + 1]];
    const NSUInteger tabIndex = [term.tabs indexOfObject:tab];
    if (tabIndex != NSNotFound) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"OpenQuickly.TabNumber", nil, [NSBundle mainBundle], @"Tab %d", @"Open Quickly location of a session; %d is the tab number"), (int)tabIndex + 1]];
    }
    NSArray<PTYSession *> *panes = tab.sessions;
    const NSUInteger paneIndex = [panes indexOfObject:session];
    if (panes.count > 1 && paneIndex != NSNotFound) {
        [parts addObject:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"OpenQuickly.PaneNumber", nil, [NSBundle mainBundle], @"Pane %1$d of %2$d", @"Open Quickly location of a session within a split tab; first %d is the pane number, second is the number of panes"), (int)paneIndex + 1, (int)panes.count]];
    }
    // Localization unneeded: list separator between already-localized parts.
    return [parts componentsJoinedByString:@" · "];
}

// Subtitle for a session row when the query didn't match something more
// interesting: where it is and what it's running.
- (NSAttributedString *)subtitleForSession:(PTYSession *)session {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *directory = [self directoryForSession:session];
    if (directory) {
        [parts addObject:directory];
    }
    NSString *job = session.variablesScope.jobName;
    if (job.length) {
        [parts addObject:job];
    }
    NSString *location = [self locationForSession:session];
    if (location.length) {
        [parts addObject:location];
    }
    // Localization unneeded: list separator.
    return [[NSAttributedString alloc] initWithString:[parts componentsJoinedByString:@"  ·  "]];
}

- (NSArray<iTermOpenQuicklyPreviewFact *> *)factsForSession:(PTYSession *)session {
    NSMutableArray<iTermOpenQuicklyPreviewFact *> *facts = [NSMutableArray array];
    NSString *directory = [self directoryForSession:session];
    if (directory) {
        [facts addObject:[[iTermOpenQuicklyPreviewFact alloc] initWithKind:iTermOpenQuicklyPreviewFactKindDirectory text:directory]];
    }
    NSString *command = session.variablesScope.lastCommand ?: session.variablesScope.jobName;
    if (command.length) {
        [facts addObject:[[iTermOpenQuicklyPreviewFact alloc] initWithKind:iTermOpenQuicklyPreviewFactKindCommand text:command]];
    }
    id<VT100RemoteHostReading> host = session.currentHost;
    if (host && !host.isLocalhost) {
        [facts addObject:[[iTermOpenQuicklyPreviewFact alloc] initWithKind:iTermOpenQuicklyPreviewFactKindHost text:host.usernameAndHostname]];
    }
    NSString *profileName = session.profile[KEY_NAME];
    if (profileName.length) {
        [facts addObject:[[iTermOpenQuicklyPreviewFact alloc] initWithKind:iTermOpenQuicklyPreviewFactKindProfile text:profileName]];
    }
    return facts;
}

- (NSImage *)snapshotForSession:(PTYSession *)session {
    if (![session.guid isEqualToString:_snapshotGuid]) {
        // Only cache a successful render so a transient nil (e.g. textview not
        // yet laid out) doesn't lock in a blank preview.
        _snapshot = [session terminalContentSnapshot];
        _snapshotGuid = _snapshot ? [session.guid copy] : nil;
    }
    return _snapshot;
}

#pragma mark - Preview

- (void)refreshPreview {
    NSInteger row = _table.selectedRow;
    PTYSession *session = [self sessionForRow:row];
    if (!session && (row < 0 || row >= (NSInteger)self.model.items.count)) {
        [_previewPane showMessage:@""];
        return;
    }
    if (session) {
        [_previewPane showSessionWithTitle:session.name ?: @""
                                  location:[self locationForSession:session]
                                  snapshot:[self snapshotForSession:session]
                           backgroundColor:session.backgroundColor
                                     facts:[self factsForSession:session]];
        return;
    }
    iTermOpenQuicklyItem *item = self.model.items[row];
    [_previewPane showItemWithTitle:item.title.string ?: @""
                             detail:item.detail.string
                               icon:item.icon];
}

#pragma mark - Actions

// Bound to the close button.
- (IBAction)close:(id)sender {
    // Use orderOut, not close. -close on a non-activating panel can leave the
    // window in a state where the window-server refuses to re-elevate it on
    // subsequent shows from a background app (iTermProfileHotKey's floating
    // panel uses the same pattern).
    [self.window orderOut:nil];
    [self stopBufferSearch];
    _snapshot = nil;
    _snapshotGuid = nil;
}

// Observes NSWorkspaceActiveSpaceDidChangeNotification once. When the Space
// switch animation completes, macOS may pick a different app's window as
// frontmost on the destination Space; re-activate iTerm2 over a couple of
// runloop spins to win the race. Modeled on iTermProfileHotKey's
// activeSpaceDidChange: handling.
- (void)reassertActivationAfterSpaceChange {
    __block id token = nil;
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    token = [center addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
        if (token) {
            [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:token];
            token = nil;
        }
        // Two spins of the runloop, then re-activate if some other app stole
        // the focus during the Space transition.
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunningApplication *current = NSRunningApplication.currentApplication;
                if (![NSWorkspace.sharedWorkspace.frontmostApplication isEqual:current]) {
                    [current activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                }
            });
        });
    }];
    // Bail out after a short timeout so we don't leak the observer if no Space
    // change actually happens.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token) {
            [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:token];
            token = nil;
        }
    });
}

// Switch to the session associated with the currently selected row, closing
// this window.
- (void)openSelectedRow {
    // NSApp.isActive returns YES whenever our panel is key, even if iTerm2
    // isn't the frontmost app, so it's not a reliable check. Compare against
    // NSWorkspace.frontmostApplication to actually detect "we're in the
    // background".
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!frontmost || ![frontmost isEqual:NSRunningApplication.currentApplication]) {
        [[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        // If selecting a session triggers a Space switch (e.g. the user is in
        // another app's fullscreen Space and the chosen session lives on a
        // different Space), macOS often activates some other app once the
        // animation finishes. Re-assert iTerm2's frontmost status after the
        // active-Space change notification arrives.
        [self reassertActivationAfterSpaceChange];
    }
    NSInteger row = [_table selectedRow];

    id<iTermGlobalSearchResultProtocol> hit = [self bufferHitForRow:row];
    if (hit) {
        [self revealBufferHit:hit];
    } else if (row >= 0 && row < (NSInteger)self.model.items.count) {
        id object = [self.model objectAtIndex:row];
        DLog(@"%@", object);
        if ([object isKindOfClass:[PTYSession class]]) {
            // Switch to session
            PTYSession *session = object;
            [session reveal];
        } else if ([object isKindOfClass:[Profile class]]) {
            // Create a new tab/window
            Profile *profile = object;
            iTermProfileHotKey *profileHotkey = [[iTermHotKeyController sharedInstance] profileHotKeyForGUID:profile[KEY_GUID]];
            if (!profileHotkey || profileHotkey.windowController.weaklyReferencedObject) {
                // Create a new non-hotkey window
                [iTermSessionLauncher launchBookmark:profile
                                          inTerminal:[[iTermController sharedInstance] currentTerminal]
                                               style:iTermOpenStyleTab
                                             withURL:nil
                                    hotkeyWindowType:iTermHotkeyWindowTypeNone
                                             makeKey:YES
                                         canActivate:YES
                                  respectTabbingMode:NO
                                               index:nil
                                             command:nil
                                         makeSession:nil
                                      didMakeSession:nil
                                          completion:nil];
            } else {
                // Create the hotkey window for this profile
                [[iTermHotKeyController sharedInstance] showWindowForProfileHotKey:profileHotkey url:nil];
            }
        } else if ([object isKindOfClass:[PseudoTerminal class]]) {
            PseudoTerminal *term = object;
            if (term.isHotKeyWindow) {
                iTermProfileHotKey *profileHotkey = [[iTermHotKeyController sharedInstance] profileHotKeyForWindowController:term];
                [[iTermHotKeyController sharedInstance] showWindowForProfileHotKey:profileHotkey url:nil];
            } else {
                NSWindow *window = [object window];
                [window makeKeyAndOrderFront:nil];
            }
        } else if ([object isKindOfClass:[iTermOpenQuicklyArrangementItem class]]) {
            // Load window arrangement
            iTermOpenQuicklyArrangementItem *item = (iTermOpenQuicklyArrangementItem *)object;
            [[iTermController sharedInstance] loadWindowArrangementWithName:item.identifier asTabsInTerminal:item.inTabs ? [[iTermController sharedInstance] currentTerminal] : nil];
        } else if ([object isKindOfClass:[iTermOpenQuicklyChangeProfileItem class]]) {
            // Change profile
            iTermOpenQuicklyChangeProfileItem *item = object;
            PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
            PTYSession *session = term.currentSession;
            NSString *guid = [item identifier];
            Profile *profile = [[ProfileModel sharedInstance] bookmarkWithGuid:guid];
            if (profile) {
                [session setProfile:profile preservingName:YES];
                // Make sure the OS doesn't pick some random window to make key
                [term.window makeKeyAndOrderFront:nil];
            }
        } else if ([object isKindOfClass:[iTermOpenQuicklyHelpItem class]]) {
            iTermOpenQuicklyHelpItem *item = object;
            _textField.stringValue = [item identifier];
            [self update];
            return;
        } else if ([object isKindOfClass:[iTermOpenQuicklyScriptItem class]]) {
            iTermOpenQuicklyScriptItem *item = [iTermOpenQuicklyScriptItem castFrom:object];
            [[[[iTermApplication sharedApplication] delegate] scriptsMenuController] launchScriptWithRelativePath:item.identifier
                                                                                                        arguments:@[]
                                                                                               explicitUserAction:YES];
        } else if ([object isKindOfClass:[iTermOpenQuicklyColorPresetItem class]]) {
            iTermOpenQuicklyColorPresetItem *item = [iTermOpenQuicklyColorPresetItem castFrom:object];
            PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
            PTYSession *session = term.currentSession;
            [session setColorsFromPresetNamed:item.presetName];
        } else if ([object isKindOfClass:[iTermOpenQuicklyActionItem class]]) {
            iTermOpenQuicklyActionItem *item = [iTermOpenQuicklyActionItem castFrom:object];
            PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
            PTYSession *session = term.currentSession;
            [session applyAction:item.action];
        } else if ([object isKindOfClass:[iTermOpenQuicklySnippetItem class]]) {
            iTermOpenQuicklySnippetItem *item = [iTermOpenQuicklySnippetItem castFrom:object];
            PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
            PTYSession *session = term.currentSession;
            [session.textview sendSnippet:item];
        } else if ([object isKindOfClass:[iTermOpenQuicklyNamedMarkItem class]]) {
            iTermOpenQuicklyNamedMarkItem *item = [iTermOpenQuicklyNamedMarkItem castFrom:object];
            if (item.session) {
                [item.session reveal];
                [item.session scrollToNamedMark:item.namedMark];
            }
        } else if ([object isKindOfClass:[iTermOpenQuicklyMenuItem class]]) {
            iTermOpenQuicklyMenuItem *item = [iTermOpenQuicklyMenuItem castFrom:object];
            if (item.valid) {
                // Do it after this window is no longer around.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSApp sendAction:item.menuItem.action
                                   to:item.menuItem.target
                                 from:item.menuItem];
                });
            }
        } else {
            if ([object isKindOfClass:[iTermOpenQuicklyInvocationItem class]]) {
                iTermOpenQuicklyInvocationItem *item = [iTermOpenQuicklyInvocationItem castFrom:object];
                [iTermScriptFunctionCall callFunction:item.identifier
                                              timeout:[[NSDate distantFuture] timeIntervalSinceNow]
                                   sideEffectsAllowed:YES
                                                scope:item.scope
                                           retainSelf:YES
                                           completion:^(id value, NSError *error, NSSet<NSString *> *missing) {
                    if (error) {
                        [iTermAPIHelper reportFunctionCallError:error
                                                  forInvocation:item.identifier
                                                         origin:NSLocalizedStringWithDefaultValue(@"OpenQuickly.ErrorOrigin", nil, [NSBundle mainBundle], @"Open Quickly", @"Origin label shown when an Open Quickly function call reports an error")
                                                         window:nil];
                    } else {
                        [iTermWarning showWarningWithTitle:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"OpenQuickly.FunctionCallResultBody", nil, [NSBundle mainBundle], @"%1$@ returned:\n%2$@", @"Alert body showing a function call result; first %@ is the invocation and second is the returned value"), item.identifier, [value description]]
                                                   actions:@[ iTermLocalizedOK() ]
                                                 accessory:nil
                                                identifier:nil
                                               silenceable:kiTermWarningTypePersistent
                                                   heading:NSLocalizedStringWithDefaultValue(@"OpenQuickly.FunctionCallResultTitle", nil, [NSBundle mainBundle], @"Function Call Result", @"Alert title showing the result of a function call")
                                                    window:nil];
                    }
                }];
            } else {
                if ([iTermBrowserGateway browserAllowedCheckingIfNot:NO]) {
                    if ([object isKindOfClass:[iTermOpenQuicklyBookmarkItem class]]) {
                        iTermOpenQuicklyBookmarkItem *item = [iTermOpenQuicklyBookmarkItem castFrom:object];
                        PTYSession *session = iTermController.sharedInstance.currentTerminal.currentSession;
                        if (session.isBrowserSession) {
                            [session openURL:item.url];
                        } else {
                            [[iTermController sharedInstance] openURL:item.url
                                                               target:nil
                                                            openStyle:iTermOpenStyleTab
                                                            select:YES];
                        }
                    } else if ([object isKindOfClass:[iTermOpenQuicklyURLItem class]]) {
                        iTermOpenQuicklyURLItem *item = [iTermOpenQuicklyURLItem castFrom:object];
                        PTYSession *session = iTermController.sharedInstance.currentTerminal.currentSession;
                        if (session.isBrowserSession) {
                            [session openURL:item.url];
                        } else {
                            [[iTermController sharedInstance] openURL:item.url
                                                               target:nil
                                                            openStyle:iTermOpenStyleTab
                                                               select:YES];
                        }
                    }
                }
            }
        }
    }

    [self close:nil];
}

// ⌘1 through ⌘9 open that row directly.
- (BOOL)openRowForShortcutEvent:(NSEvent *)event {
    const NSEventModifierFlags mask = (NSEventModifierFlagOption |
                                       NSEventModifierFlagCommand |
                                       NSEventModifierFlagShift |
                                       NSEventModifierFlagControl);
    if ((event.modifierFlags & mask) != NSEventModifierFlagCommand) {
        return NO;
    }
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length != 1) {
        return NO;
    }
    const unichar c = [characters characterAtIndex:0];
    if (c < '1' || c > '9') {
        return NO;
    }
    const NSInteger row = c - '1';
    if (row >= _table.numberOfRows) {
        NSBeep();
        return YES;
    }
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [self openSelectedRow];
    return YES;
}

#pragma mark - NSTableViewDataSource and NSTableViewDelegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _model.items.count + _bufferHits.count;
}

- (NSString *)shortcutForRow:(NSInteger)row {
    if (row >= iTermOpenQuicklyMaxShortcutRow) {
        return nil;
    }
    // Localization unneeded: a key combination.
    return [NSString stringWithFormat:@"⌘%d", (int)row + 1];
}

- (void)configureSessionTile:(iTermOpenQuicklyTileView *)tile forSession:(PTYSession *)session {
    [tile configureSessionWithBackgroundColor:session.backgroundColor
                                    textColor:session.foregroundColor
                                  cursorColor:session.cursorColor
                                     tabColor:session.tabColor];
}

// A line of scrollback that matched: the line itself as the title, and which
// session it's in as the subtitle.
- (void)configureCell:(iTermOpenQuicklyPaletteCellView *)cell
         forBufferHit:(id<iTermGlobalSearchResultProtocol>)hit
                  row:(NSInteger)row {
    PTYSession *session = hit.session;
    [self configureSessionTile:cell.tile forSession:session];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (session.name.length) {
        [parts addObject:session.name];
    }
    NSString *location = [self locationForSession:session];
    if (location.length) {
        [parts addObject:location];
    }
    // Localization unneeded: list separator.
    NSAttributedString *subtitle = [[NSAttributedString alloc] initWithString:[parts componentsJoinedByString:@"  ·  "]];
    // Snippets can span soft-wrapped lines; keep the row to one line.
    NSMutableAttributedString *title = [hit.snippet mutableCopy];
    [title.mutableString replaceOccurrencesOfString:@"\n"
                                         withString:@" "
                                            options:0
                                              range:NSMakeRange(0, title.length)];
    [cell configureWithTitle:title subtitle:subtitle shortcut:[self shortcutForRow:row]];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    iTermOpenQuicklyPaletteCellView *cell = [tableView makeViewWithIdentifier:iTermOpenQuicklyPaletteCellView.reuseIdentifier owner:self];
    if (!cell) {
        cell = [[iTermOpenQuicklyPaletteCellView alloc] initWithFrame:NSZeroRect];
    }
    id<iTermGlobalSearchResultProtocol> hit = [self bufferHitForRow:row];
    if (hit) {
        [self configureCell:cell forBufferHit:hit row:row];
        return cell;
    }
    iTermOpenQuicklyItem *item = _model.items[row];
    NSAttributedString *title = item.title ?: [[NSAttributedString alloc] initWithString:NSLocalizedStringWithDefaultValue(@"OpenQuickly.Untitled", nil, [NSBundle mainBundle], @"Untitled", @"Fallback title for an untitled Open Quickly item")];
    NSAttributedString *subtitle = item.detail;

    PTYSession *session = [item isKindOfClass:[iTermOpenQuicklySessionItem class]] ? [self sessionForRow:row] : nil;
    if (session) {
        [self configureSessionTile:cell.tile forSession:session];
        if (subtitle.length == 0) {
            subtitle = [self subtitleForSession:session];
        }
    } else {
        [cell.tile configureIcon:item.icon];
    }
    [cell configureWithTitle:title subtitle:subtitle shortcut:[self shortcutForRow:row]];
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[iTermOpenQuicklyPaletteRowView alloc] init];
}

- (void)doubleClick:(id)sender {
    [self openSelectedRow];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self refreshPreview];
}

#pragma mark - NSWindowDelegate

- (id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)client {
    if (![client isKindOfClass:[iTermOpenQuicklyTextField class]]) {
        return nil;
    }
    if (!_textView) {
        _textView = [[iTermOpenQuicklyTextView alloc] init];
        [_textView setFieldEditor:YES];
    }
    return _textView;
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self close:nil];
}

#pragma mark - NSControlDelegate

// User changed query.
- (void)controlTextDidChange:(NSNotification *)notification {
    [self update];
}

// User pressed enter (or something else we don't care about).
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    int move = [[[notification userInfo] objectForKey:@"NSTextMovement"] intValue];

    switch (move) {
        case NSReturnTextMovement:  // Enter key
            [self openSelectedRow];
            break;
        default:
            break;
    }
}

// This makes ^N and ^P work.
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)commandSelector {
    BOOL result = NO;

    if (commandSelector == @selector(moveUp:) || commandSelector == @selector(moveDown:)) {
        NSInteger row = [_table selectedRow];
        if (row < 0) {
            row = 0;
        } else if (commandSelector == @selector(moveUp:)) {
            if (row > 0) {
                row--;
            } else {
                row = _table.numberOfRows - 1;
            }
        } else if (commandSelector == @selector(moveDown:)) {
            if (row + 1 < _table.numberOfRows) {
                row++;
            } else {
                row = 0;
            }
        }
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_table scrollRowToVisible:row];
        result = YES;
    }
    return result;
}

#pragma mark - iTermOpenQuicklyTextFieldDelegate

- (BOOL)openQuicklyTextFieldHandleKeyEquivalent:(NSEvent *)event {
    return [self openRowForShortcutEvent:event];
}

// Handle arrow keys while text field is key.
- (void)keyDown:(NSEvent *)theEvent {
    static BOOL running;
    const NSEventModifierFlags mask = (NSEventModifierFlagOption |
                                       NSEventModifierFlagCommand |
                                       NSEventModifierFlagShift |
                                       NSEventModifierFlagControl);
    if (theEvent.keyCode == kVK_Return && (theEvent.modifierFlags & mask) == NSEventModifierFlagOption) {
        [self openSelectedRow];
        return;
    }
    if (theEvent.keyCode == kVK_Escape) {
        [self close:nil];
        return;
    }
    if (!running) {
        running = YES;
        [_table keyDown:theEvent];
        running = NO;
    }
}

#pragma mark - iTermOpenQuicklyModelDelegate

- (id)openQuicklyModelDisplayStringForFeatureNamed:(NSString *)name
                                             value:(NSString *)value
                                highlightedIndexes:(NSIndexSet *)highlight {
    NSString *prefix;
    if (name) {
        prefix = [NSString stringWithFormat:@"%@: ", name];
    } else {
        prefix = @"";
    }
    NSMutableAttributedString *theString =
        [[NSMutableAttributedString alloc] initWithString:prefix
                                               attributes:[self attributes]];
    [theString appendAttributedString:[self attributedStringFromString:value
                                                 byHighlightingIndices:highlight]];
    return theString;
}

- (NSAttributedString *)openQuicklyModelAttributedStringForDetail:(NSString *)detail
                                                      featureName:(NSString *)featureName {
    NSString *composite;
    if (featureName) {
        composite = [NSString stringWithFormat:@"%@: %@", featureName, detail];
    } else {
        composite = detail;
    }
    return [self attributedStringFromString:composite
                      byHighlightingIndices:nil];
}

#pragma mark - String Formatting

// Mark characters in |source| at indices in |indexSet| with a bold font. The
// cell view restyles bold runs as fuzzy-match highlights. This isn't really
// appropriate for the model to do but it's much simpler and more efficient
// this way.
- (NSAttributedString *)attributedStringFromString:(NSString *)source
                             byHighlightingIndices:(NSIndexSet *)indexSet {
    NSMutableAttributedString *attributedString =
        [[NSMutableAttributedString alloc] initWithString:source attributes:[self attributes]];
    NSDictionary *highlight = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
                                 NSParagraphStyleAttributeName: [[self attributes] objectForKey:NSParagraphStyleAttributeName]
    };
    [indexSet enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [attributedString setAttributes:highlight range:NSMakeRange(idx, 1)];
    }];
    return attributedString;
}

- (NSDictionary *)attributes {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    return @{ NSFontAttributeName: [NSFont systemFontOfSize:13],
              NSParagraphStyleAttributeName: style };
}

@end
