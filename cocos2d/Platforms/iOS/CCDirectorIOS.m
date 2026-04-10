/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2010 Ricardo Quesada
 * Copyright (c) 2011 Zynga Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

// Only compile this code on iOS. These files should NOT be included on your Mac project.
// But in case they are included, it won't be compiled.
#import <Availability.h>
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

#import <unistd.h>

// cocos2d imports
#import "CCDirectorIOS.h"
#import "CCTouchDelegateProtocol.h"
#import "CCTouchDispatcher.h"
#import "../../CCScheduler.h"
#import "../../CCActionManager.h"
#import "../../CCTextureCache.h"
#import "../../ccMacros.h"
#import "../../CCScene.h"

// support imports
#import "glu.h"
#import "../../Support/OpenGL_Internal.h"
#import "../../Support/CGPointExtension.h"

#import "CCLayer.h"

// Parent-repo header. The motorbike Xcode target compiles these cocos2d
// files alongside our own code, so this resolves through the standard
// header search paths. We use COCOS2D_RENDER_SCALE_DIVISOR from here to
// shrink the GL viewport (and therefore the rasterized pixel area)
// while keeping cocos2d's logical projection at the full
// winSizeInPixels_. The Metal presenter's slot textures are at the
// matching shrunken size and Metal bilinearly upscales to the full
// CAMetalLayer drawable on present.
#import "MetalPresenter.h"
#import "CCMetalRenderer.h"

#if CC_ENABLE_PROFILERS
#import "../../Support/CCProfiling.h"
#endif


#pragma mark -
#pragma mark Director - global variables (optimization)

CGFloat	__ccContentScaleFactor = 1;

#pragma mark -
#pragma mark Director iOS

@interface CCDirector ()
-(void) setNextScene;
-(void) showFPS;
-(void) calculateDeltaTime;
@end

@implementation CCDirector (iOSExtensionClassMethods)


+(Class) defaultDirector
{
	return [CCDirectorTimer class];
}

+ (BOOL) setDirectorType:(ccDirectorType)type
{
	if( type == CCDirectorTypeDisplayLink ) {
		NSString *reqSysVer = @"3.1";
		NSString *currSysVer = [[UIDevice currentDevice] systemVersion];

		if([currSysVer compare:reqSysVer options:NSNumericSearch] == NSOrderedAscending)
			return NO;
	}
	switch (type) {
		case CCDirectorTypeNSTimer:
			[CCDirectorTimer sharedDirector];
			break;
		case CCDirectorTypeDisplayLink:
			[CCDirectorDisplayLink sharedDirector];
			break;
		case CCDirectorTypeMainLoop:
			[CCDirectorFast sharedDirector];
			break;
		case CCDirectorTypeThreadMainLoop:
			[CCDirectorFastThreaded sharedDirector];
			break;
		default:
			NSAssert(NO,@"Unknown director type");
	}

	return YES;
}

@end



#pragma mark -
#pragma mark CCDirectorIOS

@interface CCDirectorIOS ()
-(void) updateContentScaleFactor;
- (void) releaseTouchDispatcher;
@end

@implementation CCDirectorIOS

- (id) init
{
	if( (self=[super init]) ) {

		// portrait mode default
		deviceOrientation_ = CCDeviceOrientationPortrait;

		__ccContentScaleFactor = 1;
		isContentScaleSupported_ = NO;

		// running thread is main thread on iOS
		runningThread_ = [NSThread currentThread];
	}

	return self;
}

- (void) dealloc
{
	[super dealloc];
}

//
// Timing instrumentation exported to the RootViewController FPS overlay.
// Defined unconditionally because Cocos2D does not see the game's SHOW_FPS
// define, and a few mach_absolute_time samples per frame is free.
#include <mach/mach_time.h>
double gLastCocos2DDrawMs = 0.0;   // total drawScene duration
double gLastCocos2DVisitMs = 0.0;  // just the [runningScene_ visit] cost
double gLastCocos2DSwapMs = 0.0;   // [glView swapBuffers]
double gLastCocos2DClearMs = 0.0;  // glClear
double gLastCocos2DPreMs = 0.0;    // pre-visit (matrix/state setup)
double gLastCocos2DPostMs = 0.0;   // post-visit (state teardown + popMatrix)

