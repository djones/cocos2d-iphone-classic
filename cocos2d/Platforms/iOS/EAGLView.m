/*

===== IMPORTANT =====

This is sample code demonstrating API, technology or techniques in development.
Although this sample code has been reviewed for technical accuracy, it is not
final. Apple is supplying this information to help you plan for the adoption of
the technologies and programming interfaces described herein. This information
is subject to change, and software implemented based on this sample code should
be tested with final operating system software and final documentation. Newer
versions of this sample code may be provided with future seeds of the API or
technology. For information about updates to this and other developer
documentation, view the New & Updated sidebars in subsequent documentation
seeds.

=====================

File: EAGLView.m
Abstract: Convenience class that wraps the CAEAGLLayer from CoreAnimation into a
UIView subclass.

Version: 1.3

Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple Inc.
("Apple") in consideration of your agreement to the following terms, and your
use, installation, modification or redistribution of this Apple software
constitutes acceptance of these terms.  If you do not agree with these terms,
please do not use, install, modify or redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and subject
to these terms, Apple grants you a personal, non-exclusive license, under
Apple's copyrights in this original Apple software (the "Apple Software"), to
use, reproduce, modify and redistribute the Apple Software, with or without
modifications, in source and/or binary forms; provided that if you redistribute
the Apple Software in its entirety and without modifications, you must retain
this notice and the following text and disclaimers in all such redistributions
of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may be used
to endorse or promote products derived from the Apple Software without specific
prior written permission from Apple.  Except as expressly stated in this notice,
no other rights or licenses, express or implied, are granted by Apple herein,
including but not limited to any patent rights that may be infringed by your
derivative works or by other works in which the Apple Software may be
incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO
WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED
WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN
COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, MODIFICATION AND/OR
DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF
CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF
APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2008 Apple Inc. All Rights Reserved.

*/

// Only compile this code on iOS. These files should NOT be included on your Mac project.
// But in case they are included, it won't be compiled.
#import <Availability.h>
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

#import <QuartzCore/QuartzCore.h>

#import "EAGLView.h"
#import "ES1Renderer.h"
#import "../../CCDirector.h"
#import "../../ccMacros.h"
#import "../../CCConfiguration.h"
#import "../../Support/OpenGL_Internal.h"

// Parent-repo header. The motorbike Xcode target compiles these cocos2d
// files alongside our own code, so this resolves through the standard
// header search paths.
#import "MetalPresenter.h"


//CLASS IMPLEMENTATIONS:

@interface EAGLView (Private)
- (BOOL) setupSurfaceWithSharegroup:(EAGLSharegroup*)sharegroup;
- (unsigned int) convertPixelFormat:(NSString*) pixelFormat;
@end

// On iOS 26, CAEAGLLayer presentation is effectively paced at 60 Hz through
// a GL-ES-on-Metal compatibility shim, making it impossible to sustain
// 120 FPS on ProMotion devices with this cocos2d fork. We now back the view
// with CAMetalLayer instead, render cocos2d into an IOSurface-backed FBO
// owned by a MetalPresenter, and present through the CAMetalLayer's real
// Metal swapchain (which supports true 120 Hz triple-buffering). The ES1
// GL pipeline inside cocos2d is unchanged — only the surface the GL
// renders into and the mechanism that presents it are different.
@implementation EAGLView
{
	MetalPresenter *metalPresenter_;
}

@synthesize surfaceSize=size_;
@synthesize pixelFormat=pixelformat_, depthFormat=depthFormat_;
@synthesize touchDelegate=touchDelegate_;
@synthesize context=context_;
@synthesize multiSampling=multiSampling_;

+ (Class) layerClass
{
	return [CAMetalLayer class];
}

+ (id) viewWithFrame:(CGRect)frame
{
	return [[[self alloc] initWithFrame:frame] autorelease];
}

+ (id) viewWithFrame:(CGRect)frame pixelFormat:(NSString*)format
{
	return [[[self alloc] initWithFrame:frame pixelFormat:format] autorelease];
}

+ (id) viewWithFrame:(CGRect)frame pixelFormat:(NSString*)format depthFormat:(GLuint)depth
{
	return [[[self alloc] initWithFrame:frame pixelFormat:format depthFormat:depth preserveBackbuffer:NO sharegroup:nil multiSampling:NO numberOfSamples:0] autorelease];
}

