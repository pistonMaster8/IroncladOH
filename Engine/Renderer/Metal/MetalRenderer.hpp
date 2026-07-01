#pragma once
// MetalRenderer.hpp — Pure C++ interface; implementation in MetalRenderer.mm

#include "../IRenderer.hpp"
#include <memory>

// Opaque impl
struct MetalRendererImpl;

class MetalRenderer final : public IRenderer {
public:
    MetalRenderer();
    ~MetalRenderer() override;

    bool Init(void* nativeWindowHandle, u32 widthPx, u32 heightPx) override;
    void Shutdown() override;

    void BeginFrame(f32 dt) override;
    void RenderScene(const ::RenderScene& scene) override;
    void EndFrame() override;

    void Resize(u32 widthPx, u32 heightPx) override;
    void SetDisplayScale(f32 scale) override;

    f32  LastGPUTimeMs() const override;
    u32  DrawCallCount() const override;

    // Native Metal objects — callable from ObjC++ only
    // Returns the MTLDevice* as void* for use in app shell
    void* GetMTLDevice() const;
    void* GetMTLCommandQueue() const;

private:
    std::unique_ptr<MetalRendererImpl> m_impl;
};