// Per-frame draw call counter, incremented by CCSprite (unbatched) and
// CCTextureAtlas (batched via CCSpriteBatchNode). Reset each frame in
// drawScene.
int gCocos2DDrawCallsThisFrame = 0;
int gLastCocos2DDrawCalls = 0;

// Draw the Scene
//
- (void) drawScene
{
	static mach_timebase_info_data_t _tb = {0};
	if (_tb.denom == 0) mach_timebase_info(&_tb);
	uint64_t _drawStart = mach_absolute_time();

	/* calculate "global" dt */
	[self calculateDeltaTime];

	/* tick before glClear: issue #533 */
	if( ! isPaused_ ) {
		[[CCScheduler sharedScheduler] tick: dt];
	}

	gCocos2DDrawCallsThisFrame = 0;

	// Metal renderer bracket: if CCMetalRenderer.active is YES, it
	// acquires a drawable and opens a render pass before visit, and
	// presents after. In that case the GL glClear below is harmless
	// but unread (MetalPresenter.presentAndAdvance short-circuits
	// below when active is YES). If beginFrame fails (no drawable
	// available this tick) we still run the visit so game logic
	// advances, but skip the endFrame/present.
	CCMetalRenderer *metalRenderer = [CCMetalRenderer sharedRenderer];
	BOOL metalActive = metalRenderer.active;
	BOOL metalFrameStarted = NO;
	if (metalActive) {
		// Build an orthographic projection matching cocos2d's
		// setProjection ortho: (0, w, 0, h, -1024s, 1024s) where
		// s = __ccContentScaleFactor.
		const float w = (float)winSizeInPixels_.width;
		const float h = (float)winSizeInPixels_.height;
		const float z = 1024.0f * (float)__ccContentScaleFactor;
		simd_float4x4 proj = CCMetalMakeOrtho(0.0f, w, 0.0f, h, -z, z);
		metalFrameStarted = [metalRenderer beginFrameWithProjection:proj];
	}

	uint64_t _clearStart = mach_absolute_time();
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	uint64_t _clearElapsed = mach_absolute_time() - _clearStart;
	gLastCocos2DClearMs = ((double)_clearElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	/* to avoid flickr, nextScene MUST be here: after tick and before draw.
	 XXX: Which bug is this one. It seems that it can't be reproduced with v0.9 */
	if( nextScene_ )
		[self setNextScene];

	uint64_t _preStart = mach_absolute_time();
	glPushMatrix();

	[self applyOrientation];

	// By default enable VertexArray, ColorArray, TextureCoordArray and Texture2D
	CC_ENABLE_DEFAULT_GL_STATES();
	uint64_t _preElapsed = mach_absolute_time() - _preStart;
	gLastCocos2DPreMs = ((double)_preElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	uint64_t _visitStart = mach_absolute_time();

	/* draw the scene */
	[runningScene_ visit];

	uint64_t _visitElapsed = mach_absolute_time() - _visitStart;
	gLastCocos2DVisitMs = ((double)_visitElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	uint64_t _postStart = mach_absolute_time();
	/* draw the notification node */
	[notificationNode_ visit];

	if( displayFPS_ )
		[self showFPS];

#if CC_ENABLE_PROFILERS
	[self showProfilers];
#endif

	CC_DISABLE_DEFAULT_GL_STATES();

	glPopMatrix();
	uint64_t _postElapsed = mach_absolute_time() - _postStart;
	gLastCocos2DPostMs = ((double)_postElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	totalFrames_++;

	// End the Metal frame before we call -swapBuffers so the presenter
	// can see that a Metal present has already happened this tick and
	// skip its own. If metalFrameStarted is NO we just skip, which
	// means we're running without visible output that frame (the GL
	// draws were harmless).
	if (metalFrameStarted) {
		[metalRenderer endFrameAndPresent];
	}

	uint64_t _swapStart = mach_absolute_time();
	[openGLView_ swapBuffers];
	uint64_t _swapElapsed = mach_absolute_time() - _swapStart;
	gLastCocos2DSwapMs = ((double)_swapElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	uint64_t _drawElapsed = mach_absolute_time() - _drawStart;
	gLastCocos2DDrawMs = ((double)_drawElapsed * (double)_tb.numer / (double)_tb.denom) / 1.0e6;

	gLastCocos2DDrawCalls = gCocos2DDrawCallsThisFrame;
}

-(void) setProjection:(ccDirectorProjection)projection
{
	CGSize size = winSizeInPixels_;
	// Viewport is the projection size scaled down by the render-scale
	// divisor. The projection itself stays at the full winSizeInPixels_
	// so cocos2d's coordinate system / sprite layout / point sizing is
	// completely unchanged — only the rasterized pixel count shrinks.
	GLsizei vw = (GLsizei)(size.width  / COCOS2D_RENDER_SCALE_DIVISOR);
	GLsizei vh = (GLsizei)(size.height / COCOS2D_RENDER_SCALE_DIVISOR);

	switch (projection) {
		case kCCDirectorProjection2D:
			glViewport(0, 0, vw, vh);
			glMatrixMode(GL_PROJECTION);
			glLoadIdentity();
			ccglOrtho(0, size.width, 0, size.height, -1024 * CC_CONTENT_SCALE_FACTOR(), 1024 * CC_CONTENT_SCALE_FACTOR());
			glMatrixMode(GL_MODELVIEW);
			glLoadIdentity();
			break;

		case kCCDirectorProjection3D:
		{
			float zeye = [self getZEye];

			glViewport(0, 0, vw, vh);
			glMatrixMode(GL_PROJECTION);
			glLoadIdentity();
			// accommodate iPad retina while keep backward compatibility
            if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad &&
                [[UIScreen mainScreen] scale] > 1.0 )
            {
                gluPerspective(60, (GLfloat)size.width/size.height, zeye-size.height/2, zeye+size.height/2 );
            } else {
                gluPerspective(60, (GLfloat)size.width/size.height, 0.5f, 1500);
            }

			glMatrixMode(GL_MODELVIEW);
			glLoadIdentity();
			gluLookAt( size.width/2, size.height/2, zeye,
					  size.width/2, size.height/2, 0,
					  0.0f, 1.0f, 0.0f);
			break;
		}

		case kCCDirectorProjectionCustom:
			if( projectionDelegate_ )
				[projectionDelegate_ updateProjection];
			break;

		default:
			CCLOG(@"cocos2d: Director: unrecognized projecgtion");
			break;
	}

	projection_ = projection;
}

#pragma mark Director Integration with a UIKit view

-(void) setOpenGLView:(EAGLView *)view
{
	if( view != openGLView_ ) {

		[super setOpenGLView:view];

		// Use the view's surface size (forced-landscape pixel size in
		// our Metal path) rather than computing from bounds*scale. At
		// app launch the view's bounds are often still portrait before
		// UIKit rotates, which used to leave cocos2d with a portrait
		// winSizeInPixels_ while the Metal backing was landscape.
		winSizeInPixels_ = [openGLView_ surfaceSize];
		winSizeInPoints_ = CGSizeMake(winSizeInPixels_.width / __ccContentScaleFactor,
									  winSizeInPixels_.height / __ccContentScaleFactor);

		if( __ccContentScaleFactor != 1 )
			[self updateContentScaleFactor];

		CCTouchDispatcher *touchDispatcher = [CCTouchDispatcher sharedDispatcher];
		[openGLView_ setTouchDelegate: touchDispatcher];
		[touchDispatcher setDispatchEvents: YES];
	}
}

#pragma mark Director - Retina Display

-(CGFloat) contentScaleFactor
{
	return __ccContentScaleFactor;
}

-(void) setContentScaleFactor:(CGFloat)scaleFactor
{
	if( scaleFactor != __ccContentScaleFactor ) {

		__ccContentScaleFactor = scaleFactor;

		if( openGLView_ ) {
			[self updateContentScaleFactor];
			// Pick winSizeInPixels_ up from the view's surfaceSize,
			// which our Metal-backed EAGLView keeps force-landscape
			// and at the correct pixel resolution for the current
			// scale factor.
			winSizeInPixels_ = [openGLView_ surfaceSize];
			winSizeInPoints_ = CGSizeMake(winSizeInPixels_.width / scaleFactor,
										  winSizeInPixels_.height / scaleFactor);
		} else {
			winSizeInPixels_ = CGSizeMake( winSizeInPoints_.width * scaleFactor, winSizeInPoints_.height * scaleFactor );
		}

		// update projection
		[self setProjection:projection_];
	}
}

-(void) updateContentScaleFactor
{
	// Based on code snippet from: http://developer.apple.com/iphone/prerelease/library/snippets/sp2010/sp28.html
	if ([openGLView_ respondsToSelector:@selector(setContentScaleFactor:)])
	{
		[openGLView_ setContentScaleFactor: __ccContentScaleFactor];

		isContentScaleSupported_ = YES;
	}
	else
	{
		CCLOG(@"cocos2d: WARNING: calling setContentScaleFactor on iOS < 4. Using fallback mechanism");
		isContentScaleSupported_ = NO;
	}
}

-(BOOL) enableRetinaDisplay:(BOOL)enabled
{
	// Already enabled ?
	if( enabled && __ccContentScaleFactor == 2 )
		return YES;

	// Already disabled
	if( ! enabled && __ccContentScaleFactor == 1 )
		return YES;

	// setContentScaleFactor is not supported
	if (! [openGLView_ respondsToSelector:@selector(setContentScaleFactor:)])
		return NO;

	// SD device
	if ([[UIScreen mainScreen] scale] == 1.0)
		return NO;

	float newScale = enabled ? 2 : 1;
	[self setContentScaleFactor:newScale];

	return YES;
}

// overriden, don't call super
-(void) reshapeProjection:(CGSize)size
{
	// Caller (EAGLView.layoutSubviews) passes the pixel size it wants
	// us to use — with the Metal path that's our force-landscape
	// surfaceSize. Ignore [openGLView_ bounds] because UIKit may still
	// report a portrait frame at this point.
	winSizeInPixels_ = size;
	winSizeInPoints_ = CGSizeMake(size.width / __ccContentScaleFactor,
								  size.height / __ccContentScaleFactor);

	[self setProjection:projection_];
}

#pragma mark Director Scene Landscape

-(CGPoint)convertToGL:(CGPoint)uiPoint
{
	CGSize s = winSizeInPoints_;
	float newY = s.height - uiPoint.y;
	float newX = s.width - uiPoint.x;

	CGPoint ret = CGPointZero;
	switch ( deviceOrientation_) {
		case CCDeviceOrientationPortrait:
			ret = ccp( uiPoint.x, newY );
			break;
		case CCDeviceOrientationPortraitUpsideDown:
			ret = ccp(newX, uiPoint.y);
			break;
		case CCDeviceOrientationLandscapeLeft:
			ret.x = uiPoint.y;
			ret.y = uiPoint.x;
			break;
		case CCDeviceOrientationLandscapeRight:
			ret.x = newY;
			ret.y = newX;
			break;
	}
	return ret;
}

-(CGPoint)convertToUI:(CGPoint)glPoint
{
	CGSize winSize = winSizeInPoints_;
	int oppositeX = winSize.width - glPoint.x;
	int oppositeY = winSize.height - glPoint.y;
	CGPoint uiPoint = CGPointZero;
	switch ( deviceOrientation_) {
		case CCDeviceOrientationPortrait:
			uiPoint = ccp(glPoint.x, oppositeY);
			break;
		case CCDeviceOrientationPortraitUpsideDown:
			uiPoint = ccp(oppositeX, glPoint.y);
			break;
		case CCDeviceOrientationLandscapeLeft:
			uiPoint = ccp(glPoint.y, glPoint.x);
			break;
		case CCDeviceOrientationLandscapeRight:
			// Can't use oppositeX/Y because x/y are flipped
			uiPoint = ccp(winSize.width-glPoint.y, winSize.height-glPoint.x);
			break;
	}
	return uiPoint;
}

// get the current size of the glview
-(CGSize) winSize
{
	CGSize s = winSizeInPoints_;

	if( deviceOrientation_ == CCDeviceOrientationLandscapeLeft || deviceOrientation_ == CCDeviceOrientationLandscapeRight ) {
		// swap x,y in landscape mode
		CGSize tmp = s;
		s.width = tmp.height;
		s.height = tmp.width;
	}
	return s;
}

-(CGSize) winSizeInPixels
{
	CGSize s = [self winSize];

	s.width *= CC_CONTENT_SCALE_FACTOR();
	s.height *= CC_CONTENT_SCALE_FACTOR();

	return s;
}

-(ccDeviceOrientation) deviceOrientation
{
	return deviceOrientation_;
}

- (void) setDeviceOrientation:(ccDeviceOrientation) orientation
{
	if( deviceOrientation_ != orientation ) {
		deviceOrientation_ = orientation;
		switch( deviceOrientation_) {
			case CCDeviceOrientationPortrait:
				[[UIApplication sharedApplication] setStatusBarOrientation: UIInterfaceOrientationPortrait animated:NO];
				break;
			case CCDeviceOrientationPortraitUpsideDown:
				[[UIApplication sharedApplication] setStatusBarOrientation: UIInterfaceOrientationPortraitUpsideDown animated:NO];
				break;
			case CCDeviceOrientationLandscapeLeft:
				[[UIApplication sharedApplication] setStatusBarOrientation: UIInterfaceOrientationLandscapeRight animated:NO];
				break;
			case CCDeviceOrientationLandscapeRight:
				[[UIApplication sharedApplication] setStatusBarOrientation: UIInterfaceOrientationLandscapeLeft animated:NO];
				break;
			default:
				NSLog(@"Director: Unknown device orientation");
				break;
		}
	}
}

-(void) applyOrientation
{
	CGSize s = winSizeInPixels_;
	float w = s.width / 2;
	float h = s.height / 2;

	// XXX it's using hardcoded values.
	// What if the the screen size changes in the future?
	switch ( deviceOrientation_ ) {
		case CCDeviceOrientationPortrait:
			// nothing
			break;
		case CCDeviceOrientationPortraitUpsideDown:
			// upside down
			glTranslatef(w,h,0);
			glRotatef(180,0,0,1);
			glTranslatef(-w,-h,0);
			break;
		case CCDeviceOrientationLandscapeRight:
			glTranslatef(w,h,0);
			glRotatef(90,0,0,1);
			glTranslatef(-h,-w,0);
			break;
		case CCDeviceOrientationLandscapeLeft:
			glTranslatef(w,h,0);
			glRotatef(-90,0,0,1);
			glTranslatef(-h,-w,0);
			break;
	}
}

- (void) releaseTouchDispatcher
{
    [[CCTouchDispatcher sharedDispatcher] release];
}

-(void) end
{
	[[CCTouchDispatcher sharedDispatcher] removeAllDelegates];

    //can't release the touch dispatcher if the call to end is made inside a touch handler, have to schedule it for next loop
    //for the rare case when the EAGLView isn't deallocated when the director is ended, the next touch in the view would cause a crash
    //disable the following line if the EAGLView is shared between cocos and another OpenGL program outside of cocos

    [self performSelectorOnMainThread:@selector(releaseTouchDispatcher) withObject:nil waitUntilDone:NO];

	[super end];

}

@end


#pragma mark -
#pragma mark Director TimerDirector

@implementation CCDirectorTimer
- (void)startAnimation
{
	NSAssert( animationTimer == nil, @"animationTimer must be nil. Calling startAnimation twice?");

	if( gettimeofday( &lastUpdate_, NULL) != 0 ) {
		CCLOG(@"cocos2d: Director: Error in gettimeofday");
	}

	animationTimer = [NSTimer scheduledTimerWithTimeInterval:animationInterval_ target:self selector:@selector(mainLoop) userInfo:nil repeats:YES];

	//
	//	If you want to attach the opengl view into UIScrollView
	//  uncomment this line to prevent 'freezing'.
	//	It doesn't work on with the Fast Director
	//
	//	[[NSRunLoop currentRunLoop] addTimer:animationTimer
	//								 forMode:NSRunLoopCommonModes];
}

-(void) mainLoop
{
	[self drawScene];
}

- (void)stopAnimation
{
	[animationTimer invalidate];
	animationTimer = nil;
}

- (void)setAnimationInterval:(NSTimeInterval)interval
{
	animationInterval_ = interval;

	if(animationTimer) {
		[self stopAnimation];
		[self startAnimation];
	}
}

-(void) dealloc
{
	[animationTimer release];
	[super dealloc];
}
@end


#pragma mark -
#pragma mark Director DirectorFast

@implementation CCDirectorFast

- (id) init
{
	if(( self = [super init] )) {

#if CC_DIRECTOR_DISPATCH_FAST_EVENTS
		CCLOG(@"cocos2d: Fast Events enabled");
#else
		CCLOG(@"cocos2d: Fast Events disabled");
#endif
		isRunning = NO;

		// XXX:
		// XXX: Don't create any autorelease object before calling "fast director"
		// XXX: else it will be leaked
		// XXX:
		autoreleasePool = [NSAutoreleasePool new];
	}

	return self;
}

- (void) startAnimation
{
	NSAssert( isRunning == NO, @"isRunning must be NO. Calling startAnimation twice?");

	// XXX:
	// XXX: release autorelease objects created
	// XXX: between "use fast director" and "runWithScene"
	// XXX:
	[autoreleasePool release];
	autoreleasePool = nil;

	if ( gettimeofday( &lastUpdate_, NULL) != 0 ) {
		CCLOG(@"cocos2d: Director: Error in gettimeofday");
	}


	isRunning = YES;

	SEL selector = @selector(mainLoop);
	NSMethodSignature* sig = [[[CCDirector sharedDirector] class]
							  instanceMethodSignatureForSelector:selector];
	NSInvocation* invocation = [NSInvocation
								invocationWithMethodSignature:sig];
	[invocation setTarget:[CCDirector sharedDirector]];
	[invocation setSelector:selector];
	[invocation performSelectorOnMainThread:@selector(invokeWithTarget:)
								 withObject:[CCDirector sharedDirector] waitUntilDone:NO];

//	NSInvocationOperation *loopOperation = [[[NSInvocationOperation alloc]
//											 initWithTarget:self selector:@selector(mainLoop) object:nil]
//											autorelease];
//
//	[loopOperation performSelectorOnMainThread:@selector(start) withObject:nil
//								 waitUntilDone:NO];
}

-(void) mainLoop
{
	while (isRunning) {

		NSAutoreleasePool *loopPool = [NSAutoreleasePool new];

#if CC_DIRECTOR_DISPATCH_FAST_EVENTS
		while( CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004f, FALSE) == kCFRunLoopRunHandledSource);
#else
		while(CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, TRUE) == kCFRunLoopRunHandledSource);
#endif

		if (isPaused_) {
			usleep(250000); // Sleep for a quarter of a second (250,000 microseconds) so that the framerate is 4 fps.
		}

		[self drawScene];

#if CC_DIRECTOR_DISPATCH_FAST_EVENTS
		while( CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004f, FALSE) == kCFRunLoopRunHandledSource);
#else
		while(CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, TRUE) == kCFRunLoopRunHandledSource);
#endif

		[loopPool release];
	}
}
- (void) stopAnimation
{
	isRunning = NO;
}

