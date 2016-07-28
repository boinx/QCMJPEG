#import "QCMJPEGPlugIn.h"


@interface QCMJPEGPlugIn () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (nonatomic, strong) NSLock *lock;

@property (nonatomic, strong) NSThread *connectionThread;
@property (nonatomic, strong) NSTimer *connectionThreadTimer;
@property (nonatomic, strong) NSURLConnection *connection;

@property (nonatomic, strong) NSString *location;

@property (nonatomic, strong) CIImage *image;
@property (nonatomic, assign) QCMJPEGConnectionState connectionState;
@property (nonatomic, strong) NSString *lastConnectionError;

@property (nonatomic, strong) NSMutableData *data;

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_semaphore_t renderSemaphore;

@end


@implementation QCMJPEGPlugIn

@dynamic inputLocation;
@dynamic inputUpdate;

@dynamic outputImage;
@dynamic outputConnectionState;
@dynamic outputConnectionError;

+ (NSDictionary *)attributes
{
    return @{
		QCPlugInAttributeNameKey: @"MJPEG Stream",
		QCPlugInAttributeDescriptionKey: @"Connects a Motion-JPEG stream using the HTTP protocol",
		QCPlugInAttributeCopyrightKey: @"© 2015 Boinx Software Ltd. http://boinx.com",
		QCPlugInAttributeCategoriesKey: @[
			@"Source", // Video Input
			@"Source/Device", // Video Input
		],
		QCPlugInAttributeExamplesKey: @[
			@"MJPEG.qtz",
		],
	};
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString *)key
{
	if ([key isEqualToString:@"inputLocation"])
	{
		return @{
			QCPortAttributeNameKey: @"Location",
		};
	}
	
	if ([key isEqualToString:@"inputUpdate"])
	{
		return @{
			QCPortAttributeNameKey: @"Update",
		};
	}
	
	if ([key isEqualToString:@"outputImage"])
	{
		return @{
			QCPortAttributeNameKey: @"Image",
		};
	}
	
	if ([key isEqualToString:@"outputConnectionState"])
	{
		return @{
				 QCPortAttributeNameKey: @"Connection State",
				 };
	}
	
	if ([key isEqualToString:@"outputConnectionError"])
	{
		return @{
				 QCPortAttributeNameKey: @"Connection Error",
				 };
	}
	
	return nil;
}

+ (QCPlugInExecutionMode)executionMode
{
	return kQCPlugInExecutionModeProcessor;
}

+ (QCPlugInTimeMode)timeMode
{
	return kQCPlugInTimeModeIdle;
}

- (instancetype)init
{
	self = [super init];
	if (self != nil)
	{
		NSLock *lock = [[NSLock alloc] init];
		lock.name = @"QCMJPEGPlugIn.lock";
		self.lock = lock;
		
		self.renderSemaphore = dispatch_semaphore_create(2);
		self.queue = dispatch_queue_create("QCMJPEGImageDecode", DISPATCH_QUEUE_SERIAL);

		NSThread *connectionThread = [[NSThread alloc] initWithTarget:self selector:@selector(startConnectionThread) object:nil];
		connectionThread.name = @"QCMJPEGPlugIn.connectionThead";
		self.connectionThread = connectionThread;
		self.connectionState = QCMJPEGConnectionStateDisconnected;
		
		[connectionThread start];
		

	}
	return self;
}

- (void)dealloc
{
	NSThread *connectionThread = self.connectionThread;
	if(connectionThread != nil)
	{
		[self performSelector:@selector(stopConnectionThread) onThread:connectionThread withObject:nil waitUntilDone:YES];
	}
}

- (void)startConnectionThread
{
	@autoreleasepool
	{
		NSTimeInterval timeInterval = [NSDate.distantFuture timeIntervalSinceNow];
		self.connectionThreadTimer = [NSTimer scheduledTimerWithTimeInterval:timeInterval target:self selector:@selector(connectionTimerFired) userInfo:nil repeats:NO];
		
		CFRunLoopRun();
	}
}

- (void)stopConnectionThread
{
	@autoreleasepool
	{
		[self stopConnection];
	
		NSTimer *connectionThreadTimer = self.connectionThreadTimer;
		if(connectionThreadTimer != nil)
		{
			[connectionThreadTimer invalidate];
			self.connectionThreadTimer = nil;
		}
	
		CFRunLoopStop(CFRunLoopGetCurrent());
	}
}

- (void)connectionTimerFired
{
}

