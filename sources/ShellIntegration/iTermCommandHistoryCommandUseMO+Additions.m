//
//  CommandUse.m
//  iTerm
//
//  Created by George Nachman on 1/19/14.
//
//

#import "iTermCommandHistoryCommandUseMO+Additions.h"
#import "iTermCommandHistoryCommandUseMO.h"
#import "NSObject+iTerm.h"
#import "VT100ScreenMark.h"

@implementation iTermCommandHistoryCommandUseMO (Additions)

+ (instancetype)commandHistoryCommandUseInContext:(NSManagedObjectContext *)context {
    return [NSEntityDescription insertNewObjectForEntityForName:self.entityName
                                         inManagedObjectContext:context];
}

+ (NSString *)entityName {
    return @"CommandHistoryCommandUse";
}

- (id<VT100ScreenMarkReading>)mark {
    if (!self.markGuid) {
        return nil;
    }
    return [VT100ScreenMark markWithGuid:self.markGuid forMutationThread:NO];
}

- (void)setMark:(id<VT100ScreenMarkReading>)mark {
    self.markGuid = mark.guid;
}

@end
