#import <Quartz/Quartz.h>

@interface QCImagePort : NSObject <QCPlugInOutputImageProvider>

- (id)imageValue;
- (void)setImageValue:(id)imageValue;

@end


@interface QCMJPEGPlugIn : QCPlugIn

@property NSString *inputLocation;
@property NSString *inputUsername;
@property NSString *inputPassword;

@property id<QCPlugInOutputImageProvider> outputImage;

@end
