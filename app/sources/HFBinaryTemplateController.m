//
//  HFBinaryTemplateController.m
//  HexFiend_2
//
//  Created by Kevin Wojniak on 1/7/18.
//  Copyright © 2018 ridiculous_fish. All rights reserved.
//

#import "HFBinaryTemplateController.h"
#import "HFTemplateNode.h"
#import "HFTclTemplateController.h"
#import "HFColorRange.h"
#import "HFDirectoryWatcher.h"
#import "HFTemplateFile.h"
#import "TemplateAutodetection.h"
#import "TemplateMetadata.h"
#import "MinimumVersionRequired.h"

@interface NSObject (HFTemplateOutlineViewDelegate)

- (NSMenu *)outlineView:(NSOutlineView *)sender menuForEvent:(NSEvent *)event;

@end

@interface HFTemplateOutlineView : NSOutlineView

@end

@implementation HFTemplateOutlineView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    if ([self.delegate respondsToSelector:@selector(outlineView:menuForEvent:)]) {
        return [(id)self.delegate outlineView:self menuForEvent:event];
    }
    return nil;
}

@end

@interface HFBinaryTemplateController () <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (weak) IBOutlet NSOutlineView *outlineView;
@property (weak) IBOutlet NSTextField *errorTextField;
@property (weak) IBOutlet NSPopUpButton *templatesPopUp;

@property HFController *controller;
@property HFTemplateNode *node;
@property NSArray<HFTemplateFile*> *templates;
@property NSArray<HFTemplateFile*> *bundleTemplates;
@property HFTemplateFile *selectedFile;
@property NSMutableArray<HFColorRange *> *colorRangesCovered;
@property NSMutableArray<HFColorRange *> *colorRangesHoles;
@property NSUInteger anchorPosition;
@property NSMutableArray *nodesToCollapse;
@property HFDirectoryWatcher *directoryWatcher;
@property TemplateAutodetection *autodetection;

@end

@implementation HFBinaryTemplateController

- (instancetype)init {
    if ((self = [super initWithNibName:@"BinaryTemplateController" bundle:nil]) != nil) {
        self.autodetection = [[TemplateAutodetection alloc] init];
    }
    return self;
}

- (void)awakeFromNib {
    self.outlineView.doubleAction = @selector(outlineViewDoubleAction:);
    self.outlineView.target = self;

    self.templatesPopUp.autoenablesItems = NO;
    [self loadTemplates:self];

    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:@"BinaryTemplateSelectionColor"
                                               options:0
                                               context:NULL];
}

- (void)dealloc {
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"BinaryTemplateSelectionColor" context:NULL];
}

- (void)viewDidAppear {
    [super viewDidAppear];

    [self showPopoverOnce];
    [self autodetectTemplate];
}

- (void)showPopoverOnce {
    NSString *key = @"BinaryTemplatesDisplayedWelcomePopover1";
    NSUserDefaults *userDefaults = NSUserDefaults.standardUserDefaults;
    id obj = [userDefaults objectForKey:key];
    if (!obj || ![obj isKindOfClass:[NSNumber class]] || ![obj boolValue]) {
        const NSTimeInterval popoverDelay = 0.25; // give the UI time to show
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(popoverDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showPopover];
        });
        [userDefaults setBool:YES forKey:key];
    }
}

- (void)showPopover {
    NSViewController *viewController = [[NSViewController alloc] initWithNibName:@"BinaryTemplatePopover" bundle:nil];
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = viewController;
    popover.behavior = NSPopoverBehaviorSemitransient;
    [popover showRelativeToRect:self.templatesPopUp.frame ofView:self.view preferredEdge:NSRectEdgeMinY];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> * __unused)change context:(void * __unused)context {
    if (object == [NSUserDefaults standardUserDefaults]) {
        if ([keyPath isEqualToString:@"BinaryTemplateSelectionColor"]) {
            [self updateSelectionColor];
        }
    }
}

- (NSString *)templatesFolder {
    return [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[NSBundle mainBundle].bundleIdentifier] stringByAppendingPathComponent:@"Templates"];
}

- (NSString *)bundleTemplatesPath {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"templates"];
}

