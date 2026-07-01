#pragma once

// Run all animation unit tests.  Returns true if all pass.
// Prints pass/fail status for each group to stdout.
bool RunAnimationTests();

bool TestSkeletonCreation();
bool TestForwardKinematics();
bool TestPoseBlending();
bool TestClipSampling();
bool TestKeyframeInterpolation();
bool TestTwoBoneIK();
bool TestStateMachineTransitions();
bool TestAnimationController();
