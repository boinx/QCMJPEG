@import Quartz;


@interface QCMJPEGPlugIn : QCPlugIn

@property NSString *inputLocation;
@property BOOL inputUpdate;

@property id<QCPlugInOutputImageProvider> outputImage;
@property BOOL outputConnected;

@end