- (NSString *)titleOfLastTemplate {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"BinaryTemplatesLastTemplate"];
}

- (void)saveTitleOfLastTemplate:(NSString *)title {
    NSString *key = @"BinaryTemplatesLastTemplate";
    if (title) {
        [[NSUserDefaults standardUserDefaults] setObject:title forKey:key];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
    }
}

- (void)reselectLastTemplate {
    [self.templatesPopUp selectItemWithTitle:self.titleOfLastTemplate];
}

- (void)openTemplatesFolder:(id __unused)sender {
    NSString *dir = self.templatesFolder;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert runModal];
    } else if (![[NSWorkspace sharedWorkspace] selectFile:nil inFileViewerRootedAtPath:dir]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Failed to open folder.", nil);
        [alert runModal];
    }
    [self reselectLastTemplate];
}

- (void)refresh:(id __unused)sender {
    [self loadTemplates:sender];
    [self rerunTemplate];
}

- (void)showPopover:(id)sender {
    [self showPopover];
    [self reselectLastTemplate];
}

- (NSString *)resolvePath:(NSString *)path {
    return [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path;
}

- (void)traversePath:(NSString *)dir intoTemplates:(NSMutableArray<HFTemplateFile*> *)templates {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *filename in [fm enumeratorAtPath:dir]) {
        if ([filename.pathExtension isEqualToString:@"tcl"]) {
            NSString *path = [dir stringByAppendingPathComponent:filename];
            TemplateMetadata *metadata = [[TemplateMetadata alloc] initWithPath:path];
            if (metadata.isHidden) {
                continue;
            }
            NSString *error = nil;
            if (metadata.minimumVersionRequired && ![MinimumVersionRequired isMinimumVersionSatisfied:metadata.minimumVersionRequired error:&error]) {
                NSLog(@"Min version error for %@: %@", path, error);
                continue;
            }
            HFTemplateFile *file = [[HFTemplateFile alloc] init];
            file.path = path;
            file.name = [[filename lastPathComponent] stringByDeletingPathExtension];
            file.supportedTypes = metadata.types;
            [templates addObject:file];
        } else {
            NSString *original = [dir stringByAppendingPathComponent:filename];
            NSString *resolved = [self resolvePath:original];
            BOOL isDir = NO;
            if (![original isEqual:resolved] &&
                [NSFileManager.defaultManager fileExistsAtPath:resolved isDirectory:&isDir] &&
                isDir) {
                [self traversePath:resolved intoTemplates:templates];
            }
        }
    }
}

- (void)loadTemplates:(id __unused)sender {
    // We resolve the templatesFolder in case it's a symlink
    NSString *dir = [self resolvePath:self.templatesFolder];
    NSMutableArray<HFTemplateFile*> *templates = [NSMutableArray array];
    [self traversePath:dir intoTemplates:templates];
    [templates sortUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES]]];
    [self.templatesPopUp removeAllItems];
    NSMenuItem *noneItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"None", nil) action:@selector(noTemplate:) keyEquivalent:@""];
    noneItem.target = self;
    [self.templatesPopUp.menu addItem:noneItem];
    [self.templatesPopUp.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *itemToSelect = noneItem;
    NSString *titleOfLastTemplate = self.titleOfLastTemplate;
    BOOL addedLocalTemplate = NO;
    if (templates.count > 0) {
        for (HFTemplateFile *file in templates) {
            if (!addedLocalTemplate) {
                NSMenuItem *localMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Local", nil) action:nil keyEquivalent:@""];
                localMenuItem.enabled = NO;
                [self.templatesPopUp.menu addItem:localMenuItem];
            }

            NSMenuItem *templateItem = [[NSMenuItem alloc] initWithTitle:file.name action:@selector(selectTemplateFile:) keyEquivalent:@""];
            templateItem.target = self;
            templateItem.representedObject = file;
            [self.templatesPopUp.menu addItem:templateItem];
            if (titleOfLastTemplate && [titleOfLastTemplate isEqualToString:templateItem.title]) {
                itemToSelect = templateItem;
            }
            addedLocalTemplate = YES;
        }
        [self.templatesPopUp.menu addItem:[NSMenuItem separatorItem]];
    }

    [self loadBundleTemplates:titleOfLastTemplate itemToSelect:&itemToSelect];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Refresh", nil) action:@selector(refresh:) keyEquivalent:@""];
    refreshItem.target = self;
    [self.templatesPopUp.menu addItem:refreshItem];

    NSMenuItem *openFolderItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open Templates Folder", nil) action:@selector(openTemplatesFolder:) keyEquivalent:@""];
    openFolderItem.target = self;
    [self.templatesPopUp.menu addItem:openFolderItem];

    NSMenuItem *showPopoverItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Show Welcome", nil) action:@selector(showPopover:) keyEquivalent:@""];
    showPopoverItem.target = self;
    [self.templatesPopUp.menu addItem:showPopoverItem];

    [self.templatesPopUp selectItem:itemToSelect];
    self.templates = templates;
    [self saveTitleOfLastTemplate:itemToSelect.title];
    self.selectedFile = itemToSelect.representedObject;
}

