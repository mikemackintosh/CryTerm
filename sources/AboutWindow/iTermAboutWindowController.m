//
//  iTermAboutWindowController.m
//  iTerm2
//
//  Created by George Nachman on 9/21/14.
//
//

#import "iTermAboutWindowController.h"

#import "iTerm2SharedARC-Swift.h"
#import "iTermLaunchExperienceController.h"
#import "NSAppearance+iTerm.h"
#import "NSArray+iTerm.h"
#import "NSColor+iTerm.h"
#import "NSMutableAttributedString+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSStringITerm.h"

static NSString *iTermAboutWindowControllerWhatsNewURLString = @"iterm2://whats-new/";
static NSString *const iTermAboutWindowHomePageURLString = @"https://github.com/mikemackintosh/CryTerm";
static NSString *const iTermAboutWindowReportBugURLString = @"https://github.com/mikemackintosh/CryTerm/issues";
// iTerm2's contributors, credited for the code CryTerm is built on.
static NSString *const iTermAboutWindowCreditsURLString = @"https://iterm2.com/credits";
static NSString *const iTermAboutWindowUpstreamURLString = @"https://iterm2.com/";
static NSString *const iTermAboutWindowLicenseURLString = @"https://github.com/mikemackintosh/CryTerm/blob/master/LICENSE";

// The window reads top to bottom like a credits roll: who made it, who
// sponsors it, who backs it, and how to join them. The header puts the icon
// beside a left-aligned column of title, byline, version and buttons, with the
// pair centred. Every measure below is on an 8pt scale except where type sets
// it.
static const CGFloat kAboutSideMargin = 24.0;
static const CGFloat kAboutTopMargin = 28.0;
static const CGFloat kAboutBottomMargin = 24.0;
// macOS app icons draw their artwork in the middle 824 of 1024 points, leaving
// transparent padding around it. The icon is sized so the artwork, not the
// padded image, spans the text column from the title down to the buttons.
static const CGFloat kAboutIconArtworkFraction = 824.0 / 1024.0;
static const CGFloat kAboutIconToTextGap = 20.0;
// Text fields draw their text this far inside their frames; shifting them out
// by it lines their text up with the version line and the buttons.
static const CGFloat kAboutLabelInset = 2.0;
static const CGFloat kAboutTitleToBylineGap = 4.0;
static const CGFloat kAboutBylineToVersionGap = 4.0;
static const CGFloat kAboutVersionToButtonsGap = 16.0;
static const CGFloat kAboutButtonSpacing = 8.0;
static const CGFloat kAboutSectionGap = 28.0;

static const CGFloat kAboutTitleFontSize = 22.0;
static const CGFloat kAboutBylineFontSize = 13.0;
static const CGFloat kAboutVersionFontSize = 12.0;
static const CGFloat kAboutEyebrowFontSize = 11.0;
static const CGFloat kAboutEyebrowTracking = 0.08;
static const CGFloat kAboutFooterFontSize = 12.0;
// Single-line text views for the build line and the footer.
static const CGFloat kAboutVersionLineHeight = 18.0;
static const CGFloat kAboutFooterLineHeight = 20.0;
// CryTerm's footer is the two-line GPL attribution.
static const CGFloat kAboutAttributionFooterHeight = kAboutFooterLineHeight * 2;

static const CGFloat kSponsorImageHeight = 32.0;
static const CGFloat kSponsorPaddingVertical = 12.0;
static const CGFloat kSponsorPaddingHorizontal = 16.0;
static const CGFloat kSponsorSpacing = 12.0;
static const CGFloat kSponsorImageToLabelGap = 12.0;

// Keeps the window on screen when the backer list is long; past this the well
// scrolls instead of the window growing.
static const CGFloat kAboutScreenMargin = 40.0;

// Corner radius shared by the sponsor cards and the backer well, so the two
// containers read as one system. Tahoe's window chrome is rounder than its
// predecessors', and the containers follow it.
static const CGFloat kContainerCornerRadiusTahoe = 12.0;
static const CGFloat kContainerCornerRadiusLegacy = 8.0;

