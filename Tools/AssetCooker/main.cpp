// PostFall AssetCooker — offline asset compiler.
// Converts raw source assets into engine-native cooked binary formats.
//
// Pipeline:
//   glTF 2.0 (.glb) → CookedMesh binary
//   PNG/EXR → KTX2 (via toktx) → transcodes to ASTC/BC7 at runtime
//   JSON material → CookedMaterial binary
//
// Usage:
//   AssetCooker --input <AssetsRaw/> --output <AssetsCooked/> --platform [macos|ios|all]
//   AssetCooker --single <file.glb> --output <AssetsCooked/>

#include "../../Engine/Assets/AssetID.hpp"
#include "../../Engine/Assets/MeshAsset.hpp"
#include "../../Engine/Core/StringID.hpp"
#include "../../Engine/Core/Log.hpp"
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include <fstream>

namespace fs = std::filesystem;

struct CookerOptions {
    fs::path inputDir;
    fs::path outputDir;
    std::string platform { "all" };
    fs::path singleFile;
};

static CookerOptions ParseArgs(int argc, char** argv) {
    CookerOptions opts;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--input") == 0 && i+1 < argc)
            opts.inputDir = argv[++i];
        else if (strcmp(argv[i], "--output") == 0 && i+1 < argc)
            opts.outputDir = argv[++i];
        else if (strcmp(argv[i], "--platform") == 0 && i+1 < argc)
            opts.platform = argv[++i];
        else if (strcmp(argv[i], "--single") == 0 && i+1 < argc)
            opts.singleFile = argv[++i];
    }
    return opts;
}

// Write a cooked mesh to disk (minimal binary format).
// Format:
//   [4 bytes] magic "PFMH"
//   [4 bytes] version = 1
//   [16 bytes] AssetID
//   [4 bytes] vertexCount
//   [4 bytes] indexCount
//   [4 bytes] lodCount
//   [N bytes] vertex data (interleaved PNU: 3+3+2 floats)
//   [N bytes] index data (u16)
//   [N bytes] LOD headers (MeshLOD)
static bool WriteCookedMesh(const CookedMesh& mesh, const fs::path& outPath) {
    std::ofstream f(outPath, std::ios::binary);
    if (!f) { LOG_ERR("Cooker", "Cannot open output: %s", outPath.string().c_str()); return false; }

    const u32 kMagic   = 0x48464D50; // 'PFMH'
    const u32 kVersion = 1;
    f.write(reinterpret_cast<const char*>(&kMagic),   4);
    f.write(reinterpret_cast<const char*>(&kVersion),  4);
    f.write(reinterpret_cast<const char*>(mesh.id.bytes), 16);

    u32 vc = mesh.VertexCount();
    u32 ic = static_cast<u32>(mesh.indices16.size());
    u32 lc = static_cast<u32>(mesh.lods.size());
    f.write(reinterpret_cast<const char*>(&vc), 4);
    f.write(reinterpret_cast<const char*>(&ic), 4);
    f.write(reinterpret_cast<const char*>(&lc), 4);

    // AABB
    f.write(reinterpret_cast<const char*>(&mesh.bounds), sizeof(AABB));

    // Vertex data
    f.write(reinterpret_cast<const char*>(mesh.vertexData.data()), mesh.vertexData.size());

    // Index data
    f.write(reinterpret_cast<const char*>(mesh.indices16.data()),
            mesh.indices16.size() * sizeof(u16));

    // LODs
    f.write(reinterpret_cast<const char*>(mesh.lods.data()),
            mesh.lods.size() * sizeof(MeshLOD));

    LOG_INF("Cooker", "Wrote cooked mesh: %s (%u verts, %u idx)",
            outPath.filename().string().c_str(), vc, ic);
    return true;
}