- (void)loadBundleTemplates:(NSString *)titleOfLastTemplate itemToSelect:(NSMenuItem **)itemToSelect {
    NSString *bundleTemplatesPath = self.bundleTemplatesPath;
    NSDirectoryEnumerator *bundleTemplatesEnumerator = [NSFileManager.defaultManager enumeratorAtPath:bundleTemplatesPath];
    NSArray *bundleTemplatesPaths = [bundleTemplatesEnumerator.allObjects sortedArrayUsingSelector:@selector(compare:)];
    BOOL addedBundleTemplate = NO;
    NSMutableSet<NSString *> *folders = [NSMutableSet set];
    NSMutableArray<HFTemplateFile *> *bundleTemplates = [NSMutableArray array];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *bundleTemplateFilename in bundleTemplatesPaths) {
        if (![bundleTemplateFilename containsString:@"/"] && [bundleTemplateFilename containsString:@"."]) {
            // Skip top-level files
            continue;
        }

        NSString *bundleTemplatePath = [bundleTemplatesPath stringByAppendingPathComponent:bundleTemplateFilename];
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:bundleTemplatePath isDirectory:&isDir] && isDir) {
            // Skip directories
            continue;
        }
        
        TemplateMetadata *metadata = [[TemplateMetadata alloc] initWithPath:bundleTemplatePath];
        if (metadata.isHidden) {
            continue;
        }

        NSString *error = nil;
        if (metadata.minimumVersionRequired && ![MinimumVersionRequired isMinimumVersionSatisfied:metadata.minimumVersionRequired error:&error]) {
            NSLog(@"Min version error for %@: %@", bundleTemplatePath, error);
            continue;
        }

        NSMutableArray *pathComponents = [bundleTemplateFilename.pathComponents mutableCopy];
        [pathComponents removeLastObject];
        NSString *folderKey = @"";
        for (NSString *pathComponent in pathComponents) {
            folderKey = [folderKey stringByAppendingFormat:@"%@/", pathComponent];
            if (![folders containsObject:folderKey]) {
                NSMenuItem *folderMenuItem = [[NSMenuItem alloc] initWithTitle:pathComponent action:nil keyEquivalent:@""];
                folderMenuItem.enabled = NO;
                [self.templatesPopUp.menu addItem:folderMenuItem];
                [folders addObject:folderKey];
            }
        }

        HFTemplateFile *file = [[HFTemplateFile alloc] init];
        file.path = bundleTemplatePath;
        file.name = bundleTemplateFilename.lastPathComponent.stringByDeletingPathExtension;
        file.supportedTypes = metadata.types;
        [bundleTemplates addObject:file];
        NSMenuItem *templateMenuItem = [[NSMenuItem alloc] initWithTitle:file.name action:@selector(selectTemplateFile:) keyEquivalent:@""];
        templateMenuItem.target = self;
        templateMenuItem.representedObject = file;
        templateMenuItem.indentationLevel = 1;
        [self.templatesPopUp.menu addItem:templateMenuItem];

        if (titleOfLastTemplate && [titleOfLastTemplate isEqualToString:templateMenuItem.title]) {
            *itemToSelect = templateMenuItem;
        }

        addedBundleTemplate = YES;
    }
    if (addedBundleTemplate) {
        [self.templatesPopUp.menu addItem:[NSMenuItem separatorItem]];
    }
    self.bundleTemplates = bundleTemplates;
}