// Before macOS 26, dark themes get a frosted-glass treatment and light themes
// keep the stock window, so this only ever applies when the theme is dark.
// Translucent black behind the backers so small text stays legible over the
// blur. Dark enough to read as a step down from the glass, light enough that
// the desktop still shows faintly through it.
static const CGFloat kDarkBackersScrimAlpha = 0.28;

static CGFloat iTermAboutContainerCornerRadius(void) {
    if (@available(macOS 26, *)) {
        return kContainerCornerRadiusTahoe;
    }
    return kContainerCornerRadiusLegacy;
}

// One fill for every container in the window, so the sponsor cards and the
// backer well read as the same surface.
static NSColor *iTermAboutContainerFillColor(void) {
    return [NSColor it_dynamicColorForLightMode:[NSColor colorWithWhite:0.0 alpha:0.04]
                                       darkMode:[NSColor colorWithWhite:1.0 alpha:0.08]];
}

// A logo with a flat colour baked into the image has all four corners opaque
// and the same colour. Returns that colour, or nil for a transparent logo or
// one whose corners disagree (a gradient, a photo), which is left on the
// neutral fill rather than guessed at.
static NSColor *iTermAboutBakedBackgroundColorOfImage(NSImage *image) {
    static const CGFloat kOpaqueAlpha = 0.98;
    static const CGFloat kChannelTolerance = 4.0 / 255.0;
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        return nil;
    }
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    const NSInteger maxX = bitmap.pixelsWide - 1;
    const NSInteger maxY = bitmap.pixelsHigh - 1;
    if (maxX < 0 || maxY < 0) {
        return nil;
    }
    NSColor *reference = nil;
    for (NSValue *corner in @[ [NSValue valueWithPoint:NSMakePoint(0, 0)],
                               [NSValue valueWithPoint:NSMakePoint(maxX, 0)],
                               [NSValue valueWithPoint:NSMakePoint(0, maxY)],
                               [NSValue valueWithPoint:NSMakePoint(maxX, maxY)] ]) {
        NSColor *color = [[bitmap colorAtX:corner.pointValue.x y:corner.pointValue.y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!color || color.alphaComponent < kOpaqueAlpha) {
            return nil;
        }
        if (!reference) {
            reference = color;
            continue;
        }
        if (fabs(color.redComponent - reference.redComponent) > kChannelTolerance ||
            fabs(color.greenComponent - reference.greenComponent) > kChannelTolerance ||
            fabs(color.blueComponent - reference.blueComponent) > kChannelTolerance) {
            return nil;
        }
    }
    return reference;
}

// Layer properties on the views AppKit manages get reset on the next display
// pass, so anything that paints a container does it from updateLayer.
@interface iTermSponsorBoxView : NSView
// The logo's own background when it has one baked in, so the card becomes a
// tile of that colour and the image's edge disappears into it.
@property (nonatomic, strong) NSColor *bakedBackgroundColor;
@end

@implementation iTermSponsorBoxView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    [super updateLayer];
    self.layer.cornerRadius = iTermAboutContainerCornerRadius();
    self.layer.backgroundColor = (self.bakedBackgroundColor ?: iTermAboutContainerFillColor()).CGColor;
    // A hairline keeps a tile readable as a card whatever colour it turned out
    // to be: a white tile on the light window, a dark one on the dark window.
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor it_dynamicColorForLightMode:[NSColor colorWithWhite:0.0 alpha:0.08]
                                                         darkMode:[NSColor colorWithWhite:1.0 alpha:0.10]].CGColor;
}
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

// Sits behind the backers scroll view. On macOS 26 it is a container like the
// sponsor cards; before that it is the dark scrim over the frosted glass.
@interface iTermAboutBackersWellView : NSView
@end

@implementation iTermAboutBackersWellView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    [super updateLayer];
    self.layer.cornerRadius = iTermAboutContainerCornerRadius();
    if (@available(macOS 26, *)) {
        self.layer.backgroundColor = iTermAboutContainerFillColor().CGColor;
    } else {
        self.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:kDarkBackersScrimAlpha].CGColor;
    }
}
@end

