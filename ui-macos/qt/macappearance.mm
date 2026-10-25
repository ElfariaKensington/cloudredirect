#import <AppKit/AppKit.h>
#include "macappearance.h"
#include <QWindow>
#include <QImage>
#include <QColor>
@interface CRToolbar : NSObject<NSToolbarDelegate>
@property(nonatomic,assign) MacAppearance* owner;
@end
@implementation CRToolbar
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar {
    return @[@"sidebar", NSToolbarFlexibleSpaceItemIdentifier, @"refresh"];
}
- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar {
    return @[@"sidebar", NSToolbarFlexibleSpaceItemIdentifier, @"refresh"];
}
- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)inserted {
    NSToolbarItem* item=[[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.target=self;
    if([identifier isEqualToString:@"sidebar"]){
        item.navigational=YES;
        item.label=@"Toggle Sidebar";item.toolTip=@"Show or hide the sidebar (⌃⌘S)";
        item.image=[NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:item.label];
        item.action=@selector(toggleSidebar:);
    } else {
        item.label=@"Refresh";item.toolTip=@"Refresh (⌘R)";
        item.image=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:item.label];
        item.action=@selector(refresh:);
    }
    return item;
}
- (void)toggleSidebar:(id)sender { emit self.owner->toggleSidebar(); }
- (void)refresh:(id)sender { emit self.owner->refresh(); }
@end
void MacAppearance::attach(QWindow* window) {
    NSView* view=(__bridge NSView*)(void*)window->winId();
    NSWindow* native=view.window;
    NSString* iconPath=[NSBundle.mainBundle pathForResource:@"CloudRedirect" ofType:@"icns"];
    NSImage* icon=iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if(icon)NSApp.applicationIconImage=icon;
    native.titleVisibility=NSWindowTitleVisible;
    native.titlebarAppearsTransparent=YES;
    native.toolbarStyle=NSWindowToolbarStyleUnified;
    native.backgroundColor=NSColor.windowBackgroundColor;
    NSToolbar* toolbar=[[NSToolbar alloc] initWithIdentifier:@"CloudRedirect.Toolbar"];
    CRToolbar* delegate=[CRToolbar new];delegate.owner=this;
    toolbar.delegate=delegate;toolbar.displayMode=NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization=NO;native.toolbar=toolbar;
    // NSToolbar does not retain its delegate. Keep it alive with the QObject.
    void* retained=(__bridge_retained void*)delegate;
    connect(this,&QObject::destroyed,[retained]{CFRelease(retained);});
    CGFloat titlebarHeight=MAX(0,native.frame.size.height-native.contentLayoutRect.size.height);
    NSVisualEffectView* effect=[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(view.frame.origin.x,view.frame.origin.y,224,view.frame.size.height+titlebarHeight)];
    effect.material=NSVisualEffectMaterialSidebar;
    effect.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    effect.state=NSVisualEffectStateFollowsWindowActiveState;
    effect.autoresizingMask=NSViewHeightSizable;
    [view.superview addSubview:effect positioned:NSWindowBelow relativeTo:view];
    effect_=(__bridge void*)effect;
}
void MacAppearance::setSidebarWidth(int width) {
    NSVisualEffectView* effect=(__bridge NSVisualEffectView*)effect_;
    if(effect){NSRect frame=effect.frame;frame.size.width=width;effect.frame=frame;effect.hidden=width==0;}
}
QImage SymbolProvider::requestImage(const QString& id,QSize* size,const QSize& requestedSize) {
    @autoreleasepool {
        QStringList parts=id.split('/');
        NSImage* symbol=[NSImage imageWithSystemSymbolName:[NSString stringWithUTF8String:parts[0].toUtf8().constData()] accessibilityDescription:nil];
        if(!symbol)return {};
        const int side=requestedSize.isValid()?qMax(requestedSize.width(),requestedSize.height()):40;
        QImage result(side,side,QImage::Format_ARGB32_Premultiplied);result.fill(Qt::transparent);
        NSBitmapImageRep* rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:side pixelsHigh:side bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:side*4 bitsPerPixel:32];
        NSGraphicsContext* context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:context];
        symbol=[symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:side*0.75 weight:NSFontWeightRegular]];
        [symbol drawInRect:NSMakeRect(0,0,side,side)];
        QColor color(parts.size()>1?"#"+parts[1]:"#007aff");
        [[NSColor colorWithRed:color.redF() green:color.greenF() blue:color.blueF() alpha:1] setFill];
        NSRectFillUsingOperation(NSMakeRect(0,0,side,side),NSCompositingOperationSourceIn);
        [NSGraphicsContext restoreGraphicsState];
        NSData* png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        result.loadFromData((const uchar*)png.bytes,png.length,"PNG");
        if(size)*size=result.size();return result;
    }
}