- (void)noTemplate:(id __unused)sender {
    self.selectedFile = nil;
    [self setRootNode:nil error:nil];
    [self saveTitleOfLastTemplate:nil];
}

- (void)selectTemplateFile:(id)sender {
    HFASSERT([sender isKindOfClass:[NSMenuItem class]]);
    NSMenuItem *item = (NSMenuItem *)sender;
    self.selectedFile = item.representedObject;
    [self rerunTemplate];
    [self saveTitleOfLastTemplate:item.title];
}

- (void)rerunTemplate {
    HFASSERT(self.controller != nil);
    [self rerunTemplateWithController:self.controller];
}

- (void)rerunTemplateWithController:(HFController *)controller {
    HFASSERT(controller != nil);
    _controller = controller;
    if (!self.selectedFile || self.controller.contentsLength == 0) {
        return;
    }
    NSString *errorMessage = nil;
    HFTclTemplateController *templateController = [[HFTclTemplateController alloc] init];
    templateController.anchor = self.anchorPosition;
    templateController.templatesFolder = self.templatesFolder;
    templateController.bundleTemplatesPath = self.bundleTemplatesPath;

    // Change directory to the templates folder so "source" command can use relative paths
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *currentDir = fm.currentDirectoryPath;
    if (![fm changeCurrentDirectoryPath:self.templatesFolder]) {
        NSLog(@"Failed to change directory to %@", self.templatesFolder);
    }
    
    HFTemplateNode *node = [templateController evaluateScript:self.selectedFile.path forController:controller error:&errorMessage];

    // Restore current directory
    (void)[fm changeCurrentDirectoryPath:currentDir];
    
    [self setRootNode:node error:errorMessage];
    self.nodesToCollapse = [templateController.initiallyCollapsed mutableCopy];
    [self collapseNodesIfNeeded];
    [self updateSelectionColorRange];
}

- (id)outlineView:(NSOutlineView * __unused)outlineView child:(NSInteger)index ofItem:(id)item {
    HFTemplateNode *node = item != nil ? item : self.node;
    return [node.children objectAtIndex:index];
}

- (NSInteger)outlineView:(NSOutlineView * __unused)outlineView numberOfChildrenOfItem:(id)item {
    HFTemplateNode *node = item != nil ? item : self.node;
    return node.children.count;
}

- (BOOL)outlineView:(NSOutlineView * __unused)outlineView isItemExpandable:(id)item {
    HFTemplateNode *node = item;
    return node.isGroup;
}

- (id)outlineView:(NSOutlineView * __unused)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
    HFTemplateNode *node = item;
    NSString *ident = tableColumn.identifier;
    if ([ident isEqualToString:@"name"]) {
        return node.label;
    }
    if ([ident isEqualToString:@"value"]) {
        return node.value;
    }
    return nil;
}

- (void)collapseValuedGroups {
    NSOutlineView *outlineView = self.outlineView;
    NSInteger numberOfRows = outlineView.numberOfRows;
    for (NSInteger i = numberOfRows - 1; i >= 0; --i) {
        HFTemplateNode *node = [outlineView itemAtRow:i];
        if (node.isGroup && node.value) {
            [outlineView collapseItem:node];
        }
    }
}

- (void)collapseNodesIfNeeded {
    NSOutlineView *outlineView = self.outlineView;
    // We only want to collapse nodes once
    NSMutableArray *nodesThatWereCollapsed = [NSMutableArray array];
    for (HFTemplateNode *node in self.nodesToCollapse) {
        if ([outlineView isItemExpanded:node]) {
            [outlineView collapseItem:node];
            [nodesThatWereCollapsed addObject:node];
        }
    }
    [self.nodesToCollapse removeObjectsInArray:nodesThatWereCollapsed];
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    [self collapseNodesIfNeeded];
}

