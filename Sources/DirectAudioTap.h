#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface BPDirectAudioTap : NSObject
@property(nonatomic, copy) void (^onPCM)(AVAudioPCMBuffer *, NSTimeInterval);
@property(nonatomic, copy) void (^onEvent)(NSString *);
@property(nonatomic) int targetProcessID;
@property(nonatomic) BOOL useStandardInput;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
@end
FOUNDATION_EXPORT void BPFindNowPlayingProcess(void (^completion)(int));
NS_ASSUME_NONNULL_END