- (void)setAnimationInterval:(NSTimeInterval)interval
{
	NSLog(@"FastDirectory doesn't support setAnimationInterval, yet");
}
@end

#pragma mark -
#pragma mark Director DirectorThreadedFast

@implementation CCDirectorFastThreaded

- (id) init
{
	if(( self = [super init] )) {
		isRunning = NO;
	}

	return self;
}

- (void) startAnimation
{
	NSAssert( isRunning == NO, @"isRunning must be NO. Calling startAnimation twice?");

	if ( gettimeofday( &lastUpdate_, NULL) != 0 ) {
		CCLOG(@"cocos2d: ThreadedFastDirector: Error on gettimeofday");
	}

	isRunning = YES;

	NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(mainLoop) object:nil];
	[thread start];
	[thread release];
}

-(void) mainLoop
{
	while( ![[NSThread currentThread] isCancelled] ) {
		if( isRunning )
			[self performSelectorOnMainThread:@selector(drawScene) withObject:nil waitUntilDone:YES];

		if (isPaused_) {
			usleep(250000); // Sleep for a quarter of a second (250,000 microseconds) so that the framerate is 4 fps.
		} else {
//			usleep(2000);
		}
	}
}
- (void) stopAnimation
{
	isRunning = NO;
}

- (void)setAnimationInterval:(NSTimeInterval)interval
{
	NSLog(@"FastDirector doesn't support setAnimationInterval, yet");
}
@end

