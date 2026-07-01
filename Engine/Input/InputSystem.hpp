#pragma once
#include "../Core/Math.hpp"
#include "../Core/Types.hpp"
#include <bitset>

// Unified input state — platform layers translate native events into this.
// Read once per display frame by gameplay code.

enum class Key : u16 {
    Unknown = 0,
    // Letters
    A=1, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    // Digits
    D0=30, D1, D2, D3, D4, D5, D6, D7, D8, D9,
    // Special
    Space=50, Enter, Escape, Backspace, Tab, Shift, Ctrl, Alt, Cmd,
    // Arrows
    Left=70, Right, Up, Down,
    // Function
    F1=80, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Count = 100
};

enum class MouseButton : u8 { Left=0, Right=1, Middle=2, Count=3 };

enum class TouchPhase : u8 { Began, Moved, Ended, Cancelled };

struct TouchEvent {
    u64        fingerId { 0 };
    Vec2       position {};  // normalised [0,1]
    TouchPhase phase    {};
};

struct InputState {
    // Keyboard
    std::bitset<static_cast<size_t>(Key::Count)> keysDown;
    std::bitset<static_cast<size_t>(Key::Count)> keysJustPressed;
    std::bitset<static_cast<size_t>(Key::Count)> keysJustReleased;

    // Mouse
    Vec2 mousePos        {};   // normalised [0,1] in viewport
    Vec2 mouseDelta      {};
    f32  mouseScrollDelta{};
    std::bitset<static_cast<size_t>(MouseButton::Count)> mouseDown;
    std::bitset<static_cast<size_t>(MouseButton::Count)> mouseJustPressed;
    std::bitset<static_cast<size_t>(MouseButton::Count)> mouseJustReleased;

    // Touch (iOS / trackpad)
    static constexpr u32 kMaxTouches = 10;
    TouchEvent touches[kMaxTouches];
    u32        touchCount { 0 };

    void NextFrame() {
        keysJustPressed.reset();
        keysJustReleased.reset();
        mouseJustPressed.reset();
        mouseJustReleased.reset();
        mouseDelta       = Vec2Make(0, 0);
        mouseScrollDelta = 0;
        touchCount       = 0;
    }

    // Helpers
    bool IsKeyDown    (Key k) const { return keysDown[static_cast<size_t>(k)]; }
    bool IsKeyPressed (Key k) const { return keysJustPressed[static_cast<size_t>(k)]; }
    bool IsKeyReleased(Key k) const { return keysJustReleased[static_cast<size_t>(k)]; }

    bool IsMouseDown    (MouseButton b) const { return mouseDown[static_cast<size_t>(b)]; }
    bool IsMousePressed (MouseButton b) const { return mouseJustPressed[static_cast<size_t>(b)]; }
    bool IsMouseReleased(MouseButton b) const { return mouseJustReleased[static_cast<size_t>(b)]; }
};

// Input system: hold the global InputState and mutate it from platform callbacks.
// Reset per-frame fields at the start of each display frame.
class InputSystem {
public:
    InputState& State() { return m_state; }
    const InputState& State() const { return m_state; }

    void OnKeyDown     (Key k)          { m_state.keysDown[static_cast<size_t>(k)] = true;
                                          m_state.keysJustPressed[static_cast<size_t>(k)] = true; }
    void OnKeyUp       (Key k)          { m_state.keysDown[static_cast<size_t>(k)] = false;
                                          m_state.keysJustReleased[static_cast<size_t>(k)] = true; }
    void OnMouseMove   (Vec2 normPos, Vec2 delta) { m_state.mousePos = normPos; m_state.mouseDelta = delta; }
    void OnMouseDown   (MouseButton b)  { m_state.mouseDown[static_cast<size_t>(b)] = true;
                                          m_state.mouseJustPressed[static_cast<size_t>(b)] = true; }
    void OnMouseUp     (MouseButton b)  { m_state.mouseDown[static_cast<size_t>(b)] = false;
                                          m_state.mouseJustReleased[static_cast<size_t>(b)] = true; }
    void OnScroll      (f32 delta)      { m_state.mouseScrollDelta += delta; }
    void OnTouch       (TouchEvent te)  { if (m_state.touchCount < InputState::kMaxTouches)
                                              m_state.touches[m_state.touchCount++] = te; }
    void NextFrame     ()               { m_state.NextFrame(); }

private:
    InputState m_state;
};
