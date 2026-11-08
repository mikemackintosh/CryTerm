//
//  NSBundle+iTerm.h
//  iTerm2
//
//  Created by George Nachman on 6/29/17.
//
//

#import <Foundation/Foundation.h>

@interface NSBundle (iTerm)

+ (BOOL)it_isNightlyBuild;
+ (BOOL)it_isEarlyAdopter;
// NO for builds whose Info.plist has no SUFeedURLForFinal (e.g., forks that
// don't publish a Sparkle appcast).
+ (BOOL)it_hasSoftwareUpdateFeed;
+ (NSDate *)it_buildDate;

@end