- (void)setRootNode:(HFTemplateNode *)node error:(NSString *)error {
    if (error != nil) {
        self.node = nil;
        self.errorTextField.stringValue = error;
        self.errorTextField.hidden = NO;
    } else {
        self.node = node;
        self.errorTextField.hidden = YES;
    }
    [self.outlineView reloadData];
    [self.outlineView expandItem:nil expandChildren:YES];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"BinaryTemplatesAutoCollapseValuedGroups"]) {
        [self collapseValuedGroups];
    }
}

- (NSColor *)selectionColor {
    NSColor *color = [NSColor lightGrayColor];
    NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:@"BinaryTemplateSelectionColor"];
    if (colorData && [colorData isKindOfClass:[NSData class]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // TODO: When 10.14 becomes the minimum target, replace NSUnarchiver/NSArchiver
        // with NSKeyedUnarchiver/NSKeyedArchiver versions.
        // This can't be easily done until then because in Preferences.xib NSUnarchiveFromData
        // is used with the binding. The non-deprecated replacement is NSSecureUnarchiveFromData,
        // but that requires 10.14.
        // @available(macOS 10.14, *) ---- this is a token so this code is found later...
        NSColor *tempColor = [NSUnarchiver unarchiveObjectWithData:colorData];
#pragma clang diagnostic pop
        if (tempColor && [tempColor isKindOfClass:[NSColor class]]) {
            color = tempColor;
        }
    }
    return color;
}

- (NSColor *)backgroundColor {
    // why doesn't this change when dark mode changes?
    // return [NSColor textBackgroundColor];

    // Why doesn't HFDarkModeEnabled() work from HFBinaryTemplateController but does work elsewhere?
    // The appearance name doesn't change for HFBinaryTemplateController.
    if (HFDarkModeEnabled()) {
        return [NSColor colorWithCalibratedWhite:22/255.0 alpha:1];
    }
    else
    {
        return [NSColor colorWithCalibratedWhite:1 alpha:1];
    }
}

- (NSColor *)holeColor {
    NSColorSpace * colorSpace = [NSColorSpace genericRGBColorSpace];
    HFColor * sel = [self selectionColor];
    NSColor * rgbSel = [sel colorUsingColorSpace:colorSpace];
    HFColor * bg = [self backgroundColor];
    HFColor * rgbBg = [bg colorUsingColorSpace:colorSpace];

    CGFloat blend = 0.44;
    HFColor * hole = [NSColor
        colorWithCalibratedRed:rgbSel.redComponent   * blend + rgbBg.redComponent   * (1 - blend)
                         green:rgbSel.greenComponent * blend + rgbBg.greenComponent * (1 - blend)
                          blue:rgbSel.blueComponent  * blend + rgbBg.blueComponent  * (1 - blend)
                         alpha:1
    ];
    return hole;
}

- (void)updateSelectionColor {
    BOOL colorsChanged = false;
    if (self.colorRangesCovered && self.colorRangesCovered.count) {
        HFColor * sel = [self selectionColor];
        for (HFColorRange *obj in self.colorRangesCovered) {
            obj.color = sel;
        }
        colorsChanged = true;
    }
    if (self.colorRangesHoles && self.colorRangesHoles.count) {
        HFColor * hole = [self holeColor];
        for (HFColorRange *obj in self.colorRangesHoles) {
            obj.color = hole;
        }
        colorsChanged = true;
    }
    if (colorsChanged)
        [self.controller colorRangesDidChange];
}

