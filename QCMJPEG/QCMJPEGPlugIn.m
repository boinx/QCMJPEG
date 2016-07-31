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

@property (nonatomic, strong) NSTimer *watchDogTimer;
@property (assign) BOOL dataSearchSOI;
@property (assign) NSRange JPEGRange;
@property (assign) NSUInteger dataSOIPointer;

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
	[self.watchDogTimer invalidate];

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

- (void)updateWatchDogTimer
{
	// setup a watchdog to stop the connection once the QC isn't calling this patch anymore.
	[self.watchDogTimer invalidate];
	self.watchDogTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(watchDogTimerFired:) userInfo:nil repeats:NO];
}

#pragma mark - NSURLConnectionDelegate, NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	if(connection != self.connection)
	{
		return;
	}

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
	if(connection != self.connection)
	{
		return;
	}

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

// #define MEASUREDATARATE 1
#ifdef MEASUREDATARATE
	long callCount;
	long dataCount;
	uint64_t lastDataRateUpdate;
#endif

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)newData
{
	if(connection != self.connection)
	{
		return;
	}

#ifdef MEASUREDATARATE
	callCount ++;
	dataCount = dataCount + newData.length;
	uint64_t now = CVGetCurrentHostTime();
	
	const double clock_freq = CVGetHostClockFrequency();
	
	if( now > lastDataRateUpdate + clock_freq)
	{
		
		CGFloat secs = (now - lastDataRateUpdate) / clock_freq;
		NSLog(@"calls/sec=%d dataThroughPut=%ld junkSize=%lu", (int)(callCount / secs), dataCount, newData.length);
		callCount = 0;
		dataCount = 0;
		lastDataRateUpdate = now;
	}
#endif

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
		if (data == nil || data.length > 10000000)
		{
			// lazzy creation of the data buffer
			// savety net: 10MB are much to much data for a JPEG frame, so we kill the data buffer and start all over again.
			data = [NSMutableData dataWithCapacity:64 * 1024];
			self.data = data;
			self.dataSearchSOI = YES;	// search for SOI (Start Of Image)
			self.JPEGRange = NSMakeRange(NSNotFound, 0);
		}

		NSUInteger dataPointer = data.length;	// only search in the new buffer
		[data appendData:newData];
		
		const uint8_t SOIToken[2] = { 0xFF, 0xD8 };	// Start Of Image
		NSData *SOIData = [NSData dataWithBytes:SOIToken length:sizeof(SOIToken)];
		
		const uint8_t EOIToken[2] = { 0xFF, 0xD9 };	// End Of Image
		NSData *EOIData = [NSData dataWithBytes:EOIToken length:sizeof(EOIToken)];
		
		NSRange SOIRange = NSMakeRange(NSNotFound, 0);
		NSRange EOIRange = NSMakeRange(NSNotFound, 0);

		BOOL keepSearching = YES;
		do
		{
			NSRange searchRange = NSMakeRange(dataPointer, data.length - dataPointer);

			if (self.dataSearchSOI)
			{
				SOIRange = [data rangeOfData:SOIData options:0 range:searchRange];
				if (SOIRange.location != NSNotFound)
				{
					self.dataSOIPointer = SOIRange.location;
					dataPointer = SOIRange.location+1;
					self.dataSearchSOI = NO;
				}
				else
				{
					keepSearching = NO;
				}
			}
			else
			{
				
				EOIRange = [data rangeOfData:EOIData options:0 range:searchRange];
				if (EOIRange.location != NSNotFound)
				{
					self.JPEGRange = NSMakeRange(self.dataSOIPointer, NSMaxRange(EOIRange) - self.dataSOIPointer);	// store last JPEG position
					dataPointer = EOIRange.location+1;
					self.dataSOIPointer = 0;
					self.dataSearchSOI = YES;
				}
				else
				{
					keepSearching = NO;
				}
			}
		}
		while(keepSearching);
		
		if (self.JPEGRange.location != NSNotFound)
		{
			// JPEG found
			dispatch_semaphore_t renderSemaphore = self.renderSemaphore;
			if (dispatch_semaphore_wait(renderSemaphore, DISPATCH_TIME_NOW) == 0)	// are we currently decoding?
			{
				NSData *JPEGData = [data subdataWithRange:self.JPEGRange];

				// decode JPEG on another thread
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
				
				NSUInteger bytesToRemove = NSMaxRange(self.JPEGRange);
				[data replaceBytesInRange:NSMakeRange(0, bytesToRemove) withBytes:NULL length:0];
				self.dataSOIPointer = self.dataSOIPointer - bytesToRemove;
				self.JPEGRange = NSMakeRange(NSNotFound, 0);
			}

		}

	}

}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	if(connection != self.connection)
	{
		return;
	}

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

- (void)watchDogTimerFired:(NSTimer*)timer
{
	[self stopConnection];
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
	
	[self performSelector:@selector(updateWatchDogTimer) onThread:self.connectionThread withObject:nil waitUntilDone:NO];

	[lock unlock];
	
	return YES;
}

@end
