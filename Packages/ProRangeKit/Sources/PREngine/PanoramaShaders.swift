/// Shaders Metal du rendu de panorama, compilés au lancement (`makeLibrary(source:)`),
/// ce qui évite de dépendre de la compilation des `.metal` par SwiftPM sur la CI.
/// Le calcul de direction reproduit exactement `ProjectionParameters.direction(ndc:)` (PRCore).
enum PanoramaShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float PI = 3.14159265358979;

    struct ViewUniforms {
        float4 rot0;        // caméra → monde, colonne 0 (droite)
        float4 rot1;        // colonne 1 (haut)
        float4 rot2;        // colonne 2 (arrière)
        float4 shiftTan;    // décalage x, décalage y, tan(fov/2), aspect
        float4 unfolded;    // centre u, centre v, hauteur visible en v, morphing
        float4 display;     // exposition (EV), courbe, hauteur de l'écran en pixels, hauteur de la texture
        float4 background;  // couleur hors panorama
        float4 paper;       // fond de la toile, sous le calque (blanc)
    };

    struct VOut {
        float4 position [[position]];
        float2 ndc;
    };

    vertex VOut panoramaVertex(uint vid [[vertex_id]]) {
        // Un triangle qui couvre tout l'écran.
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.ndc = p * 2.0 - 1.0;
        o.position = float4(o.ndc, 0.0, 1.0);
        return o;
    }

    static float3 rectilinearDirection(float2 ndc, constant ViewUniforms& u) {
        float t = u.shiftTan.z;
        float3 c = normalize(float3(ndc.x * u.shiftTan.w * t + u.shiftTan.x, ndc.y * t + u.shiftTan.y, -1.0));
        return normalize(u.rot0.xyz * c.x + u.rot1.xyz * c.y + u.rot2.xyz * c.z);
    }

    static float2 unfoldedUV(float2 ndc, constant ViewUniforms& u) {
        float span = u.unfolded.z;
        return float2(u.unfolded.x + ndc.x * u.shiftTan.w * span * 0.25, u.unfolded.y - ndc.y * span * 0.5);
    }

    static float3 directionFromUV(float2 uv) {
        float theta = uv.y * PI;
        float phi = (uv.x - 0.5) * 2.0 * PI;
        float s = sin(theta);
        return float3(s * sin(phi), cos(theta), -s * cos(phi));
    }

    static float2 uvFromDirection(float3 d) {
        return float2(atan2(d.x, -d.z) / (2.0 * PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
    }

    static float3 agxContrast(float3 x) {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    }

    static float3 agx(float3 c) {
        const float3x3 inset = float3x3(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
                                        0.0784335999999992, 0.878468636469772, 0.0784336,
                                        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
        const float3x3 outset = float3x3(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
                                         -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
                                         -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
        const float minEV = -12.47393;
        const float maxEV = 4.026069;
        float3 v = inset * max(c, 1e-10);
        v = (clamp(log2(v), minEV, maxEV) - minEV) / (maxEV - minEV);
        v = outset * agxContrast(v);
        // La matrice de sortie peut dépasser légèrement [0, 1] sur les couleurs saturées.
        return clamp(pow(max(v, 0.0), 2.2), 0.0, 1.0);
    }

    static float3 aces(float3 c) {
        return clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    }

    static float3 hable(float3 x) {
        const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
        return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
    }

    static float3 filmic(float3 c) {
        return clamp(hable(c * 2.0) / hable(float3(11.2)), 0.0, 1.0);
    }

    static float3 toneMap(float3 c, int curve) {
        switch (curve) {
            case 1: return agx(c);
            case 2: return aces(c);
            case 3: return filmic(c);
            default: return clamp(c, 0.0, 1.0);
        }
    }

    fragment float4 panoramaFragment(VOut in [[stage_in]],
                                     constant ViewUniforms& u [[buffer(0)]],
                                     texture2d<float> pano [[texture(0)]],
                                     sampler s [[sampler(0)]]) {
        float morph = u.unfolded.w;
        float2 flatUV = unfoldedUV(in.ndc, u);
        float2 uv;
        if (morph >= 0.999) {
            if (flatUV.y < 0.0 || flatUV.y > 1.0) { return float4(u.background.rgb, 1.0); }
            uv = float2(flatUV.x - floor(flatUV.x), flatUV.y);
        } else {
            float3 d = rectilinearDirection(in.ndc, u);
            if (morph > 0.0) {
                float3 f = directionFromUV(float2(flatUV.x, clamp(flatUV.y, 0.0, 1.0)));
                d = normalize(mix(d, f, morph));
            }
            uv = uvFromDirection(d);
        }
        // Niveau de détail choisi explicitement : pas de saut de dérivées sur la couture.
        float pixelAngle = mix(2.0 * u.shiftTan.z / u.display.z, u.unfolded.z * PI / u.display.z, morph);
        float texelAngle = PI / u.display.w;
        float lod = max(0.0, log2(pixelAngle / texelAngle));
        float4 c = pano.sample(s, uv, level(lod));
        c.rgb += u.paper.rgb * (1.0 - c.a);
        return float4(toneMap(c.rgb * exp2(u.display.x), int(u.display.y)), 1.0);
    }
    """
}