#pragma mark -
#pragma mark DirectorDisplayLink

// Allows building DisplayLinkDirector for pre-3.1 SDKS
// without getting compiler warnings.
@interface NSObject(CADisplayLink)
+ (id) displayLinkWithTarget:(id)arg1 selector:(SEL)arg2;
- (void) addToRunLoop:(id)arg1 forMode:(id)arg2;
- (void) setFrameInterval:(int)interval;
- (void) invalidate;
@end

@implementation CCDirectorDisplayLink

- (void)setAnimationInterval:(NSTimeInterval)interval
{
	animationInterval_ = interval;
	if(displayLink){
		[self stopAnimation];
		[self startAnimation];
	}
}

- (void) startAnimation
{
	NSAssert( displayLink == nil, @"displayLink must be nil. Calling startAnimation twice?");

	if ( gettimeofday( &lastUpdate_, NULL) != 0 ) {
		CCLOG(@"cocos2d: DisplayLinkDirector: Error on gettimeofday");
	}

	// Target FPS derived from the requested animation interval. iOS will
	// clamp us to the display's actual maximum refresh rate (60 or 120).
	NSInteger targetFPS = (NSInteger) round(1.0 / animationInterval_);
	if (targetFPS < 1) targetFPS = 1;

	CCLOG(@"cocos2d: Preferred frames per second: %ld", (long)targetFPS);

	displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(mainLoop:)];

	if (@available(iOS 15.0, *)) {
		// Loose range so iOS can adapt (e.g. under thermal / Low Power),
		// but bias toward the requested target.
		float maxFPS = (float)targetFPS;
		float minFPS = MIN(30.0f, maxFPS);
		((CADisplayLink*)displayLink).preferredFrameRateRange =
			CAFrameRateRangeMake(minFPS, maxFPS, maxFPS);
	} else {
		((CADisplayLink*)displayLink).preferredFramesPerSecond = targetFPS;
	}

    if (runLoopCommon_)
            	[displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    else
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

-(void) mainLoop:(id)sender
{
    @try
    {
        [self drawScene];
    }
    @catch (NSException* exception)
    {
     	[self stopAnimation];
        [exception performSelector:@selector(raise) withObject:nil afterDelay:0];
    }
}

- (void) stopAnimation
{
	[displayLink invalidate];
	displayLink = nil;
}

-(void) dealloc
{
	[displayLink release];
	[super dealloc];
}

- (void) setRunLoopCommon:(BOOL) common
{
    BOOL running = NO;
    if (displayLink)
    {
        running = YES;
        [self stopAnimation];
    }
    runLoopCommon_ = common;

    if (running)
        [self startAnimation];

}
@end

#endif // __IPHONE_OS_VERSION_MAX_ALLOWED