- (void)updateSelectionColorRange {
    NSInteger row = self.outlineView.selectedRow;

    BOOL colorsChanged = false;
    if (self.colorRangesCovered && self.colorRangesCovered.count) {
        [self.controller.colorRanges removeObjectsInArray:self.colorRangesCovered];
        [self.colorRangesCovered removeAllObjects];
        colorsChanged = true;
    }
    if (self.colorRangesHoles && self.colorRangesHoles.count) {
        [self.controller.colorRanges removeObjectsInArray:self.colorRangesHoles];
        [self.colorRangesHoles removeAllObjects];
        colorsChanged = true;
    }

    if (row != -1) {
        HFTemplateNode *node = [self.outlineView itemAtRow:row];
        if (node.ranges.count) {
            if (!self.colorRangesCovered)
                self.colorRangesCovered = [[NSMutableArray alloc] init];
            if (!self.colorRangesHoles)
                self.colorRangesHoles = [[NSMutableArray alloc] init];
            HFColor * sel = [self selectionColor];
            HFColor * hole = [self holeColor];
            BOOL havePrevious = false;
            unsigned long long previousMax = 0;
            for (HFRangeWrapper *range in node.ranges) {
                if (havePrevious && previousMax < range.HFRange.location) {
                    HFColorRange * colorRange = [[HFColorRange alloc] init];
                    colorRange.color = hole;
                    colorRange.range = [HFRangeWrapper withRange:HFRangeMake(previousMax, range.HFRange.location - previousMax)];
                    [self.colorRangesHoles addObject:colorRange];
                    colorsChanged = true;
                }
                if (range.HFRange.length) {
                    HFColorRange * colorRange = [[HFColorRange alloc] init];
                    colorRange.color = sel;
                    colorRange.range = range;
                    [self.colorRangesCovered addObject:colorRange];
                    colorsChanged = true;
                }
                havePrevious = true;
                previousMax = HFMaxRange(range.HFRange);
            }
        }
    }

    if (colorsChanged) {
        if (self.colorRangesCovered)
            [self.controller.colorRanges addObjectsFromArray:self.colorRangesCovered];
        if (self.colorRangesHoles)
            [self.controller.colorRanges addObjectsFromArray:self.colorRangesHoles];
        [self.controller colorRangesDidChange];
    }
}

- (void)outlineViewSelectionDidChange:(NSNotification * __unused)notification {
    [self updateSelectionColorRange];
    
    if (self.outlineView.numberOfSelectedRows == 1) {
        NSInteger action = [[NSUserDefaults standardUserDefaults] integerForKey:@"BinaryTemplatesSingleClickAction"];
        switch (action) {
            case 0: // do nothing
                break;
            case 1: // scroll to offset
                [self jumpToField:nil];
                break;
            case 2: // select bytes
                [self selectBytes:nil];
                break;
            default:
                NSLog(@"Unknown single click action %ld", action);
        }
    }
}

