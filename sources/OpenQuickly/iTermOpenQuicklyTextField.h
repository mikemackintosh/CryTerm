#import <Cocoa/Cocoa.h>

@protocol iTermOpenQuicklyTextFieldDelegate <NSObject>
- (void)keyDown:(NSEvent *)event;

@optional
// Gives the delegate first crack at a key equivalent such as ⌘1. Return YES
// if it was handled.
- (BOOL)openQuicklyTextFieldHandleKeyEquivalent:(NSEvent *)event;
@end

// A text field that passes arrow keys to its arrowHandler.
@interface iTermOpenQuicklyTextField : NSTextField

@property(nonatomic, weak) id<iTermOpenQuicklyTextFieldDelegate> arrowHandler;

@end

@interface iTermOpenQuicklyTextView: NSTextView
@end
