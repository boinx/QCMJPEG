@import Quartz;

typedef NS_ENUM(NSUInteger, QCMJPEGConnectionState) {
	QCMJPEGConnectionStateDisconnected = 0,
	QCMJPEGConnectionStateConnecting = 1,
	QCMJPEGConnectionStateConnected = 2,
	QCMJPEGConnectionStateReceivingData = 3,
	QCMJPEGConnectionStateConnectionError = 99,
	
};

@interface QCMJPEGPlugIn : QCPlugIn

@property NSString *inputLocation;
@property BOOL inputUpdate;

@property id<QCPlugInOutputImageProvider> outputImage;
@property NSUInteger outputConnectionState;
@property NSString *outputConnectionError;

@end