#pragma mark - NSURLConnectionDelegate, NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{

	NSLock *lock = self.lock;
	[lock lock];
	{
		if(error)
		{
			self.connectionState = QCMJPEGConnectionStateConnectionError;
			self.lastConnectionError = [error localizedDescription];
		}
		else
		{
			self.connectionState = QCMJPEGConnectionStateDisconnected;
		}
	}
	[lock unlock];

	[self stopConnection];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	NSLock *lock = self.lock;
	[lock lock];
	{
		if(self.connectionState <= QCMJPEGConnectionStateConnecting)
		{
			self.connectionState = QCMJPEGConnectionStateConnected;
		}
	}
	[lock unlock];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)newData
{
	NSLock *lock = self.lock;
	[lock lock];
	{
		if(self.connectionState <= QCMJPEGConnectionStateConnecting)
		{
			self.connectionState = QCMJPEGConnectionStateConnected;
		}
	}
	[lock unlock];

	@autoreleasepool
	{
		NSMutableData *data = self.data;
		if (data == nil)
		{
			data = [NSMutableData dataWithCapacity:64 * 1024];
			self.data = data;
		}

		[data appendData:newData];
		
		
		dispatch_semaphore_t renderSemaphore = self.renderSemaphore;
		if (dispatch_semaphore_wait(renderSemaphore, DISPATCH_TIME_NOW) == 0)
		{
			const uint8_t SOIToken[2] = { 0xFF, 0xD8 };	// Start Of Image
			NSData *SOIData = [NSData dataWithBytes:SOIToken length:sizeof(SOIToken)];
			
			const uint8_t EOIToken[2] = { 0xFF, 0xD9 };	// End Of Image
			NSData *EOIData = [NSData dataWithBytes:EOIToken length:sizeof(EOIToken)];
			
			NSRange JPEGRange = NSMakeRange(NSNotFound, 0);
			
			NSRange searchRange = NSMakeRange(0, data.length);
			do
			{
				// Search the last SOI Token first
				
				const NSRange SOIRange = [data rangeOfData:SOIData options:NSDataSearchBackwards range:searchRange];
				if (SOIRange.location == NSNotFound)
				{
					break;
				}
				
				// Search the next EOI Token
				
				searchRange = NSMakeRange(NSMaxRange(SOIRange), data.length - NSMaxRange(SOIRange));
				
				const NSRange EOIRange = [data rangeOfData:EOIData options:NSDataSearchBackwards range:searchRange];
				if (EOIRange.location != NSNotFound)
				{
					// found an image
					JPEGRange = NSMakeRange(SOIRange.location, NSMaxRange(EOIRange) - SOIRange.location);
					break;
				}
				
				// asuming the data looks like this [...SOI....EOI...SOI...] we need to check for a previous SOI
				searchRange = NSMakeRange(0, SOIRange.location);
			}
			while(1);
			
			if (JPEGRange.location != NSNotFound)
			{
				NSData *JPEGData = [data subdataWithRange:JPEGRange];

				dispatch_async(self.queue, ^{
					
					@autoreleasepool
					{
						CIImage *JPEGImage = [[CIImage alloc] initWithData:JPEGData options:nil];
						if (JPEGImage != nil)
						{
							NSLock *lock = self.lock;
							[lock lock];
							{
								self.connectionState = QCMJPEGConnectionStateReceivingData;
								self.lastConnectionError = @"";
								self.image = JPEGImage;
							}
							[lock unlock];
						}
						
						
						dispatch_semaphore_signal(renderSemaphore);
					}
				});
				
				if (data.length == NSMaxRange(JPEGRange))
				{
					// no more data left
					data.length = 0;
				}
				else
				{
					NSRange searchRange = NSMakeRange(NSMaxRange(JPEGRange), data.length - NSMaxRange(JPEGRange));
					
					const NSRange SOIRange = [data rangeOfData:SOIData options:0 range:searchRange];
					if (SOIRange.location == NSNotFound)
					{
						// no JPEG SOI found, can be discarded
						data.length = 0;
					}
					else
					{
						// keep the data starting at the next SOI
						[data replaceBytesInRange:NSMakeRange(0, SOIRange.location) withBytes:NULL length:0];
					}
				}

			}
			else
			{
				// no jpeg data found yet
				dispatch_semaphore_signal(renderSemaphore);

			}
		}

		
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	[self stopConnection];
}

#pragma mark -

- (void)startConnection
{
	@autoreleasepool
	{
		[self stopConnection];
		
		NSURL *URL;
		
		NSLock *lock = self.lock;
		[lock lock];
		{
			URL = [NSURL URLWithString:self.location];
		}
		[lock unlock];

		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
		
		// TODO: headers?
		// TODO: method?
		
		self.connection = [NSURLConnection connectionWithRequest:request delegate:self];
		
	}
}

- (void)stopConnection
{
	@autoreleasepool
	{
		NSURLConnection *connection = self.connection;
		if (connection != nil)
		{
			[connection cancel];
			self.connection = nil;
		}
		
		NSLock *lock = self.lock;
		[lock lock];
		{
			if(self.connectionState != QCMJPEGConnectionStateConnectionError)
			{
				self.connectionState = QCMJPEGConnectionStateDisconnected;
			}
		}
		[lock unlock];
	}
}


- (BOOL)startExecution:(id <QCPlugInContext>)context
{
	return YES;
}

- (void)stopExecution:(id <QCPlugInContext>)context
{
}

- (void)enableExecution:(id <QCPlugInContext>)context
{
}

- (void)disableExecution:(id <QCPlugInContext>)context
{
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary *)arguments
{
	NSLock *lock = self.lock;
	[lock lock];
	
	if ([self didValueForInputKeyChange:@"inputUpdate"] && self.inputUpdate == YES)
	{
		self.location = self.inputLocation;

		[self performSelector:@selector(startConnection) onThread:self.connectionThread withObject:nil waitUntilDone:NO];
	}
	
	{
		CIImage *image = self.image;
		if (image != nil)
		{
			[self setValue:image forKeyPath:@"patch.outputImage.value"];
			self.image = nil;
		}
	}
	
	{
		NSString *lastConnectionError = self.lastConnectionError;
		if (lastConnectionError != nil)
		{
			self.outputConnectionError = lastConnectionError;
			self.lastConnectionError = nil;
		}
	}
	
	self.outputConnectionState = self.connectionState;
	
	[lock unlock];
	
	return YES;
}

@end