@interface iTermSponsor: NSObject
@property (nonatomic) NSView *view;
@property (nonatomic, copy) NSString *url;
@end

@implementation iTermSponsor
@end

// Button actions travel up the responder chain to the window controller.
@interface iTermAboutWindowController (Actions)
- (IBAction)openHomePage:(id)sender;
- (IBAction)reportBug:(id)sender;
- (IBAction)openCredits:(id)sender;
@end

@interface iTermAboutWindowContentView : NSVisualEffectView
// Height the content wants for the given height of the backer list, before
// the screen cap is applied.
- (CGFloat)preferredHeightForBackersHeight:(CGFloat)backersHeight;
- (void)setBackersCount:(NSInteger)count;
@end

@implementation iTermAboutWindowContentView {
    IBOutlet NSImageView *_iconView;
    IBOutlet NSTextField *_titleField;
    IBOutlet NSTextField *_bylineField;
    IBOutlet NSScrollView *_versionScrollView;
    IBOutlet NSScrollView *_bottomAlignedScrollView;
    IBOutlet NSScrollView *_footerScrollView;
    IBOutlet NSTextView *_sponsorsHeading;

    NSArray<iTermSponsor *> *_sponsors;
    NSArray<NSButton *> *_buttons;
    NSTextField *_sponsorsEyebrow;
    NSTextField *_backersEyebrow;
    iTermAboutBackersWellView *_backersWell;
    NSVisualEffectMaterial _stockMaterial;
    // Set once awakeFromNib has captured the nib's material. Until then there is
    // no stock material to fall back to and no _backersWell to toggle.
    BOOL _ready;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    _stockMaterial = self.material;

    _titleField.font = [NSFont systemFontOfSize:kAboutTitleFontSize weight:NSFontWeightSemibold];
    _titleField.textColor = [NSColor labelColor];
    _bylineField.font = [NSFont systemFontOfSize:kAboutBylineFontSize];
    _bylineField.textColor = [NSColor secondaryLabelColor];
    _titleField.alignment = NSTextAlignmentLeft;
    _bylineField.alignment = NSTextAlignmentLeft;
    NSTextView *versionTextView = [NSTextView castFrom:_versionScrollView.documentView];
    versionTextView.textContainer.lineFragmentPadding = 0;
    versionTextView.textContainerInset = NSZeroSize;

    _buttons = @[
        [self makeButtonWithTitle:NSLocalizedStringWithDefaultValue(@"AboutWindow.HomePage", nil, [NSBundle mainBundle], @"Home Page", @"Button title in the about window that opens the CryTerm home page")
                           action:@selector(openHomePage:)],
        [self makeButtonWithTitle:NSLocalizedStringWithDefaultValue(@"AboutWindow.ReportBug", nil, [NSBundle mainBundle], @"Report a Bug", @"Button title in the about window that opens the bug reporting page")
                           action:@selector(reportBug:)],
        [self makeButtonWithTitle:NSLocalizedStringWithDefaultValue(@"AboutWindow.Credits", nil, [NSBundle mainBundle], @"Credits", @"Button title in the about window that opens the credits page")
                           action:@selector(openCredits:)],
    ];

    // CryTerm shows none of iTerm2's sponsors, backers, or the invitation to
    // support it: they support upstream, not this build. The sponsor and backer
    // views stay unbuilt (nil) and the backer list from the nib stays hidden.
    _sponsors = @[];
    _bottomAlignedScrollView.hidden = YES;

    // The footer is the GPL attribution instead.
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    _sponsorsHeading.selectable = YES;
    _sponsorsHeading.editable = NO;
    [_sponsorsHeading.textStorage setAttributedString:[self attributionWithParagraphStyle:paragraphStyle]];

    _ready = YES;
    [self applyAppearanceTreatment];
    [self layoutContent];
}

