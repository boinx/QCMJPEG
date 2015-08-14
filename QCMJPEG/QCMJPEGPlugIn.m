#import "QCMJPEGPlugIn.h"


@interface QCMJPEGPlugIn () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (nonatomic, strong) NSLock *lock;

@property (nonatomic, strong) NSThread *connectionThread;
@property (nonatomic, strong) NSTimer *connectionThreadTimer;
@property (nonatomic, strong) NSURLConnection *connection;

@property (nonatomic, strong) NSString *location;
@property (nonatomic, strong) NSString *username;
@property (nonatomic, strong) NSString *password;

@property (nonatomic, strong) CIImage *image;

@property (nonatomic, strong) NSMutableData *data;

@end


@implementation QCMJPEGPlugIn

@dynamic inputLocation;
@dynamic inputUsername;
@dynamic inputPassword;
@dynamic outputImage;

+ (NSDictionary *)attributes
{
    return @{
		QCPlugInAttributeNameKey: @"MJPEG",
		QCPlugInAttributeDescriptionKey: @"Connects a Motion-JPEG stream using the HTTP protocol",
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
	
	if ([key isEqualToString:@"inputUsername"])
	{
		return @{
			QCPortAttributeNameKey: @"Username",
		};
	}
	
	if ([key isEqualToString:@"inputPassword"])
	{
		return @{
			QCPortAttributeNameKey: @"Password",
		};
	}
	
	if ([key isEqualToString:@"outputImage"])
	{
		return @{
			QCPortAttributeNameKey: @"Image",
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
		
		NSThread *connectionThread = [[NSThread alloc] initWithTarget:self selector:@selector(startConnectionThread) object:nil];
		connectionThread.name = @"QCMJPEGPlugIn.connectionThead";
		self.connectionThread = connectionThread;
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
	NSLog(@"%@ %@", connection, error);
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{

}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)newData
{
	@autoreleasepool
	{
		NSMutableData *data = self.data;
		if (data == nil)
		{
			data = [NSMutableData dataWithCapacity:64 * 1024];
			self.data = data;
		}

		[data appendData:newData];
		
		const uint8_t SOIToken[2] = { 0xFF, 0xD8 };
		NSData *SOIData = [NSData dataWithBytes:SOIToken length:sizeof(SOIToken)];
		
		const uint8_t EOIToken[2] = { 0xFF, 0xD9 };
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
			if (EOIRange.location == NSNotFound)
			{
				searchRange = NSMakeRange(0, SOIRange.location);
				continue;
			}
			
			JPEGRange = NSMakeRange(SOIRange.location, NSMaxRange(EOIRange) - SOIRange.location);
		}
		while(1);

		if (JPEGRange.location != NSNotFound)
		{
			NSData *JPEGData = [data subdataWithRange:JPEGRange];
			CIImage *JPEGImage = [[CIImage alloc] initWithData:JPEGData options:nil];
			if (JPEGImage != nil)
			{
				NSLock *lock = self.lock;
				[lock lock];
				
				self.image = JPEGImage;
				
				[lock unlock];
			}
		
			if (data.length == NSMaxRange(JPEGRange))
			{
				data.length = 0;
			}
			else
			{
				[data replaceBytesInRange:NSMakeRange(0, NSMaxRange(JPEGRange)) withBytes:NULL length:0];
			}
		}
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	@autoreleasepool
	{
		NSLog(@"%@", connection);
	}
}

#pragma mark -

- (void)startConnection
{
	@autoreleasepool
	{
		[self stopConnection];
		
		NSLock *lock = self.lock;
		[lock lock];

		NSURL *URL = [NSURL URLWithString:self.location];
		
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
		
		// TODO: headers?
		// TODO: method?
		
		self.connection = [NSURLConnection connectionWithRequest:request delegate:self];
		
		[lock unlock];
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
	}
}


- (BOOL)startExecution:(id <QCPlugInContext>)context
{
	[self.connectionThread start];
	return YES;
}

- (void)stopExecution:(id <QCPlugInContext>)context
{
	[self performSelector:@selector(stopConnectionThread) onThread:self.connectionThread withObject:nil waitUntilDone:YES];
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
	
	BOOL reconnect = NO;
	
	if ([self didValueForInputKeyChange:@"inputLocation"])
	{
		self.location = self.inputLocation;
		reconnect = YES;
	}
	
	if ([self didValueForInputKeyChange:@"inputUsername"])
	{
		self.username = self.inputUsername;
		reconnect = YES;
	}
	
	if ([self didValueForInputKeyChange:@"inputPassword"])
	{
		self.password = self.inputPassword;
		reconnect = YES;
	}
	
	if (reconnect)
	{
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
	[lock unlock];

#if 0
	if(self.doneSignal != nil)
	{
		if(self.doneSignal.boolValue)
		{
			self.outputParsedJSON = self.parsedJSON;
			self.outputDoneSignal = YES;
			
			self.parsedJSON = nil;
			
			self.doneSignal = @NO;
		}
		else
		{
			self.outputDoneSignal = NO;
			
			self.doneSignal = nil;
		}
	}
	
	if(self.statusCode != nil)
	{
		self.outputStatusCode = self.statusCode.unsignedIntegerValue;
		self.statusCode = nil;
	}
	
	if(self.connecting != nil)
	{
		self.outputConnecting = self.connecting.boolValue;
		self.connecting = nil;
	}
	
	if(self.connected != nil)
	{
		self.outputConnected = self.connected.boolValue;
		self.connected = nil;
	}
	
	if(self.error)
	{
		[context logMessage:@"JSON Import error: %@", self.error];
		
		self.error = nil;
	}
#endif
	
	return YES;
}

@end