+ (id) viewWithFrame:(CGRect)frame pixelFormat:(NSString*)format depthFormat:(GLuint)depth preserveBackbuffer:(BOOL)retained sharegroup:(EAGLSharegroup*)sharegroup multiSampling:(BOOL)multisampling numberOfSamples:(unsigned int)samples
{
	return [[[self alloc] initWithFrame:frame pixelFormat:format depthFormat:depth preserveBackbuffer:retained sharegroup:sharegroup multiSampling:multisampling numberOfSamples:samples] autorelease];
}

- (id) initWithFrame:(CGRect)frame
{
	return [self initWithFrame:frame pixelFormat:kEAGLColorFormatRGB565 depthFormat:0 preserveBackbuffer:NO sharegroup:nil multiSampling:NO numberOfSamples:0];
}

- (id) initWithFrame:(CGRect)frame pixelFormat:(NSString*)format
{
	return [self initWithFrame:frame pixelFormat:format depthFormat:0 preserveBackbuffer:NO sharegroup:nil multiSampling:NO numberOfSamples:0];
}

- (id) initWithFrame:(CGRect)frame pixelFormat:(NSString*)format depthFormat:(GLuint)depth preserveBackbuffer:(BOOL)retained sharegroup:(EAGLSharegroup*)sharegroup multiSampling:(BOOL)sampling numberOfSamples:(unsigned int)nSamples
{
	if((self = [super initWithFrame:frame]))
	{
		pixelformat_ = format;
		depthFormat_ = depth;
		multiSampling_ = sampling;
		requestedSamples_ = nSamples;
		preserveBackbuffer_ = retained;
        first_ = NO;

		if( ! [self setupSurfaceWithSharegroup:sharegroup] ) {
			[self release];
			return nil;
		}
	}

	return self;
}

-(id) initWithCoder:(NSCoder *)aDecoder
{
	if( (self = [super initWithCoder:aDecoder]) ) {

		CAEAGLLayer*			eaglLayer = (CAEAGLLayer*)[self layer];

		pixelformat_ = kEAGLColorFormatRGB565;
		depthFormat_ = 0; // GL_DEPTH_COMPONENT24_OES;
		multiSampling_= NO;
		requestedSamples_ = 0;
		size_ = [eaglLayer bounds].size;
        
        first_ =YES; 

		if( ! [self setupSurfaceWithSharegroup:nil] ) {
			[self release];
			return nil;
		}
    }

    return self;
}

-(BOOL) setupSurfaceWithSharegroup:(EAGLSharegroup*)sharegroup
{
	// Layer is now a CAMetalLayer, not CAEAGLLayer — skip the old EAGL
	// drawableProperties / renderbufferStorage:fromDrawable: path and
	// stand up an EAGLContext + MetalPresenter pair instead.
	context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1
									 sharegroup:sharegroup];
	if (!context_ || ![EAGLContext setCurrentContext:context_]) {
		CCLOG(@"cocos2d: EAGLView: could not create ES1 context");
		return NO;
	}

	// Backing size in PIXELS. Our view frame is in points and the layer's
	// contentsScale is the points→pixels factor (2x or 3x Retina).
	CGFloat scale = [[UIScreen mainScreen] scale];
	CGSize pixelSize = CGSizeMake(self.bounds.size.width * scale,
								 self.bounds.size.height * scale);
	size_ = pixelSize;

	CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
	metalPresenter_ = [[MetalPresenter alloc] initWithLayer:metalLayer
													   size:pixelSize
													  scale:scale
												  glContext:context_];
	if (!metalPresenter_) {
		CCLOG(@"cocos2d: EAGLView: MetalPresenter init failed");
		return NO;
	}

	// Bind slot 0 so the very first drawScene renders into it.
	[metalPresenter_ bindCurrentFramebuffer];

	// Set the GL viewport to match the backing size.
	glViewport(0, 0, (GLsizei)pixelSize.width, (GLsizei)pixelSize.height);

	discardFramebufferSupported_ = NO; // Metal path doesn't use discard hints.

	return YES;
}

- (void) dealloc
{
	CCLOGINFO(@"cocos2d: deallocing %@", self);

	// Metal path: metalPresenter_ is an ARC-compiled class but THIS file
	// is MRC, so we manage its reference manually.
	[metalPresenter_ release];
	// Legacy renderer_ ivar is never populated on the Metal path;
	// release-to-nil is a no-op.
	[renderer_ release];
	[context_ release];
	[super dealloc];
}