// “CryTerm is a modified version of iTerm2 …” linking to iTerm2, and the license on
// the line below linking to the license text.
- (NSAttributedString *)attributionWithParagraphStyle:(NSParagraphStyle *)paragraphStyle {
    NSString *const basedOn = NSLocalizedStringWithDefaultValue(@"AboutWindow.BasedOnITerm2", nil, [NSBundle mainBundle], @"\n\nCryTerm is a modified version of iTerm2 by George Nachman and contributors.", @"Attribution line in the about window. Keep the product names CryTerm and iTerm2 and the person’s name untranslated.");
    NSString *const license = NSLocalizedStringWithDefaultValue(@"AboutWindow.License", nil, [NSBundle mainBundle], @"\nLicensed under the GNU General Public License v2 or later.", @"Link title in the about window that opens the license");
    NSDictionary *const attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:kAboutFooterFontSize],
                                        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                                        NSParagraphStyleAttributeName: paragraphStyle };
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSArray<NSArray<NSString *> *> *const lines = @[ @[ basedOn, iTermAboutWindowUpstreamURLString ],
                                                    @[ license, iTermAboutWindowLicenseURLString ] ];
    for (NSArray<NSString *> *line in lines) {
        // The catalog's strings begin with line breaks from the old layout.
        NSString *const text = [line[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (result.length > 0) {
            // Localization unneeded
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes]];
        }
        NSMutableDictionary *const linkAttributes = [attributes mutableCopy];
        linkAttributes[NSLinkAttributeName] = [NSURL URLWithString:line[1]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:linkAttributes]];
    }
    return result;
}

- (NSButton *)makeButtonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:nil action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
    [button sizeToFit];
    [self addSubview:button];
    return button;
}

- (NSTextField *)makeEyebrowWithText:(NSString *)text {
    NSTextField *label = [NSTextField labelWithAttributedString:[self makeEyebrowAttributedString:text]];
    label.alignment = NSTextAlignmentCenter;
    [label sizeToFit];
    [self addSubview:label];
    return label;
}

- (void)setBackersCount:(NSInteger)count {
    NSString *text = NSLocalizedStringWithDefaultValue(@"AboutWindow.BackersHeading", nil, [NSBundle mainBundle], @"Backers", @"Small uppercase heading in the about window above the list of individual backers");
    NSMutableAttributedString *eyebrow = [[NSMutableAttributedString alloc] initWithAttributedString:[self makeEyebrowAttributedString:text]];
    if (count > 0) {
        // Localization unneeded
        NSString *countString = [NSString stringWithFormat:@"  %@", [NSNumberFormatter localizedStringFromNumber:@(count)
                                                                                                         numberStyle:NSNumberFormatterDecimalStyle]];
        [eyebrow appendAttributedString:[[NSAttributedString alloc] initWithString:countString
                                                                        attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:kAboutEyebrowFontSize],
                                                                                      NSForegroundColorAttributeName: [NSColor tertiaryLabelColor] }]];
    }
    _backersEyebrow.attributedStringValue = eyebrow;
    [_backersEyebrow sizeToFit];
    [self layoutContent];
}

- (NSAttributedString *)makeEyebrowAttributedString:(NSString *)text {
    NSFont *font = [NSFont systemFontOfSize:kAboutEyebrowFontSize weight:NSFontWeightSemibold];
    return [[NSAttributedString alloc] initWithString:text.localizedUppercaseString
                                           attributes:@{ NSFontAttributeName: font,
                                                         NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                                                         NSKernAttributeName: @(kAboutEyebrowFontSize * kAboutEyebrowTracking) }];
}

// CryTerm has no sponsor or backer sections, so the height is the header and
// the attribution footer whatever backersHeight is.
- (CGFloat)preferredHeightForBackersHeight:(CGFloat)backersHeight {
    return (kAboutTopMargin +
            [self headerHeight] + kAboutSectionGap +
            kAboutAttributionFooterHeight +
            kAboutBottomMargin);
}

- (CGFloat)headerTextHeight {
    return (NSHeight(_titleField.frame) + kAboutTitleToBylineGap +
            NSHeight(_bylineField.frame) + kAboutBylineToVersionGap +
            kAboutVersionLineHeight + kAboutVersionToButtonsGap +
            NSHeight(_buttons.firstObject.frame));
}

- (CGFloat)headerHeight {
    return [self headerTextHeight];
}

- (CGFloat)iconSize {
    return round([self headerTextHeight] / kAboutIconArtworkFraction);
}

