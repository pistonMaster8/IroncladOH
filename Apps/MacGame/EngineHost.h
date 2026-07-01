// EngineHost.h — Objective-C interface bridging Swift ↔ C++ engine.

#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps the C++ engine (GameSim + MetalRenderer) for use from Swift.
@interface EngineHost : NSObject

/// Attach to the CAMetalLayer of an MTKView. Call once before the view appears.
/// Swift: host.setup(layer:width:height:)
- (BOOL)setupWithLayer:(CAMetalLayer*)layer
                 width:(NSUInteger)w
                height:(NSUInteger)h
    NS_SWIFT_NAME(setup(layer:width:height:));

/// Called each display-link frame with the elapsed real time (seconds).
- (void)renderFrame:(double)dt;

/// Notify the engine when the drawable size changes.
- (void)resizeWidth:(NSUInteger)w height:(NSUInteger)h
    NS_SWIFT_NAME(resize(width:height:));

/// Notify of a display scale change (Retina / ProMotion).
- (void)setDisplayScale:(double)scale;

/// Mouse input — normalised [0,1] coordinates in the viewport.
- (void)mouseDownX:(double)x y:(double)y button:(int)btn
    NS_SWIFT_NAME(mouseDown(x:y:button:));
- (void)mouseUpX:(double)x y:(double)y button:(int)btn
    NS_SWIFT_NAME(mouseUp(x:y:button:));
- (void)mouseMovedX:(double)x y:(double)y deltaX:(double)dx deltaY:(double)dy
    NS_SWIFT_NAME(mouseMoved(x:y:deltaX:deltaY:));
- (void)scrollDelta:(double)delta;

/// Trackpad pinch gesture (positive = spread = zoom in).
- (void)magnifyDelta:(double)delta
    NS_SWIFT_NAME(magnifyDelta(_:));

/// Two-finger scroll — orbits the camera around its target.
- (void)orbitDeltaX:(double)dx deltaY:(double)dy
    NS_SWIFT_NAME(orbitDelta(deltaX:deltaY:));

/// Left-drag pan — translates the camera target across the ground plane.
- (void)panDeltaX:(double)dx deltaY:(double)dy
    NS_SWIFT_NAME(panDelta(deltaX:deltaY:));

/// Keyboard input — passes raw macOS/UIKit key codes.
- (void)keyDown:(int)keyCode;
- (void)keyUp:(int)keyCode;

/// Terrace face roughness (G panel)
@property (readwrite) float terraceNoiseStrength;
@property (readwrite) float terraceNoiseScale;

/// G-mode (grass editor panel) — toggled by G key; readonly from Swift.
@property (readonly)  BOOL  gModeActive;

/// Shell grass controls (G panel)
@property (readwrite) BOOL  shellGrassVisible;
@property (readwrite) float shellGrassDensity;
@property (readwrite) float shellColorBaseR;
@property (readwrite) float shellColorBaseG;
@property (readwrite) float shellColorBaseB;
@property (readwrite) float shellColorTipR;
@property (readwrite) float shellColorTipG;
@property (readwrite) float shellColorTipB;

/// Long grass controls (G panel)
@property (readwrite) BOOL  longGrassVisible;
@property (readwrite) float longGrassDensity;
@property (readwrite) float longStepEdgeDensity;
@property (readwrite) float longColorBaseR;
@property (readwrite) float longColorBaseG;
@property (readwrite) float longColorBaseB;
@property (readwrite) float longColorTipR;
@property (readwrite) float longColorTipG;
@property (readwrite) float longColorTipB;
@property (readwrite) int grassGenerationMode;
@property (readwrite) int grassOptimizationMode;
@property (readwrite) float grassOptStartDistance;
@property (readwrite) float grassOptEndDistance;
@property (readwrite) float grassOptDensityScale;
@property (readwrite) float grassOptStrength;
@property (readwrite) int grassOptCurve;
@property (readwrite) int grassOptOriginMode;
@property (readwrite) float grassOptOriginMaxOffset;
@property (readwrite) int grassImitationMode;
@property (readwrite) float grassImitationFadeStart;
@property (readwrite) float grassImitationFadeEnd;
@property (readwrite) float grassImitationOpacity;
@property (readwrite) float grassImitationDensity;
@property (readwrite) float grassImitationHeight;
@property (readwrite) int grassImitationOriginMode;
@property (readwrite) float grassImitationOriginMaxOffset;

/// A-mode (animation editor panel) — toggled by A key; readonly from Swift.
@property (readonly)  BOOL  aModeActive;

/// Animation gait parameters, exposed as a flat indexed list for the A panel.
/// (0..11 = walk, 12..23 = run.) Changing a value live-rebuilds the clip library.
@property (readonly) NSInteger animParamCount;
- (float)animParamValue:(NSInteger)index;
- (void)setAnimParam:(NSInteger)index value:(float)value
    NS_SWIFT_NAME(setAnimParam(_:value:));
