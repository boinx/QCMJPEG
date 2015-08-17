@import Quartz;


@interface QCMJPEGPlugIn : QCPlugIn

@property NSString *inputLocation;
@property NSString *inputUsername;
@property NSString *inputPassword;
@property BOOL inputUpdate;

@property id<QCPlugInOutputImageProvider> outputImage;
@property BOOL outputConnected;

@end