// Placeholder: real implementation would use fastgltf to import the glTF.
// For now, generate a unit cube as a placeholder cooked mesh.
static CookedMesh MakePlaceholderMesh(const std::string& name) {
    CookedMesh m;
    m.name   = name;
    m.format = VertexFormat::PNU;
    m.bounds.min = Vec3Make(-0.5f, -0.5f, -0.5f);
    m.bounds.max = Vec3Make( 0.5f,  0.5f,  0.5f);

    // 8-vertex cube in PNU format (3+3+2 floats = 8 floats = 32 bytes/vertex)
    struct PNUVert { float px,py,pz, nx,ny,nz, u,v; };
    const PNUVert verts[8] = {
        {-0.5f,-0.5f,-0.5f, 0,0,-1, 0,0},
        { 0.5f,-0.5f,-0.5f, 0,0,-1, 1,0},
        { 0.5f, 0.5f,-0.5f, 0,0,-1, 1,1},
        {-0.5f, 0.5f,-0.5f, 0,0,-1, 0,1},
        {-0.5f,-0.5f, 0.5f, 0,0, 1, 0,0},
        { 0.5f,-0.5f, 0.5f, 0,0, 1, 1,0},
        { 0.5f, 0.5f, 0.5f, 0,0, 1, 1,1},
        {-0.5f, 0.5f, 0.5f, 0,0, 1, 0,1},
    };
    const u16 idx[36] = {
        0,2,1, 0,3,2,  4,5,6, 4,6,7,
        0,1,5, 0,5,4,  2,3,7, 2,7,6,
        0,4,7, 0,7,3,  1,2,6, 1,6,5,
    };

    m.vertexData.assign(reinterpret_cast<const u8*>(verts),
                        reinterpret_cast<const u8*>(verts) + sizeof(verts));
    m.indices16.assign(idx, idx + 36);
    m.lods.push_back(MeshLOD{ 0, 36, 0.0f });

    // Generate a deterministic AssetID from name
    u64 h = StringID::Compute(name);
    memcpy(m.id.bytes, &h, 8);
    memcpy(m.id.bytes + 8, &h, 8);
    return m;
}

int main(int argc, char** argv) {
    LOG_INF("Cooker", "PostFall AssetCooker v0.1");
    CookerOptions opts = ParseArgs(argc, argv);

    if (opts.outputDir.empty()) {
        LOG_ERR("Cooker", "No --output directory specified");
        return 1;
    }
    fs::create_directories(opts.outputDir);
    fs::create_directories(opts.outputDir / "Meshes");
    fs::create_directories(opts.outputDir / "Textures");
    fs::create_directories(opts.outputDir / "Materials");

    // ─── Single-file mode ────────────────────────────────────────────────────
    if (!opts.singleFile.empty()) {
        auto ext = opts.singleFile.extension().string();
        if (ext == ".glb" || ext == ".gltf") {
            LOG_INF("Cooker", "Cooking mesh: %s", opts.singleFile.string().c_str());
            CookedMesh mesh = MakePlaceholderMesh(opts.singleFile.stem().string());
            fs::path out   = opts.outputDir / "Meshes" / (opts.singleFile.stem().string() + ".pfmesh");
            return WriteCookedMesh(mesh, out) ? 0 : 1;
        }
        LOG_ERR("Cooker", "Unsupported single-file type: %s", ext.c_str());
        return 1;
    }

    // ─── Directory mode ──────────────────────────────────────────────────────
    if (opts.inputDir.empty()) {
        LOG_ERR("Cooker", "No --input directory specified");
        return 1;
    }

    int processed = 0, failed = 0;
    for (const auto& entry : fs::recursive_directory_iterator(opts.inputDir)) {
        if (!entry.is_regular_file()) continue;
        auto ext = entry.path().extension().string();

        if (ext == ".glb" || ext == ".gltf") {
            LOG_INF("Cooker", "Cooking mesh: %s", entry.path().filename().string().c_str());
            CookedMesh mesh = MakePlaceholderMesh(entry.path().stem().string());
            fs::path out   = opts.outputDir / "Meshes" / (entry.path().stem().string() + ".pfmesh");
            if (WriteCookedMesh(mesh, out)) processed++; else failed++;
        } else if (ext == ".png" || ext == ".exr" || ext == ".jpg") {
            // TODO: invoke toktx to produce KTX2 with Basis Universal
            LOG_INF("Cooker", "Texture cooking not yet implemented: %s",
                    entry.path().filename().string().c_str());
        }
    }

    LOG_INF("Cooker", "Done: %d processed, %d failed", processed, failed);
    return failed > 0 ? 1 : 0;
}