- (NSString*)animParamLabel:(NSInteger)index
    NS_SWIFT_NAME(animParamLabel(_:));
/// Per-parameter stride-phase offset (degrees), same indexing as the values.
- (float)animPhaseValue:(NSInteger)index;
- (void)setAnimPhase:(NSInteger)index value:(float)value
    NS_SWIFT_NAME(setAnimPhase(_:value:));
/// Copy the walk gait params + phases onto the run gait (seed run from walk).
- (void)copyAnimWalkToRun;

/// Preview toggle: force animated units to play the walk cycle in place.
@property (readwrite) BOOL animPreviewWalk;

/// T-mode (tree editor panel) — toggled by T key; readonly from Swift.
@property (readonly)  BOOL  tModeActive;
/// Tree trunk controls (T panel)
@property (readwrite) BOOL  treesVisible;
@property (readwrite) float treeDensity;
@property (readwrite) float treeColorR;
@property (readwrite) float treeColorG;
@property (readwrite) float treeColorB;
@property (readwrite) float treeLeanMin;
@property (readwrite) float treeLeanMax;
@property (readwrite) float treeDeadDensity;
@property (readwrite) float treeDeadLeanMin;
@property (readwrite) float treeDeadLeanMax;
@property (readwrite) float treeHeightMin;
@property (readwrite) float treeHeightMax;
@property (readwrite) float treeThickness;
/// Pull node — click on the ground to place; trees lean toward/away by `treePull`.
/// Magnitude is the likelihood; sign sets direction (+ toward node, − away from it).
@property (readwrite) BOOL  treePullPlaceMode;   // when YES, a click places the node
@property (readonly)  BOOL  treePullActive;      // YES once a node has been placed
@property (readwrite) float treePull;            // -1..1 living trees (sign = toward/away)
@property (readwrite) float treeDeadPull;        // -1..1 dead trees  (sign = toward/away)

/// Set to YES for one frame after loadState runs; cleared by Swift draw() once it
/// has synced the loaded values back into EngineStats.
@property (readwrite) BOOL  stateJustLoaded;

/// Erosion params restored from the last save — read by Swift after stateJustLoaded.
@property (readonly) float savedErosionStep;
@property (readonly) float savedErosionHeight;
@property (readonly) float savedErosionAngle;

/// D-mode active (terrain editor visible). Toggled by D key; readonly from Swift.
@property (readonly)  BOOL dModeActive;
/// Terrain node placement mode — toggled by Swift UI button.
@property (readwrite) BOOL terrainNodePlaceMode;
/// Construction-plane overlay visibility — toggled by Swift UI button.
@property (readwrite) BOOL constructionPlaneVisible;

/// Auto-node mode — when YES, the construction plane is auto-filled with a grid of
/// terrain nodes whose density is set by `autoNodeDensity` (interior nodes per axis).
@property (readwrite) BOOL  autoNode;
@property (readwrite) float autoNodeDensity;

/// Apply the construction plane to the real terrain. `step` sets the band slicing;
/// `height` brute-forces the world rise per band (0 → rise equals step); `angle` is the
/// riser angle from horizontal in degrees (90 → vertical). One-shot.
- (void)generateTerrainWithStep:(float)step height:(float)height angle:(float)angle
    NS_SWIFT_NAME(generateTerrain(step:height:angle:));

/// Apply a terrain preset (0 Flat, 1 Hill, 2 Bowl, 3 Ridge, 4 Dunes, 5 Procedural). Node
/// presets use the given erosion params; the procedural preset uses `groundScale` to enlarge
/// the ground plane. One-shot.
- (void)applyTerrainPreset:(NSInteger)index step:(float)step height:(float)height
                     angle:(float)angle groundScale:(float)scale
    NS_SWIFT_NAME(applyTerrainPreset(_:step:height:angle:groundScale:));

/// Debug info readable by Swift debug overlay.
@property (readonly) NSInteger fps;
@property (readonly) double    frameTimeMs;
@property (readonly) NSInteger drawCalls;
@property (readonly) NSInteger visibleEntities;
@property (readonly) NSInteger projectileCount;
@property (readonly) double    gpuTimeMs;

/// Input debug — updated each frame; lets the overlay diagnose event delivery.
@property (readonly) double    cursorNormX;     // [0,1] screen x
@property (readonly) double    cursorNormY;     // [0,1] screen y (0=top)
@property (readonly) double    cursorFloorX;    // world x projected to y=0 plane
@property (readonly) double    cursorFloorZ;    // world z projected to y=0 plane
@property (readonly) NSInteger lastClickBtn;    // -1=none, 0=left, 1=right
@property (readonly) NSInteger mouseMoveCount;  // cumulative move events received

@end

NS_ASSUME_NONNULL_END