// The transparent margin on each side of the icon's artwork.
- (CGFloat)iconPadding {
    return round(([self iconSize] - [self headerTextHeight]) / 2);
}

- (CGFloat)buttonsWidth {
    CGFloat width = -kAboutButtonSpacing;
    for (NSButton *button in _buttons) {
        width += NSWidth(button.frame) + kAboutButtonSpacing;
    }
    return width;
}

- (CGFloat)versionTextWidth {
    NSTextView *textView = [NSTextView castFrom:_versionScrollView.documentView];
    return ceil(textView.textStorage.size.width);
}

// The icon sits to the left of the text column, both centred vertically in
// the header, and the pair is centred horizontally in the window.
- (void)layoutHeaderWithTop:(CGFloat)top {
    const CGFloat titleWidth = ceil(_titleField.attributedStringValue.size.width);
    const CGFloat bylineWidth = ceil(_bylineField.attributedStringValue.size.width);
    const CGFloat textWidth = MAX(MAX(titleWidth, bylineWidth),
                                  MAX([self versionTextWidth], [self buttonsWidth]));
    // Measure the group by the icon's artwork so the padding neither pushes
    // the text away nor throws off the centring.
    const CGFloat iconSize = [self iconSize];
    const CGFloat iconPadding = [self iconPadding];
    const CGFloat artworkSize = iconSize - iconPadding * 2;
    const CGFloat groupWidth = artworkSize + kAboutIconToTextGap + textWidth;
    const CGFloat groupX = round((NSWidth(self.bounds) - groupWidth) / 2);
    const CGFloat headerHeight = [self headerHeight];

    _iconView.frame = NSMakeRect(groupX - iconPadding,
                                 top - round((headerHeight + iconSize) / 2),
                                 iconSize,
                                 iconSize);

    const CGFloat textX = groupX + artworkSize + kAboutIconToTextGap;
    CGFloat y = top - round((headerHeight - [self headerTextHeight]) / 2);
    y -= NSHeight(_titleField.frame);
    _titleField.frame = NSMakeRect(textX - kAboutLabelInset, y, titleWidth + kAboutLabelInset * 2, NSHeight(_titleField.frame));
    y -= kAboutTitleToBylineGap + NSHeight(_bylineField.frame);
    _bylineField.frame = NSMakeRect(textX - kAboutLabelInset, y, bylineWidth + kAboutLabelInset * 2, NSHeight(_bylineField.frame));
    y -= kAboutBylineToVersionGap + kAboutVersionLineHeight;
    _versionScrollView.frame = NSMakeRect(textX, y, textWidth, kAboutVersionLineHeight);
    y -= kAboutVersionToButtonsGap;

    const CGFloat buttonHeight = NSHeight(_buttons.firstObject.frame);
    y -= buttonHeight;
    CGFloat x = textX;
    for (NSButton *button in _buttons) {
        button.frame = NSMakeRect(x, y, NSWidth(button.frame), buttonHeight);
        x += NSWidth(button.frame) + kAboutButtonSpacing;
    }
}

- (CGFloat)sponsorRowHeight {
    return kSponsorImageHeight + kSponsorPaddingVertical * 2;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutContent];
}

// Stacks the header and, below it, the attribution footer. CryTerm has no
// sponsor row or backer list between them.
- (void)layoutContent {
    const CGFloat width = NSWidth(self.bounds);
    const CGFloat contentWidth = width - kAboutSideMargin * 2;
    CGFloat y = NSHeight(self.bounds) - kAboutTopMargin;

    [self layoutHeaderWithTop:y];
    y -= [self headerHeight] + kAboutSectionGap;

    y -= kAboutAttributionFooterHeight;
    _footerScrollView.frame = NSMakeRect(kAboutSideMargin, y, contentWidth, kAboutAttributionFooterHeight);
}

