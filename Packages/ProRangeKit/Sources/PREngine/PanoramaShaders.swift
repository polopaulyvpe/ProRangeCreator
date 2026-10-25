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
        float4 layer;       // calque actif : opacité (0 = absent ou masqué), mode, dessus présent, espace (0 perceptuel, 1 linéaire)
        float4 contentRot0; // aperçu de rotation de la sphère : inverse, colonne 0 ; w = 1 si actif
        float4 contentRot1;
        float4 contentRot2;
        float4 guides;      // actifs, espacement (degrés), opacité, inutilisé
        float4 selection;   // sélection affichée, aperçu de transformation actif
        float4 tCenter;     // transformation : origine
        float4 tEast;       // repère tangent en l'origine
        float4 tNorth;
        float4 tMoveInv0;   // inverse du déplacement, en colonnes
        float4 tMoveInv1;
        float4 tMoveInv2;
        float4 tParams;     // cos(angle), sin(angle), 1/échelle x, 1/échelle y
        float4 tH0;         // distorsion : homographie inverse (colonnes), plan gnomonique en tCenter
        float4 tH1;
        float4 tH2;
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

    // Courbe de transfert prolongée au-delà de 1 (PRCore.ColorTransfer).
    constant float SLOPE_AT_ONE = 1.055 / 2.4;

    static float toEncoded(float l) {
        float a = abs(l);
        float c = a <= 0.0031308 ? a * 12.92 : (a <= 1.0 ? 1.055 * pow(a, 1.0 / 2.4) - 0.055 : 1.0 + (a - 1.0) * SLOPE_AT_ONE);
        return l < 0.0 ? -c : c;
    }

    static float toLinear(float c) {
        float a = abs(c);
        float l = a <= 0.04045 ? a / 12.92 : (a <= 1.0 ? pow((a + 0.055) / 1.055, 2.4) : 1.0 + (a - 1.0) / SLOPE_AT_ONE);
        return c < 0.0 ? -l : l;
    }

    static float3 toEncoded3(float3 v) { return float3(toEncoded(v.x), toEncoded(v.y), toEncoded(v.z)); }
    static float3 toLinear3(float3 v) { return float3(toLinear(v.x), toLinear(v.y), toLinear(v.z)); }

    // Modes de fusion : PRCore.BlendMode, mêmes codes (ordre de allCases).
    static float colorBurnF(float b, float s) { return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); }
    static float colorDodgeF(float b, float s) { return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); }
    static float hardLightF(float b, float s) { return s <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s); }
    static float softLightF(float b, float s) {
        if (s <= 0.5) { return b - (1.0 - 2.0 * s) * b * (1.0 - b); }
        float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
        return b + (2.0 * s - 1.0) * (d - b);
    }
    static float vividLightF(float b, float s) { return s <= 0.5 ? colorBurnF(b, 2.0 * s) : colorDodgeF(b, 2.0 * s - 1.0); }
    static float pinLightF(float b, float s) { return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0); }
    static float divideF(float b, float s) { return s <= 1e-6 ? (b > 0.0 ? 65504.0 : 0.0) : min(65504.0, b / s); }

    static float lum(float3 c) { return 0.3 * c.x + 0.59 * c.y + 0.11 * c.z; }
    static float3 clipColor(float3 c) {
        float l = lum(c);
        float n = min(min(c.x, c.y), c.z);
        float x = max(max(c.x, c.y), c.z);
        if (n < 0.0) { c = l + (c - l) * l / (l - n); }
        if (x > 1.0) { c = l + (c - l) * (1.0 - l) / (x - l); }
        return c;
    }
    static float3 setLum(float3 c, float l) { return clipColor(c + (l - lum(c))); }
    static float satOf(float3 c) { return max(max(c.x, c.y), c.z) - min(min(c.x, c.y), c.z); }
    static float3 setSat(float3 c, float s) {
        float mx = max(max(c.x, c.y), c.z);
        float mn = min(min(c.x, c.y), c.z);
        return mx > mn ? (c - mn) * s / (mx - mn) : float3(0.0);
    }

    static float3 blendMode(float3 b, float3 s, int mode) {
        bool unbounded = mode == 0 || mode == 1 || mode == 2 || mode == 4 || mode == 5 || mode == 6
                      || mode == 9 || mode == 10 || mode == 18 || mode == 20 || mode == 21;
        if (!unbounded) { b = clamp(b, 0.0, 1.0); s = clamp(s, 0.0, 1.0); }
        float3 r;
        switch (mode) {
            case 1: r = b * s; break;
            case 2: r = min(b, s); break;
            case 3: r = float3(colorBurnF(b.x, s.x), colorBurnF(b.y, s.y), colorBurnF(b.z, s.z)); break;
            case 4: r = b + s - 1.0; break;
            case 5: r = lum(s) < lum(b) ? s : b; break;
            case 6: r = max(b, s); break;
            case 7: r = b + s - b * s; break;
            case 8: r = float3(colorDodgeF(b.x, s.x), colorDodgeF(b.y, s.y), colorDodgeF(b.z, s.z)); break;
            case 9: r = b + s; break;
            case 10: r = lum(s) > lum(b) ? s : b; break;
            case 11: r = float3(hardLightF(s.x, b.x), hardLightF(s.y, b.y), hardLightF(s.z, b.z)); break;
            case 12: r = float3(softLightF(b.x, s.x), softLightF(b.y, s.y), softLightF(b.z, s.z)); break;
            case 13: r = float3(hardLightF(b.x, s.x), hardLightF(b.y, s.y), hardLightF(b.z, s.z)); break;
            case 14: r = float3(vividLightF(b.x, s.x), vividLightF(b.y, s.y), vividLightF(b.z, s.z)); break;
            case 15: r = clamp(b + 2.0 * s - 1.0, 0.0, 1.0); break;
            case 16: r = float3(pinLightF(b.x, s.x), pinLightF(b.y, s.y), pinLightF(b.z, s.z)); break;
            case 17: r = select(float3(0.0), float3(1.0), b + s >= 1.0); break;
            case 18: r = abs(b - s); break;
            case 19: r = b + s - 2.0 * b * s; break;
            case 20: r = b - s; break;
            case 21: r = float3(divideF(b.x, s.x), divideF(b.y, s.y), divideF(b.z, s.z)); break;
            case 22: r = setLum(setSat(s, satOf(b)), lum(b)); break;
            case 23: r = setLum(setSat(b, satOf(s)), lum(b)); break;
            case 24: r = setLum(s, lum(b)); break;
            case 25: r = setLum(b, lum(s)); break;
            default: r = s; break;
        }
        return max(r, 0.0);
    }

    // PRCore.Compositing.composite : couleurs linéaires prémultipliées en entrée et en sortie.
    static float4 compositeLayer(float4 backdrop, float4 source, int mode, float opacity, bool perceptual) {
        float sa = source.w * opacity;
        if (sa <= 0.0) { return backdrop; }
        float ba = backdrop.w;
        float outA = sa + ba * (1.0 - sa);
        float3 s = source.rgb / source.w;
        float3 b = ba > 0.0 ? backdrop.rgb / ba : float3(0.0);
        if (perceptual) { s = toEncoded3(s); b = toEncoded3(b); }
        float3 mixed = mode == 0 ? s : (1.0 - ba) * s + ba * blendMode(b, s, mode);
        float3 st = (sa * mixed + (1.0 - sa) * ba * b) / outA;
        if (perceptual) { st = toLinear3(st); }
        return float4(st * outA, outA);
    }

    fragment float4 panoramaFragment(VOut in [[stage_in]],
                                     constant ViewUniforms& u [[buffer(0)]],
                                     texture2d<float> pano [[texture(0)]],
                                     texture2d<float> active [[texture(1)]],
                                     texture2d<float> above [[texture(2)]],
                                     texture2d<float> selectionTex [[texture(3)]],
                                     texture2d<float> floatingTex [[texture(4)]],
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
        // Guides : liés au repère du monde (horizon, méridiens), donc calculés avant l'aperçu de rotation du contenu.
        float guide = 0.0;
        if (u.guides.x > 0.5) {
            float spacing = u.guides.y;
            float latDeg = (0.5 - uv.y) * 180.0;
            float lonDeg = (uv.x - 0.5) * 360.0;
            float dLat = abs(fract(latDeg / spacing + 0.5) - 0.5) * spacing * PI / 180.0;
            float dLon = abs(fract(lonDeg / spacing + 0.5) - 0.5) * spacing * PI / 180.0 * cos(latDeg * PI / 180.0);
            float width = max(pixelAngle, 1e-5);
            guide = max(clamp(1.0 - dLat / width, 0.0, 1.0), clamp(1.0 - dLon / width, 0.0, 1.0)) * u.guides.z;
            float horizon = clamp(1.0 - abs(latDeg) * PI / 180.0 / (2.0 * width), 0.0, 1.0);
            guide = max(guide, horizon);
        }
        if (u.contentRot0.w > 0.5) {
            float3 d = directionFromUV(uv);
            d = u.contentRot0.xyz * d.x + u.contentRot1.xyz * d.y + u.contentRot2.xyz * d.z;
            uv = uvFromDirection(d);
        }
        // Sélection, et aperçu de transformation : la direction vue est ramenée à sa source par la transformation inverse
        // (même calcul que PRCore.SphericalTransform.inverse).
        float selectionValue = 1.0;
        float4 floating = float4(0.0);
        if (u.selection.y > 0.5) {
            float3 d = directionFromUV(uv);
            float3 o = u.tCenter.xyz;
            float3 src = o;
            bool valid = true;
            if (u.selection.z > 0.5) {
                // Distorsion (PRCore.SphericalDistort.inverse) : plan gnomonique, homographie inverse.
                float z = dot(d, o);
                valid = z > 1e-4;
                if (valid) {
                    float2 g = float2(dot(d, u.tEast.xyz), dot(d, u.tNorth.xyz)) / z;
                    float3 h = u.tH0.xyz * g.x + u.tH1.xyz * g.y + u.tH2.xyz;
                    valid = abs(h.z) > 1e-9;
                    if (valid) { src = normalize(o + u.tEast.xyz * (h.x / h.z) + u.tNorth.xyz * (h.y / h.z)); }
                }
            } else {
                float3 e = u.tMoveInv0.xyz * d.x + u.tMoveInv1.xyz * d.y + u.tMoveInv2.xyz * d.z;
                float cosA = dot(o, e);
                float3 t = e - o * cosA;
                float sinA = length(t);
                float2 p = float2(0.0);
                if (sinA > 1e-7) { p = float2(dot(t, u.tEast.xyz), dot(t, u.tNorth.xyz)) * (atan2(sinA, cosA) / sinA); }
                float cs = u.tParams.x;
                float sn = u.tParams.y;
                float2 q = float2(p.x * cs + p.y * sn, -p.x * sn + p.y * cs) * u.tParams.zw;
                float a = length(q);
                if (a > 1e-7) { src = o * cos(a) + (u.tEast.xyz * q.x + u.tNorth.xyz * q.y) / a * sin(a); }
            }
            if (valid) {
                float2 suv = uvFromDirection(src);
                floating = floatingTex.sample(s, suv, level(lod));
                if (u.selection.x > 0.5) { selectionValue = selectionTex.sample(s, suv, level(lod)).a; }
            } else if (u.selection.x > 0.5) {
                selectionValue = 0.0;
            }
        } else if (u.selection.x > 0.5) {
            selectionValue = selectionTex.sample(s, uv, level(lod)).a;
        }
        bool perceptual = u.layer.w < 0.5;
        // Dessous (papier et calques inférieurs déjà composés), puis calque actif avec son mode, puis dessus (tout en Normal).
        float4 c = pano.sample(s, uv, level(lod));
        if (u.layer.x > 0.0) { c = compositeLayer(c, active.sample(s, uv, level(lod)), int(u.layer.y), u.layer.x, perceptual); }
        if (u.layer.z > 0.5) { c = compositeLayer(c, above.sample(s, uv, level(lod)), 0, 1.0, perceptual); }
        c.rgb += u.paper.rgb * (1.0 - c.a);
        c.rgb = floating.rgb + c.rgb * (1.0 - floating.a);
        float3 shown = toneMap(c.rgb * exp2(u.display.x), int(u.display.y));
        // Hors sélection : assombri.
        if (u.selection.x > 0.5) { shown *= mix(0.5, 1.0, clamp(selectionValue, 0.0, 1.0)); }
        return float4(mix(shown, float3(0.2, 0.75, 1.0), guide), 1.0);
    }
    """
}
