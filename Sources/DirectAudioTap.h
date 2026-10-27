#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface BPDirectAudioTap : NSObject
@property(nonatomic, copy) void (^onPCM)(AVAudioPCMBuffer *, NSTimeInterval);
@property(nonatomic, copy) void (^onEvent)(NSString *);
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