- (void)layoutSponsorRowAtY:(CGFloat)rowY {
    CGFloat totalWidth = -kSponsorSpacing;
    for (iTermSponsor *sponsor in _sponsors) {
        totalWidth += NSWidth(sponsor.view.frame) + kSponsorSpacing;
    }
    CGFloat x = round((NSWidth(self.bounds) - totalWidth) / 2.0);
    for (iTermSponsor *sponsor in _sponsors) {
        NSRect frame = sponsor.view.frame;
        frame.origin = NSMakePoint(x, rowY);
        sponsor.view.frame = frame;
        x += NSWidth(frame) + kSponsorSpacing;
    }
}

// On macOS 26 the About window is a plain window-background window, the way
// the system's own About panel is, with the backers in a container like the
// sponsor cards; the colours are dynamic, so light and dark share one path.
// Before macOS 26, dark themes get frosted glass with a scrim behind the
// backers and light themes keep the stock window.
- (void)applyAppearanceTreatment {
    if (@available(macOS 26, *)) {
        self.material = NSVisualEffectMaterialWindowBackground;
        _backersWell.hidden = NO;
        return;
    }
    const BOOL dark = self.effectiveAppearance.it_isDark;
    self.material = dark ? NSVisualEffectMaterialUnderWindowBackground : _stockMaterial;
    _backersWell.hidden = !dark;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    // AppKit does not guarantee this fires after awakeFromNib. Applying the
    // treatment before awakeFromNib has captured the stock material would set a
    // bogus material and then let awakeFromNib record that bogus value as the
    // stock one. awakeFromNib does the initial application itself.
    if (!_ready) {
        return;
    }
    [self applyAppearanceTreatment];
}

- (NSView *)makeSponsorBoxWithImageNamed:(NSString *)imageName title:(NSString *)title {
    NSImage *image = [NSImage imageNamed:imageName];
    CGFloat aspect = (image && image.size.height > 0)
        ? (image.size.width / image.size.height) : 1.0;
    CGFloat imageWidth = ceil(kSponsorImageHeight * aspect);
    CGFloat boxHeight = [self sponsorRowHeight];

    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(kSponsorPaddingHorizontal, kSponsorPaddingVertical, imageWidth, kSponsorImageHeight)];
    imageView.image = image;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;

    CGFloat boxWidth = imageWidth + 2 * kSponsorPaddingHorizontal;

    NSTextField *label = nil;
    if (title) {
        label = [NSTextField labelWithString:title];
        label.font = [NSFont systemFontOfSize:13];
        label.textColor = [NSColor linkColor];
        [label sizeToFit];
        CGFloat labelX = kSponsorPaddingHorizontal + imageWidth + kSponsorImageToLabelGap;
        label.frame = NSMakeRect(labelX,
                                 round((boxHeight - label.frame.size.height) / 2.0),
                                 label.frame.size.width,
                                 label.frame.size.height);
        boxWidth = NSMaxX(label.frame) + kSponsorPaddingHorizontal;
    }

    iTermSponsorBoxView *box = [[iTermSponsorBoxView alloc] initWithFrame:NSMakeRect(0, 0, boxWidth, boxHeight)];
    box.wantsLayer = YES;
    box.bakedBackgroundColor = iTermAboutBakedBackgroundColorOfImage(image);
    [box addSubview:imageView];
    if (label) {
        [box addSubview:label];
    }

    return box;
}

- (NSArray<iTermSponsor *> *)buildUnifiedSponsorRow {
    NSArray<NSDictionary *> *sponsorData = @[
        // Localization unneeded
        @{ @"image": @"whitebox_logo", @"title": @"Whitebox", @"url": @"https://whitebox.so/?utm_source=iTerm2" },
        @{ @"image": @"coderabbitai",  @"url": @"https://coderabbit.ai/" },
        @{ @"image": @"SerpApi",       @"url": @"https://serpapi.com/?utm_source=iterm" },
        @{ @"image": @"LIMSIQ",        @"url": @"https://limsiq.com/iterm2?utm_source=iterm2&utm_medium=sponsorship&utm_campaign=about_box" },
        @{ @"image": @"BairesDev",     @"url": @"https://www.bairesdev.com/sponsoring-open-source-projects/" },
    ];

    NSMutableArray<iTermSponsor *> *sponsors = [NSMutableArray array];
    for (NSDictionary *data in sponsorData) {
        iTermSponsor *sponsor = [[iTermSponsor alloc] init];
        sponsor.view = [self makeSponsorBoxWithImageNamed:data[@"image"] title:data[@"title"]];
        sponsor.url = data[@"url"];
        [self addSubview:sponsor.view];
        [sponsors addObject:sponsor];
    }
    return [sponsors copy];
}