- (void) layoutSubviews
{
    [super layoutSubviews];

    // Checking whether size has changed — UIKit also triggers layoutSubviews
    // for unrelated reasons and we don't want to rebuild the pool each time.
    CGFloat scale = [[UIScreen mainScreen] scale];
    CGSize pixelSize = CGSizeMake(self.bounds.size.width * scale,
                                  self.bounds.size.height * scale);

    BOOL sizeChanged = (pixelSize.width != size_.width || pixelSize.height != size_.height);
    if (!sizeChanged && !first_) return;

    first_ = NO;

    [EAGLContext setCurrentContext:context_];

    if (![metalPresenter_ resizeTo:pixelSize scale:scale]) {
        CCLOG(@"cocos2d: EAGLView: MetalPresenter resize failed");
        return;
    }

    size_ = pixelSize;
    [metalPresenter_ bindCurrentFramebuffer];
    glViewport(0, 0, (GLsizei)pixelSize.width, (GLsizei)pixelSize.height);

    // Issue #914 #924
    CCDirector *director = [CCDirector sharedDirector];
    [director reshapeProjection:size_];

    // Avoid flicker. Issue #350
    [director performSelectorOnMainThread:@selector(drawScene) withObject:nil waitUntilDone:YES];
}

- (void) swapBuffers
{
	// Metal path: hand the current slot's IOSurface to a Metal blit
	// encoder, present the resulting drawable, and advance to the next
	// slot (with its FBO now bound for the next frame). This takes the
	// place of the old -[EAGLContext presentRenderbuffer:] call.
	[metalPresenter_ presentAndAdvance];

#if COCOS2D_DEBUG
	CHECK_GL_ERROR();
#endif
}

- (void) setContentScaleFactor:(CGFloat)scaleFactor
{
	CGFloat oldScale = self.contentScaleFactor;
	[super setContentScaleFactor:scaleFactor];
	if (metalPresenter_ && scaleFactor != oldScale) {
		// Cocos2D calls this from enableRetinaDisplay: after our initial
		// setupSurface, which means our slot pool was built at the screen's
		// native scale but cocos2d now wants us to render at a different
		// scale. Rebuild the pool at the new scale.
		[EAGLContext setCurrentContext:context_];
		CGSize pixelSize = CGSizeMake(self.bounds.size.width * scaleFactor,
									 self.bounds.size.height * scaleFactor);
		if ([metalPresenter_ resizeTo:pixelSize scale:scaleFactor]) {
			size_ = pixelSize;
			[metalPresenter_ bindCurrentFramebuffer];
			glViewport(0, 0, (GLsizei)pixelSize.width, (GLsizei)pixelSize.height);
		}
	}
}

- (unsigned int) convertPixelFormat:(NSString*) pixelFormat
{
	// define the pixel format
	GLenum pFormat;


	if([pixelFormat isEqualToString:@"EAGLColorFormat565"])
		pFormat = GL_RGB565_OES;
	else
		pFormat = GL_RGBA8_OES;

	return pFormat;
}

#pragma mark EAGLView - Point conversion

- (CGPoint) convertPointFromViewToSurface:(CGPoint)point
{
	CGRect bounds = [self bounds];

	return CGPointMake((point.x - bounds.origin.x) / bounds.size.width * size_.width, (point.y - bounds.origin.y) / bounds.size.height * size_.height);
}

- (CGRect) convertRectFromViewToSurface:(CGRect)rect
{
	CGRect bounds = [self bounds];

	return CGRectMake((rect.origin.x - bounds.origin.x) / bounds.size.width * size_.width, (rect.origin.y - bounds.origin.y) / bounds.size.height * size_.height, rect.size.width / bounds.size.width * size_.width, rect.size.height / bounds.size.height * size_.height);
}

// Pass the touches to the superview
#pragma mark EAGLView - Touch Delegate

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	if(touchDelegate_)
	{
		[touchDelegate_ touchesBegan:touches withEvent:event];
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	if(touchDelegate_)
	{
		[touchDelegate_ touchesMoved:touches withEvent:event];
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	if(touchDelegate_)
	{
		[touchDelegate_ touchesEnded:touches withEvent:event];
	}
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	if(touchDelegate_)
	{
		[touchDelegate_ touchesCancelled:touches withEvent:event];
	}
}

@end

#endif // __IPHONE_OS_VERSION_MAX_ALLOWED