- (NSMenu *)outlineView:(NSOutlineView *)sender menuForEvent:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    NSPoint loc = [sender convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [sender rowAtPoint:loc];
    [sender selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    id obj = row != -1 ? [sender itemAtRow:row] : nil;
    NSMenuItem *item;

    item = [menu addItemWithTitle:NSLocalizedString(@"Scroll to Offset", nil) action:@selector(jumpToField:) keyEquivalent:@""];
    item.target = self;
    item.enabled = obj != nil;
    
    item = [menu addItemWithTitle:NSLocalizedString(@"Copy Value", nil) action:@selector(copyValue:) keyEquivalent:@""];
    item.target = self;
    item.enabled = obj != nil;
    
    item = [menu addItemWithTitle:NSLocalizedString(@"Select Bytes", nil) action:@selector(selectBytes:) keyEquivalent:@""];
    item.target = self;
    item.enabled = obj != nil;

    return menu;
}

- (void)outlineViewDoubleAction:(id)sender {
    HFASSERT(sender == self.outlineView);
    NSInteger row = self.outlineView.clickedRow;
    if (row != -1) {
        NSInteger action = [[NSUserDefaults standardUserDefaults] integerForKey:@"BinaryTemplatesDoubleClickAction"];
        switch (action) {
            case 0: // do nothing
                break;
            case 1: // scroll to offset
                [self jumpToField:sender];
                break;
            case 2: // select bytes
                [self selectBytes:sender];
                break;
            default:
                NSLog(@"Unknown double click action %ld", action);
        }
    }
}

- (void)jumpToField:(id __unused)sender {
    HFTemplateNode *node = [self.outlineView itemAtRow:[self.outlineView selectedRow]];
    HFRangeWrapper *first = [node.ranges firstObject];
    HFRange range = HFRangeMake(first.HFRange.location, 0);
    [self.controller setSelectedContentsRanges:@[[HFRangeWrapper withRange:range]]];
    [self.controller maximizeVisibilityOfContentsRange:range];
}

- (void)anchorTo:(NSUInteger)position {
    self.anchorPosition = position;
    [self rerunTemplate];
}

typedef struct {
    HFTemplateNode * best_node;
    HFRange best_range;
    int best_depth;
    NSUInteger position;
} HFSearchState;

- (void)findAndExpandDeepestNodeForPosition:(NSUInteger)position startAt:(HFTemplateNode *)node depth:(int)depth state:(HFSearchState *)state {
    if (node) {
        HFRangeWrapper * first = [node.ranges firstObject];
        HFRangeWrapper * last = [node.ranges lastObject];
        unsigned long long loc = first.HFRange.location;
        unsigned long long len = HFMaxRange(last.HFRange) - loc;
        HFRange range = HFRangeMake(loc, len);
        
        if (HFLocationInRange(position, range)) {
            if (
                !state->best_node || (
                    range.length < state->best_range.length || (
                        range.length == state->best_range.length && (
                            range.location > state->best_range.location || (
                                range.location == state->best_range.location && (
                                    depth > state->best_depth
                                )
                            )
                        )
                    )
                )
            ) {
                state->best_node = node;
                state->best_range = range;
                state->best_depth = depth;
            }
        }
        if (node.children) {
            for (HFTemplateNode *childNode in node.children) {
                [self findAndExpandDeepestNodeForPosition:position startAt:childNode depth:(depth + 1) state:state];
            }
        }
    }
}

- (void)outlineViewToChild:(HFTemplateNode *)node {
    if (node && node.parent) {
        [self outlineViewToChild:node.parent];
        [self.outlineView expandItem:node.parent];
    }
}

- (void)showInTemplateAt:(NSUInteger)position {
    if (self.node == nil) {
        return;
    }
    HFSearchState state = { 0 };
    [self findAndExpandDeepestNodeForPosition:position startAt:self.node depth:0 state:&state];
    if (state.best_node) {
        [self outlineViewToChild:state.best_node];
        NSInteger itemIndex = [self.outlineView rowForItem:state.best_node];
        if (itemIndex < 0) {
            return;
        }
        [self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:itemIndex] byExtendingSelection:NO];
        [self.outlineView scrollRowToVisible:itemIndex];
    }
}

- (void)copyValue:(id __unused)sender {
    HFTemplateNode *node = [self.outlineView itemAtRow:[self.outlineView selectedRow]];
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];
    [pboard clearContents];
    [pboard setString:node.value forType:NSPasteboardTypeString];
}

- (void)selectBytes:(id __unused)sender {
    HFTemplateNode *node = [self.outlineView itemAtRow:[self.outlineView selectedRow]];
    HFRangeWrapper * first = [node.ranges firstObject];
    HFRangeWrapper * last = [node.ranges lastObject];
    unsigned long long loc = first.HFRange.location;
    unsigned long long len = HFMaxRange(last.HFRange) - loc;
    HFRange range = HFRangeMake(loc, len);
    [self.controller setSelectedContentsRanges:@[[HFRangeWrapper withRange:range]]];
}

- (void)copy:(id)sender {
    // NSResponder chain from Edit > Copy
    if (self.outlineView.numberOfSelectedRows > 0) {
        [self copyValue:sender];
    }
}

- (BOOL)hasTemplate {
    return self.node != nil;
}

- (void)viewWillAppear {
    self.directoryWatcher = [[HFDirectoryWatcher alloc] initWithPath:self.templatesFolder handler:^{
        NSLog(@"Templates directory changed");
        [self loadTemplates:self];
        [self rerunTemplate];
    }];
}

- (void)viewWillDisappear {
    [self.directoryWatcher stop];
    self.directoryWatcher = nil;
}

- (void)autodetectTemplate {
    NSURL *representedURL = self.view.window.representedURL;
    if (!representedURL) {
        return;
    }
    NSArray<HFTemplateFile *> *allTemplates = [self.templates arrayByAddingObjectsFromArray:self.bundleTemplates];
    HFTemplateFile *template = [self.autodetection defaultTemplateForFileAtURL:representedURL allTemplates:allTemplates];
    if (template) {
        self.selectedFile = template;
        [self.templatesPopUp selectItemWithTitle:template.name];
        [self rerunTemplate];
    }
}

@end