- (void)mouseUp:(NSEvent *)theEvent {
    if (theEvent.clickCount == 1) {
        for (iTermSponsor *sponsor in _sponsors) {
            NSPoint pt = [sponsor.view convertPoint:theEvent.locationInWindow fromView:nil];
            if (NSPointInRect(pt, sponsor.view.bounds)) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:sponsor.url]];
                break;
            }
        }
    }
}

@end

@implementation iTermAboutWindowController {
    IBOutlet NSTextView *_dynamicText;
    IBOutlet iTermAboutBackersColumnsView *_backersView;
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
    self = [super initWithWindowNibName:@"AboutWindow"];
    if (self) {
        NSDictionary *myDict = [[NSBundle bundleForClass:[self class]] infoDictionary];
        NSString *const versionNumber = myDict[(NSString *)kCFBundleVersionKey];
        NSString *versionString = [NSString stringWithFormat: NSLocalizedStringWithDefaultValue(@"AboutWindow.BuildVersion", nil, [NSBundle mainBundle], @"Build %@", @"Build version line in the about window; placeholder is the build number"), versionNumber];
        NSAttributedString *whatsNew = nil;
        if ([versionNumber hasPrefix:@"3.7."] || [versionString isEqualToString:@"unknown"]) {
            whatsNew = [self attributedStringWithLinkToURL:iTermAboutWindowControllerWhatsNewURLString
                                                     title:NSLocalizedStringWithDefaultValue(@"AboutWindow.WhatsNew", nil, [NSBundle mainBundle], @"What’s New in 3.7?", @"Link title in the about window that opens the whats-new page for version 3.7")];
        }

        // Force IBOutlets to be bound by creating window.
        [self window];

        NSDictionary *versionAttributes = @{ NSForegroundColorAttributeName: [NSColor tertiaryLabelColor],
                                             NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:kAboutVersionFontSize weight:NSFontWeightRegular] };
        [_dynamicText setLinkTextAttributes:self.linkTextViewAttributes];
        [[_dynamicText textStorage] deleteCharactersInRange:NSMakeRange(0, [[_dynamicText textStorage] length])];
        [[_dynamicText textStorage] appendAttributedString:[[NSAttributedString alloc] initWithString:versionString
                                                                                            attributes:versionAttributes]];
        if (whatsNew) {
            // Localization unneeded
            [[_dynamicText textStorage] appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ·  "
                                                                                                attributes:versionAttributes]];
            [[_dynamicText textStorage] appendAttributedString:whatsNew];
        }
        // The link carries no font of its own and would otherwise draw in the
        // text system's default Helvetica.
        [[_dynamicText textStorage] addAttribute:NSFontAttributeName
                                           value:versionAttributes[NSFontAttributeName]
                                           range:NSMakeRange(0, [[_dynamicText textStorage] length])];
        [_dynamicText setAlignment:NSTextAlignmentLeft
                             range:NSMakeRange(0, [[_dynamicText textStorage] length])];

        // CryTerm does not fetch or show iTerm2's backers (iterm2.com/patrons.txt).
        [self resizeToFitBackersWithCount:0 animate:NO];
    }
    return self;
}

- (iTermAboutWindowContentView *)aboutContentView {
    return [iTermAboutWindowContentView castFrom:self.window.contentView];
}

- (NSDictionary *)linkTextViewAttributes {
    return @{ NSForegroundColorAttributeName: [NSColor linkColor],
              NSCursorAttributeName: [NSCursor pointingHandCursor] };
}

// The window grows to fit the backer list, as it always has, but never past
// the screen: beyond that the list scrolls inside its well instead.
- (void)resizeToFitBackersWithCount:(NSInteger)count animate:(BOOL)animate {
    const CGFloat width = NSWidth(_backersView.enclosingScrollView.frame);
    const CGFloat backersHeight = [_backersView heightForWidth:width];
    [_backersView setFrameSize:NSMakeSize(width, backersHeight)];
    iTermAboutWindowContentView *contentView = self.aboutContentView;
    [contentView setBackersCount:count];

    const CGFloat preferredHeight = [contentView preferredHeightForBackersHeight:backersHeight];
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    const NSRect visibleFrame = NSInsetRect(screen.visibleFrame, 0, kAboutScreenMargin);
    NSRect contentRect = [self.window contentRectForFrameRect:self.window.frame];
    const CGFloat diff = MIN(preferredHeight, NSHeight(visibleFrame)) - NSHeight(contentRect);
    NSRect rect = self.window.frame;
    rect.size.height += diff;
    rect.origin.y -= diff;
    // Growing downward keeps the top edge still, which can push the bottom
    // off the screen; slide the window up to keep all of it visible.
    rect.origin.y = MAX(rect.origin.y, NSMinY(visibleFrame));
    rect.origin.y = MIN(rect.origin.y, NSMaxY(screen.visibleFrame) - NSHeight(rect));
    [self.window setFrame:rect display:YES animate:animate];
}

// The feed marks higher-tier backers by wrapping the name in ⭐️. They come
// first, in a heavier weight; everyone else follows.
- (void)setPatrons:(NSArray *)patronNames {
    if (!patronNames.count) {
        [_backersView showWithMessage:NSLocalizedStringWithDefaultValue(@"AboutWindow.ErrorLoadingPatrons", nil, [NSBundle mainBundle], @"Error loading patrons :(", @"Text shown in the about window when the patron list failed to load")];
        [self resizeToFitBackersWithCount:0 animate:NO];
        return;
    }

    // Match only the star itself. The emoji variation selector that follows
    // it also appears in many other emoji (❤️, ☕️), which must not count.
    // Localization unneeded
    NSString *const star = @"\u2B50";
    NSString *const starWithVariationSelector = @"\u2B50\uFE0F";
    NSMutableArray<NSString *> *higherTier = [NSMutableArray array];
    NSMutableArray<NSString *> *everyoneElse = [NSMutableArray array];
    for (NSString *rawName in patronNames) {
        // Literal searches, because a non-literal one treats the star and its
        // variation selector as a single character and finds no bare star.
        NSString *name = [rawName stringByReplacingOccurrencesOfString:starWithVariationSelector
                                                            withString:@""
                                                               options:NSLiteralSearch
                                                                 range:NSMakeRange(0, rawName.length)];
        name = [name stringByReplacingOccurrencesOfString:star
                                               withString:@""
                                                  options:NSLiteralSearch
                                                    range:NSMakeRange(0, name.length)];
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length == 0) {
            continue;
        }
        if ([rawName rangeOfString:star options:NSLiteralSearch].location != NSNotFound) {
            [higherTier addObject:name];
        } else {
            [everyoneElse addObject:name];
        }
    }

    [_backersView showWithHigherTier:higherTier everyoneElse:everyoneElse];
    [self resizeToFitBackersWithCount:higherTier.count + everyoneElse.count
                              animate:YES];
}

- (NSAttributedString *)attributedStringWithLinkToURL:(NSString *)urlString title:(NSString *)title {
    NSDictionary *linkAttributes = @{ NSLinkAttributeName: [NSURL URLWithString:urlString] };
    NSString *localizedTitle = title;
    return [[NSAttributedString alloc] initWithString:localizedTitle
                                            attributes:linkAttributes];
}

#pragma mark - Actions

- (IBAction)openHomePage:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:iTermAboutWindowHomePageURLString]];
}

- (IBAction)reportBug:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:iTermAboutWindowReportBugURLString]];
}

- (IBAction)openCredits:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:iTermAboutWindowCreditsURLString]];
}

#pragma mark - NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex {
    NSURL *url = [NSURL castFrom:link];
    if ([url.absoluteString isEqualToString:iTermAboutWindowControllerWhatsNewURLString]) {
        [iTermLaunchExperienceController forceShowWhatsNew];
        return YES;
    }
    return NO;
}

@end
